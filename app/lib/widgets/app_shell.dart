// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../ffi_bridge.dart'
    show AudioDeviceInfo, EclipsaStudioEngine, PlaybackAe;
import '../logging/log.dart';
import '../meters/db_utils.dart';
import '../meters/meter_ballistics.dart';
import '../meters/meter_provider.dart';
import '../meters/peak_hold.dart';
import '../playback/playback_session.dart';
import '../session/session.dart';
import '../state.dart';
import '../util/focus_utils.dart';
import '../theme.dart';
import '../video/video_panel.dart';
import '../video/video_provider.dart';
import '../video/video_sync.dart';
import '../views/elements_view.dart';
import '../views/mix_view.dart';
import '../views/renderer_view.dart';
import '../views/inspector_view.dart';
import '../window_state.dart';
import '../workspace/workspace_actions.dart'
    show openIamfForQc, publishPlaybackDuration;
import '../workspace/workspace_close.dart';
import '../workspace/workspace_mode.dart';
import '../workspace/workspace_tab_shortcuts.dart';
import 'import_error_dialog.dart';
import 'ok_dialog.dart';
import 'statusbar.dart';
import 'topbar.dart';

// Process-lifetime latch for the startup auto-load. AppShell re-mounts
// when the user returns to landing and re-enters Creator; without this
// flag each remount would fire _maybeReopenLastProject again and
// re-load the initial session on top of whatever the user just
// selected. Module-level so it survives State re-creation.
bool _autoLoadConsumed = false;

// One-time, mode-independent restore of engine-global settings (audio
// device + monitoring) so the landing screen reflects saved state, not
// only an open workspace. Latched for the process lifetime.
bool _startupRestoreDone = false;

// One-shot guard for the launch-parameter Playback open. Module-level so
// it survives StartupRestore State re-creation and fires exactly once.
bool _autoOpenIamfConsumed = false;

// Bumped on every applyMonitoringForDevice call. A call that finds the token
// changed after its async prefs read knows a newer apply superseded it and
// bows out, so overlapping device switches can't race the config write.
int _applyMonitoringGeneration = 0;

/// Height kept for the workspace view under the video panel (ES-1027).
/// Measured 1400 px wide, the Mix view needs 306 px at the Large font
/// size, the Renderer view 122 px and the Elements view 112 px.
const double kMinWorkspaceViewHeight = 320;

/// The maximum height of the video panel, including the border under
/// the strip, when [available] px lie between the top bar and the status
/// bar (ES-1027): the least of 600 px, half of [available], and
/// [available] less [kMinWorkspaceViewHeight]. Below 320 px of
/// [available] it is negative; the panel keeps its 100 px strip whatever
/// the value.
double videoPanelMaxHeight(double available) =>
    math.min(600, math.min(available / 2, available - kMinWorkspaceViewHeight));

/// Element-wise equality for two routing-mask lists (null-safe). Used to
/// decide whether a same-layout config change actually edited the patch and
/// needs an engine re-push.
bool _sameMasks(List<int>? a, List<int>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// One-shot guard for the "audio output unavailable" SnackBar — process
// lifetime, shared by the startup restore and the AppShell tick.
bool _audioOutputUnavailableNotified = false;

/// The `--quit-after-load` verdict once the launch file has opened (a
/// session, [what] `session`, or a Playback file, [what] `playback`):
/// exit 0 when it [opened] and the engine is initialised, exit 1
/// otherwise. The audio thread may legitimately be down on headless
/// machines (no output device), so it is reported but not required.
/// Skips Flutter and window-manager teardown deliberately via
/// [hardExit]: on Windows a plain `exit()` still runs the orderly
/// plugin teardown, which wedges in the ANGLE GL teardown and leaves a
/// window-less zombie instead of exiting (ES-389).
Never quitAfterStartupOpen(
  EclipsaStudioEngine? engine, {
  required bool opened,
  required String what,
}) {
  final ok = opened && engine != null;
  final audioRunning = engine?.isAudioThreadRunning ?? false;
  // STABLE LOG CONTRACT (issue ES-39): smoke tests parse this line.
  Log.i(
    LogCat.app,
    'quit-after-load: ${ok ? 'ok' : 'failed'} '
    '($what=$opened engine=${engine != null} audio=$audioRunning) '
    '— exit ${ok ? 0 : 1}',
  );
  hardExit(ok ? 0 : 1);
}

/// Sits above the workspace-mode switch so engine-global restore and
/// listeners run whether the app opens on the landing screen or straight
/// into a workspace. Owns the audio + monitoring restore (once), plus the
/// monitoring engine-push/persist and device-shrink clamp listeners.
class StartupRestore extends ConsumerStatefulWidget {
  final Widget child;
  const StartupRestore({super.key, required this.child});

  @override
  ConsumerState<StartupRestore> createState() => _StartupRestoreState();
}

class _StartupRestoreState extends ConsumerState<StartupRestore> {
  Timer? _deviceListTimer;
  Timer? _hwRateTimer;

  // Rate-follow poll state (see _pollDeviceHardwareRate).
  int _hwRateMismatchPolls = 0;
  final RateFollowLatch _rateFollowLatch = RateFollowLatch();

  @override
  void dispose() {
    _deviceListTimer?.cancel();
    _hwRateTimer?.cancel();
    super.dispose();
  }

  /// Follow OS-level sample-rate changes. The user can change the
  /// device's nominal rate in Audio MIDI Setup at any time; nothing
  /// notifies the app, so poll the live hardware rate at 1 Hz and,
  /// after two consecutive mismatched reads (debounce against catching
  /// the OS mid-switch), reconfigure — the engine re-adopts the
  /// hardware rate and the providers/UI follow. Lives here — not in
  /// the AppShell tick — for the same reason as the device-list poll:
  /// the settings dialog is reachable from the landing screen, where
  /// no workspace (and no ticker) exists, and a stale rate would sit
  /// in Settings until a workspace mounted.
  ///
  /// A failed follow (reconfigure error, or the engine rolled back to
  /// the mismatched stream because the device refused its own rate) is
  /// latched per (device, hw-rate) pair: retrying would close/reopen
  /// the device every ~2 s forever (ES-33). While latched, the mismatch
  /// is surfaced via [sampleRateMismatchProvider] (status bar +
  /// settings dialog) instead of retried; the latch clears when the
  /// hardware rate or device changes, or the rates agree again.
  void _pollDeviceHardwareRate() {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;
    final hw = engine.deviceHardwareSampleRate;
    if (hw == 0 || hw == engine.currentSampleRate) {
      _hwRateMismatchPolls = 0;
      if (_rateFollowLatch.isSet) {
        _rateFollowLatch.clear();
        ref.read(sampleRateMismatchProvider.notifier).update(null);
        Log.i(LogCat.device, 'Sample-rate mismatch cleared');
      }
      return;
    }
    final s = ref.read(audioSettingsProvider);
    if (_rateFollowLatch.matches(s.deviceIndex, hw)) {
      _hwRateMismatchPolls = 0;
      return;
    }
    if (++_hwRateMismatchPolls < 2) return;
    _hwRateMismatchPolls = 0;

    Log.i(
      LogCat.device,
      'Device hardware rate changed to $hw Hz — reconfiguring to follow',
    );
    final rc = engine.reconfigure(
      deviceIndex: s.deviceIndex,
      sampleRate: hw,
      bufferSize: s.bufferSize,
    );
    ref.read(audioConfigEpochProvider.notifier).bump();
    if (rc != 0 || engine.currentSampleRate != hw) {
      final engineRate = engine.currentSampleRate;
      _rateFollowLatch.set(s.deviceIndex, hw);
      ref.read(sampleRateMismatchProvider.notifier).update((
        engineRate: engineRate,
        hwRate: hw,
      ));
      Log.w(
        LogCat.device,
        rc != 0
            ? 'Failed to follow hardware rate (rc=$rc) — output may be '
                  'resampled; not retrying until the rate or device changes'
            : 'Device rate follow: engine at $engineRate Hz, device at '
                  '$hw Hz — output is resampled; not retrying until the '
                  'rate or device changes',
      );
      return;
    }
    final actual = engine.currentSampleRate;
    // A latch for a different (device, rate) pair is stale now that a
    // follow succeeded — clear it rather than waiting a poll cycle.
    if (_rateFollowLatch.isSet) {
      _rateFollowLatch.clear();
      ref.read(sampleRateMismatchProvider.notifier).update(null);
    }
    ref
        .read(audioSettingsProvider.notifier)
        .update(
          AudioSettings(
            deviceIndex: s.deviceIndex,
            sampleRate: actual,
            bufferSize: s.bufferSize,
          ),
        );
    ref.read(transportProvider.notifier).rebaseSampleRate(actual);
  }

  /// Re-enumerate output devices every few seconds so hot-plugged
  /// devices appear, removed ones drop out, and the "(default)" badge
  /// follows the OS default. Lives here — not in the AppShell tick —
  /// because the settings dialog is reachable from the landing screen,
  /// where no workspace (and no ticker) exists. The selection stays
  /// pinned to the user's device: enumeration indices shift, so the
  /// selected index is remapped by name. A pure reindex leaves the open
  /// stream untouched. If the selected device disappeared, the selection
  /// follows the engine's fallback (system default) AND the fallback
  /// stream is reopened here — the engine re-points its selection but
  /// never reopens, so without this playback would be silent (ES-163).
  void _pollDeviceList() {
    final before = ref.read(audioDevicesProvider);
    final s = ref.read(audioSettingsProvider);
    final selectedName = s.deviceIndex >= 0 && s.deviceIndex < before.length
        ? before[s.deviceIndex].name
        : null;
    if (!ref.read(audioDevicesProvider.notifier).refresh()) return;
    final after = ref.read(audioDevicesProvider);
    Log.i(LogCat.device, 'Device list changed: ${after.length} device(s)');

    // Follow-system-default mode (ES-467): the selection tracks the OS
    // default output, not a pinned device. The refresh publishes on
    // default-flag moves too (see AudioDevicesNotifier._sameDevices),
    // so a default flip between two present devices lands here even
    // when nothing was plugged or unplugged.
    if (ref.read(followSystemDefaultProvider)) {
      final action = followSystemDefaultAction(
        after,
        selectedName,
        s.deviceIndex,
      );
      if (action == null) return;
      if (!action.reopen) {
        // Same device, shifted enumeration index — re-pin only.
        ref
            .read(audioSettingsProvider.notifier)
            .update(
              AudioSettings(
                deviceIndex: action.index,
                sampleRate: s.sampleRate,
                bufferSize: s.bufferSize,
              ),
            );
        return;
      }
      Log.i(
        LogCat.device,
        'System default output is now "${after[action.index].name}" — '
        'following',
      );
      _reopenOutputDevice(action.index, s, after);
      return;
    }

    if (selectedName == null) return;
    var idx = -1;
    for (var i = 0; i < after.length; i++) {
      if (after[i].name == selectedName) {
        idx = i;
        break;
      }
    }
    if (idx == s.deviceIndex) return;
    if (idx >= 0) {
      // Device still present, only its enumeration index shifted (something
      // hot-plugged ahead of it). The open stream is untouched — just re-pin
      // the selection to the new index, no reopen needed.
      ref
          .read(audioSettingsProvider.notifier)
          .update(
            AudioSettings(
              deviceIndex: idx,
              sampleRate: s.sampleRate,
              bufferSize: s.bufferSize,
            ),
          );
      return;
    }
    // Selected device disappeared. DeviceManager::refresh has already
    // re-pointed the engine's selection to the system-default fallback, but
    // it does NOT reopen the stream — `dev_` stays bound to the dead device,
    // so playback is silent. Reopen the fallback ourselves, the same way a
    // manual device switch does (settings_dialog `_applyAudio`); pointing the
    // routing at it without a reconfigure (the old behaviour) left it muted
    // until a manual toggle (ES-163).
    Log.w(LogCat.device, 'Selected device "$selectedName" disconnected');
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;
    _reopenOutputDevice(engine.currentDeviceIndex, s, after);
  }

  /// Reopen the output stream on device [idx] — the same sequence a
  /// manual device switch runs (settings_dialog `_applyAudio`), shared
  /// by the disconnect fallback (ES-163) and the follow-system-default
  /// switch (ES-467). The saved device name is deliberately NOT
  /// persisted: neither caller is a deliberate user pick, so the
  /// pinned device stays on disk and is restored on the next launch
  /// (or when follow mode is switched back off).
  void _reopenOutputDevice(
    int idx,
    AudioSettings s,
    List<AudioDeviceInfo> after,
  ) {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;
    if (idx < 0 || idx >= after.length) return;
    final rc = engine.reconfigure(
      deviceIndex: idx,
      sampleRate: s.sampleRate,
      bufferSize: s.bufferSize,
    );
    ref.read(audioConfigEpochProvider.notifier).bump();
    if (rc != 0) {
      Log.w(
        LogCat.device,
        'Failed to reopen output device "${after[idx].name}" '
        '(rc=$rc) — output stays silent until a manual switch',
      );
      return;
    }
    // The engine adopts the new hardware's own rate; read back what is
    // actually running, reflect it, and re-pin the transport clock so
    // seek round-trips stay identity.
    final actualRate = engine.currentSampleRate;
    final indexChanged = idx != s.deviceIndex;
    ref
        .read(audioSettingsProvider.notifier)
        .update(
          AudioSettings(
            deviceIndex: idx,
            sampleRate: actualRate,
            bufferSize: s.bufferSize,
          ),
        );
    ref.read(transportProvider.notifier).rebaseSampleRate(actualRate);
    // The deviceIndex listener loads + pushes the new device's monitoring
    // config, but only fires when the index value changes. If the new
    // device lands on the same numeric index the old one held, push it
    // here so it gets its own routing rather than inheriting the old.
    if (!indexChanged) {
      applyMonitoringForDevice(ref);
    }
    Log.i(
      LogCat.device,
      'Reopened output "${after[idx].name}" at $actualRate Hz',
    );
  }

  @override
  void initState() {
    super.initState();
    // 1 s cadence (same as the hardware-rate poll below): follow-
    // system-default mode (ES-467) rides this poll, and a multi-second
    // lag between the OS switching outputs and the app following
    // reads as broken. Each tick pays a full re-enumeration (HAL
    // property reads per device) plus FFI marshalling of the list;
    // only the provider publish is skipped when nothing changed.
    // Accepted at 1 Hz — the hardware-rate poll below already does
    // per-second HAL reads.
    _deviceListTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollDeviceList(),
    );
    _hwRateTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollDeviceHardwareRate(),
    );
    // Routing pushed to the engine is masked to the live device's channel
    // count. The mask is a VIEW: state and disk keep the full patch so it
    // survives device switches and channel-count changes (ES-24, ES-63).
    List<int> maskedRouting(MonitoringConfig c) => c
        .clampedToDeviceChannels(ref.read(outputDeviceChannelsProvider))
        .routing;

    // Push monitoring config changes to the C++ engine + persist. Attached
    // before the post-frame restore so the restored config's first `set`
    // pushes the saved layout to the engine.
    ref.listenManual(monitoringConfigProvider, (prev, next) {
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine != null) {
        if (prev?.layout != next.layout) {
          // Push layout + routing atomically so the audio thread never hears
          // the new layout paired with the previous target's patch. The first
          // fire (prev == null) is the one-time startup sync.
          if (!engine.setLayoutAndRouting(
            next.layout.oarValue,
            maskedRouting(next),
          )) {
            Log.e(
              LogCat.engine,
              'Failed to set layout to ${next.layout.label}',
            );
          }
        } else if (!_sameMasks(prev?.routing, next.routing)) {
          // Same layout, patch edited — push the routing alone.
          if (!engine.setRouting(maskedRouting(next))) {
            Log.w(LogCat.engine, 'Failed to set routing');
          }
        }
      }
      persistMonitoringForDevice(ref);
    });

    // Pink-noise calibration lives in a separate provider, so it gets its own
    // push. It reads both the lit cell and the current reference level; the
    // engine mutes the program and plays noise at a fixed level while lit.
    void pushNoise() {
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine == null) return;
      final noise = ref.read(noiseInjectionProvider);
      final dbfs = ref.read(monitoringConfigProvider).noiseDbfs;
      final mode = switch (noise.cell) {
        NoiseCell.row => 1,
        NoiseCell.col => 2,
        NoiseCell.none => 0,
      };
      engine.setNoise(mode, noise.channel, dbfs);
    }

    ref.listenManual(noiseInjectionProvider, (_, _) => pushNoise());
    // Re-push the level while a cell is lit (noiseDbfs lives in the
    // monitoring config, a separate provider from the noise cell).
    ref.listenManual(
      monitoringConfigProvider.select((c) => c.noiseDbfs),
      (_, _) => pushNoise(),
    );

    // Output channel labels persist per device alongside the config.
    ref.listenManual(
      outputLabelsProvider,
      (_, _) => persistMonitoringForDevice(ref),
    );

    // On output-device switch, load that device's saved config / routing /
    // labels (or seed a default). Reads the current device name at apply
    // time, after the index has changed.
    ref.listenManual(audioSettingsProvider.select((s) => s.deviceIndex), (
      prev,
      next,
    ) {
      if (prev == null || prev == next) return;
      applyMonitoringForDevice(ref);
    });

    // When the device channel count changes (smaller device, same device
    // reconfigured, enumeration completing at startup), re-push the active
    // routing under the new mask. Shrink: the engine stops hearing
    // out-of-range wires (settings dialog surfaces the warning). Grow: the
    // full saved patch becomes audible again. State itself never mutates,
    // so nothing clamped can be persisted (ES-24, ES-63).
    ref.listenManual(outputDeviceChannelsProvider, (prev, next) {
      if (prev == null || prev == next) return;
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine == null) return;
      if (!engine.setRouting(
        maskedRouting(ref.read(monitoringConfigProvider)),
      )) {
        Log.w(
          LogCat.engine,
          'Failed to re-push routing for $next device channels',
        );
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreStartupSettings(ref, context);
      _maybeAutoOpenIamf(ref, context);
      _maybeQuitWithoutEngine(ref);
    });
  }

  // Without the engine the engine-unavailable screen replaces AppShell,
  // so a launch session is never loaded; an unattended --quit-after-load
  // run gives its session verdict here. A Playback file reaches its own
  // verdict through _maybeAutoOpenIamf.
  void _maybeQuitWithoutEngine(WidgetRef ref) {
    if (!ref.read(quitAfterLoadProvider)) return;
    if (ref.read(autoLoadSessionProvider) == null) return;
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine != null) return;
    quitAfterStartupOpen(null, opened: false, what: 'session');
  }

  // Launch-parameter Playback open (`--open` with a Playback file,
  // `--playback`, or its old name `--iamf`): open the file in Playback
  // mode once the first frame is up. StartupRestore is mounted for every
  // workspace mode (it wraps the mode router), so this fires whether the
  // app booted to the landing screen or elsewhere; openIamfForQc drives
  // the switch to Playback itself. Latched so a StartupRestore remount
  // can't reopen it. Under --quit-after-load the open shows no error
  // dialog and the process exits with the verdict once it completes.
  Future<void> _maybeAutoOpenIamf(WidgetRef ref, BuildContext context) async {
    if (_autoOpenIamfConsumed) return;
    _autoOpenIamfConsumed = true;
    final path = ref.read(autoLoadIamfProvider);
    if (path == null) return;
    final quit = ref.read(quitAfterLoadProvider);
    // Read once, before the open; the verdict below reports it.
    final engine = ref.read(eclipsaStudioEngineProvider);
    Log.i(LogCat.app, 'Auto-opening for Playback: $path');
    var opened = false;
    try {
      opened = await openIamfForQc(context, ref, path: path, showErrors: !quit);
    } catch (e, st) {
      // Error subclasses too: under --quit-after-load the process must
      // reach the verdict below.
      Log.e(LogCat.app, 'Unexpected error during the Playback open: $e', st);
    } finally {
      if (quit) quitAfterStartupOpen(engine, opened: opened, what: 'playback');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> _restoreStartupSettings(
  WidgetRef ref,
  BuildContext context,
) async {
  if (_startupRestoreDone) return;
  _startupRestoreDone = true;
  await _restoreAudioSettings(ref, context);
  // Pin the transport clock to whatever rate the engine actually ended up
  // running at. _restoreAudioSettings rebases on its reconfigure path, but
  // both of its early returns (no saved prefs; saved state already matches
  // the engine) skip that — and when the device forced a non-48 kHz rate,
  // leaving transport.sampleRate at its 48000 default while the engine runs
  // at e.g. 96000 desyncs the playhead and video by the rate ratio (ES-218).
  // rebaseSampleRate is a no-op when already equal, so this is safe after the
  // reconfigure path has already pinned it.
  if (context.mounted) {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine != null) {
      ref
          .read(transportProvider.notifier)
          .rebaseSampleRate(engine.currentSampleRate);
    }
  }
  await applyMonitoringForDevice(ref);
}

Future<void> _restoreAudioSettings(WidgetRef ref, BuildContext context) async {
  final engine = ref.read(eclipsaStudioEngineProvider);
  if (engine == null) return;
  try {
    final prefs = await AppPreferences.load();
    if (!context.mounted) return;
    final savedName = prefs[AppPreferences.kAudioDeviceName] as String?;
    final savedBuf = prefs[AppPreferences.kAudioBufferSize] as int?;
    final follow = prefs[AppPreferences.kAudioFollowSystemDefault] == true;
    if (follow) {
      ref.read(followSystemDefaultProvider.notifier).restore(true);
    }
    if (savedName == null && savedBuf == null && !follow) {
      _notifyIfAudioOutputUnavailable(ref, context);
      return;
    }

    // Resolve the device to open: in follow mode the OS default wins
    // (the saved name is the remembered pin for when follow is turned
    // off); otherwise the saved name resolved to its current index.
    var devIdx = engine.currentDeviceIndex;
    if (follow) {
      final devices = engine.getAudioDevices();
      for (final d in devices) {
        if (d.isDefault) {
          devIdx = d.index;
          break;
        }
      }
    } else if (savedName != null) {
      for (var i = 0; i < engine.deviceCount; i++) {
        if (engine.deviceName(i) == savedName) {
          devIdx = i;
          break;
        }
      }
    }

    // The sample rate is never persisted or requested: the engine
    // adopts whatever rate the output device is running (ES-518).
    final rate = engine.currentSampleRate;
    final buf = savedBuf ?? engine.currentBufferSize;

    // Skip reconfigure if already matching the engine's current state.
    if (devIdx == engine.currentDeviceIndex &&
        buf == engine.currentBufferSize) {
      return;
    }

    final rc = engine.reconfigure(
      deviceIndex: devIdx,
      sampleRate: rate,
      bufferSize: buf,
    );
    ref.read(audioConfigEpochProvider.notifier).bump();
    if (rc == 0) {
      // The engine adopts the device's hardware rate (ES-518) —
      // reflect what is actually in effect.
      final actualRate = engine.currentSampleRate;
      ref
          .read(audioSettingsProvider.notifier)
          .update(
            AudioSettings(
              deviceIndex: devIdx,
              sampleRate: actualRate,
              bufferSize: buf,
            ),
          );
      // Engine SR may have changed; re-pin the transport's clock so seek
      // round-trips stay identity.
      ref.read(transportProvider.notifier).rebaseSampleRate(actualRate);
      Log.i(
        LogCat.engine,
        'Restored audio settings: '
        '${follow ? "system default" : savedName}, '
        '$actualRate Hz, $buf frames',
      );
    } else {
      Log.w(LogCat.engine, 'Failed to restore audio settings (rc=$rc)');
    }
  } on Exception catch (e) {
    Log.w(LogCat.engine, 'Failed to restore audio settings', e);
  }
  if (context.mounted) _notifyIfAudioOutputUnavailable(ref, context);
}

/// Load and apply the monitoring config + output labels for the current
/// device, and record that device in [monitoringDeviceNameProvider], the
/// name later edits are saved under. Startup restore, device switch and
/// Reset to Defaults all call it, and none of them needs a relaunch.
/// Falls back to [MonitoringConfig.initial] when the device has no saved
/// entry. The global limiter law is not per-device state; it is always
/// overlaid from [AppPreferences] so that one call restores everything
/// the MONITORING panel shows.
Future<void> applyMonitoringForDevice(WidgetRef ref) async {
  // Bump a generation token so a newer apply (e.g. a fast second device
  // switch) that starts while this one awaits the prefs read wins instead of
  // both racing to write monitoringConfigProvider.
  final generation = ++_applyMonitoringGeneration;
  final deviceName = selectedOutputDeviceName(ref);
  // Let queued saves land first; loading around an in-flight save would
  // snapshot stale prefs and resurrect an outdated device entry.
  await monitoringSavesSettled();
  final prefs = await AppPreferences.load();
  // A newer apply superseded us during the load — let it own the write.
  if (generation != _applyMonitoringGeneration) return;

  // Reuse the prefs map already in hand — no second disk read.
  final loaded = deviceName != null
      ? monitoringForDeviceIn(prefs, deviceName)
      : null;

  final MonitoringConfig cfg;
  final Map<int, String> labels;
  if (loaded != null) {
    cfg = loaded.config;
    labels = loaded.labels;
  } else {
    // Unknown device: the seeded default (Stereo and Binaural, identity
    // routing, Stereo active).
    cfg = MonitoringConfig.initial();
    labels = const {};
  }

  // Restore is read-only with respect to disk: the sets below fire the
  // engine-push listeners (masked to the live channel count), but the
  // persistence listeners are suppressed — writing a restore back is how
  // routing used to get clamped on disk and lost (ES-63).
  _applyingMonitoring = true;
  try {
    ref.read(monitoringDeviceNameProvider.notifier).set(deviceName);
    ref.read(monitoringConfigProvider.notifier).set(cfg);
    ref.read(outputLabelsProvider.notifier).replaceAll(labels);
  } finally {
    _applyingMonitoring = false;
  }
  Log.i(
    LogCat.engine,
    'Applied monitoring for ${deviceName ?? "(no device)"}: '
    '${cfg.activeLayout.label}',
  );
}

/// True while [applyMonitoringForDevice] writes restored state into the
/// providers (their listeners fire synchronously on `set`). Suppresses the
/// persistence path so a restore can never write back to disk.
bool _applyingMonitoring = false;

/// Persist the current monitoring config + labels under the name of the
/// device they belong to ([monitoringDeviceNameProvider]). No-op before
/// the first apply, when no device was resolved, or while a restore is
/// being applied (restore is read-only).
void persistMonitoringForDevice(WidgetRef ref) {
  if (_applyingMonitoring) return;
  final name = ref.read(monitoringDeviceNameProvider);
  if (name == null) return;
  final cfg = ref.read(monitoringConfigProvider);
  final labels = ref.read(outputLabelsProvider);
  saveMonitoringForDevice(name, cfg, labels).then(
    (_) {},
    onError: (Object e) =>
        Log.w(LogCat.session, 'Failed to persist monitoring config', e),
  );
}

/// Shows a one-shot SnackBar if the engine is initialised but no audio
/// output device was successfully opened. Called after audio-settings
/// restore (so a saved-device reconfigure can recover first) and from the
/// AppShell tick when playback finds the audio thread stopped.
void _notifyIfAudioOutputUnavailable(WidgetRef ref, BuildContext context) {
  if (_audioOutputUnavailableNotified) return;
  if (!context.mounted) return;
  final engine = ref.read(eclipsaStudioEngineProvider);
  if (engine == null) return;
  if (engine.isAudioThreadRunning) return;
  final err = engine.lastDeviceError;
  // Commit the flag only once the SnackBar is actually shown. If there is
  // no ScaffoldMessenger in scope yet (e.g. landing screen), leave it
  // false so a later call still has a chance to surface the failure.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    if (_audioOutputUnavailableNotified) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _audioOutputUnavailableNotified = true;
    final detail = err.isNotEmpty ? err : 'Check Settings → Audio.';
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: T.errorRed,
        duration: const Duration(seconds: 10),
        content: Text('Audio output unavailable. $detail'),
      ),
    );
  });
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

/// Reports a condition once it has held for [graceTicks] consecutive
/// ticks, once per occurrence: [tick] returns true on the tick the grace
/// period runs out and not again until the condition has cleared and
/// held once more. At 60 Hz the grace is one second, longer than a
/// session load's window between setting the elements and syncing the
/// engine (ES-693).
class _MismatchLatch {
  static const graceTicks = 60;

  int _held = 0;
  bool _warned = false;

  bool tick(bool mismatch) {
    if (!mismatch) {
      _held = 0;
      _warned = false;
      return false;
    }
    _held++;
    if (_warned || _held < graceTicks) return false;
    _warned = true;
    return true;
  }
}

class _AppShellState extends ConsumerState<AppShell>
    with SingleTickerProviderStateMixin, WindowListener {
  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  bool _wasPlaying = false;

  // The two Creator-mode meter mismatches the tick loop reports: the UI
  // has elements but the engine order is empty, and the engine order has
  // entries but the peaks are empty. Each is a latch with a grace
  // period (ES-693).
  final _emptyOrder = _MismatchLatch();
  final _emptyPeaks = _MismatchLatch();

  // Memoized per-slot mix-gain scales for Playback meters (ES-294).
  // PlaybackSession is immutable, so a presentation switch (or any
  // other change) replaces the object and invalidates this cache.
  PlaybackSession? _playbackScaleSession;
  List<double> _playbackScales = const [];

  List<double> _playbackMeterScales(PlaybackSession? session) {
    if (session == null) {
      _playbackScaleSession = null;
      _playbackScales = const [];
      return _playbackScales;
    }
    if (identical(session, _playbackScaleSession)) return _playbackScales;
    _playbackScaleSession = session;
    _playbackScales = computeMixMeterScales(session.selectedMix, [
      for (final ae in session.audioElements) ae.audioElementId,
    ]);
    return _playbackScales;
  }

  // AV-sync observability state (see _onTick).
  int _lastAudioFrames = -1;

  /// Playhead position at the end of the previous tick. The loop wrap
  /// (ES-535) is edge-triggered off this: it fires only when playback
  /// *crossed* the region end this tick, not whenever the playhead
  /// merely sits past it — a deliberate user placement after the
  /// region must stick (loop stays armed). Updated every tick, paused
  /// included, so "was already past the region when Play was pressed"
  /// never reads as a crossing.
  int _prevTickSamplePos = 0;
  int _stuckTickCount = 0;
  bool _noEngineWarned = false;

  /// Wall-clock stamp of the last user seek forwarded to the engine.
  /// The tick loop coalesces scrub storms (ES-473): during a drag every
  /// pointer move arms the seek flag at up to 60 Hz, but each forward
  /// costs the engine a decoder reposition + ring refill, so seeks
  /// are forwarded at most every [_kSeekForwardInterval]. A held-back
  /// seek stays armed and forwards on a later tick — the drag's final
  /// position always lands.
  DateTime _lastSeekForwardAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Minimum interval between forwarded user seeks (issue ES-473's
  /// ~50 ms). Comfortably above the engine's fade-out + post latency,
  /// below anything that would make scrubbing feel laggy. Tuned by
  /// ear (ES-473 QC): 80 ms with a shorter engine prime was tried and
  /// sounded worse than this setting.
  static const Duration _kSeekForwardInterval = Duration(milliseconds: 50);
  bool _audioThreadStuckWarned = false;

  // Latches the once-only "scan complete" log line for the active
  // playback session. Reset whenever the session is closed/reopened
  // by checking on a session-path change.
  bool _playbackScanCompletedLogged = false;
  String? _playbackScanWatchPath;

  // Audio-thread health diagnostics (see _pollAudioDiagnostics).
  int _prevCallbackCount = 0;
  int _prevDropoutCount = 0;
  int _prevOverrunCount = 0;
  int _prevUnderrunCount = 0;
  int _dropoutLoggedCount = 0;
  int _overrunLoggedCount = 0;
  int _underrunLoggedCount = 0;
  Duration _lastAudioRollupAt = Duration.zero;
  // First 10 per category keeps detailed per-event logs bounded; the
  // periodic rollup below still reports aggregate counts after that.
  static const int _maxLoggedPerAudioCategory = 10;
  static const Duration _audioRollupInterval = Duration(seconds: 10);

  /// Focus scope hosting the shell-level keyboard shortcuts (spacebar
  /// play/pause, zoom, etc). Held explicitly so we can re-request
  /// focus on it when the window regains focus after having been
  /// deactivated — otherwise Flutter's primary focus is left empty
  /// and shortcuts silently stop firing until the user clicks
  /// somewhere inside the app.
  final FocusScopeNode _shellScopeNode = FocusScopeNode(debugLabel: 'AppShell');

  @override
  void initState() {
    super.initState();
    windowManager.setPreventClose(true);
    windowManager.addListener(this);
    _ticker = createTicker(_onTick);
    _ticker.start();
    _fpsWindowStart = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _maybeReopenLastProject();
    _restorePreferences();
    // Engine-global settings (audio device + monitoring) are restored
    // once at launch by StartupRestore, which also owns the monitoring
    // engine-push/persist and device-shrink clamp listeners — those sit
    // above the workspace-mode switch so they apply on the landing screen
    // too, not only inside an open workspace.

    // Push the active mix presentation's IAMF metadata to OAR whenever
    // the active mix or sub-mix changes, so the renderer follows the
    // user's selection. Gain changes to the currently-active mix are
    // pushed directly from the mix view (see _ChannelStrip._update
    // and _OutputMixGainField._setOutputMixGain), and so is a mix deletion,
    // which can leave both indices unchanged (_confirmDeleteMix);
    // session-load gets a bulk push from
    // SessionNotifier._syncActiveMixGainsToEngine.
    ref.listenManual(
      activeMixProvider,
      (prev, next) => _pushActiveMixSettings(),
    );
    ref.listenManual(
      activeSubMixProvider,
      (prev, next) => _pushActiveMixSettings(),
    );
    // A notice raised before this shell mounted is already sitting in the
    // provider: a session load started from the landing screen raises its
    // missing-media (or profile-conflict) notice while the workspace is
    // still being built, and the build-time ref.listen below only fires on
    // changes. Replay it once the first frame is up (ES-628).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = ref.read(importNoticeProvider);
      if (pending != null) _onImportNotice(pending);
    });
    Log.i(LogCat.app, 'Eclipsa Studio started');
  }

  /// Surface one import notice: blockers and warnings as a dialog,
  /// informational notices as a SnackBar; then clear the provider.
  void _onImportNotice(ImportNotice next) {
    if (next.severity != ImportNoticeSeverity.info) {
      // A lingering info SnackBar behind the modal scrim is stale
      // context — hide it, matching the info branch.
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _showNoticeDialog(next);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(next.message, style: TextStyle(color: T.textPrimary)),
            backgroundColor: T.bgElevated,
          ),
        );
    }
    ref.read(importNoticeProvider.notifier).clear();
  }

  /// Forward IAMF mix metadata (per-element exclusion and mix gain,
  /// output mix gain, and element_rendering_config) for the
  /// currently-active mix and sub-mix to the C++ engine. Safe to call at
  /// any time — no-ops when the engine isn't ready or indices are out of
  /// range. The rendering configs are committed with a single OAR
  /// rebuild ([pushSubMixSettings]).
  void _pushActiveMixSettings() {
    final engine = ref.read(eclipsaStudioEngineProvider);
    final sub = activeSubMixOf(
      ref.read(mixesNotifierProvider),
      ref.read(activeMixProvider),
      ref.read(activeSubMixProvider),
    );
    if (engine == null || sub == null) return;
    pushSubMixSettings(engine, sub, ref.read(elementsProvider));
  }

  /// Restore AppShell-scoped settings from preferences. Loads the
  /// preferences JSON once and hands the map to the per-area appliers
  /// below — each _restore* used to call AppPreferences.load() itself,
  /// re-reading and re-parsing the same file five times on cold start.
  ///
  /// Each area applies under its own catch so one bad stored value
  /// (e.g. a wrong-typed pref that throws on the `as` cast) can't
  /// silently skip the areas after it.
  Future<void> _restorePreferences() async {
    final Map<String, dynamic> prefs;
    try {
      prefs = await AppPreferences.load();
    } on Exception catch (e) {
      Log.w(LogCat.session, 'Failed to load preferences', e);
      return;
    }
    if (!mounted) return;
    void apply(String area, void Function(Map<String, dynamic>) restore) {
      try {
        restore(prefs);
      } catch (e) {
        Log.w(LogCat.session, 'Failed to restore $area', e);
      }
    }

    apply('general settings', _restoreGeneralSettings);
    apply('last used dirs', _restoreLastDirs);
    apply('colormap', _restoreColormap);
  }

  void _restoreGeneralSettings(Map<String, dynamic> prefs) {
    final tdName = prefs[AppPreferences.kTimeDisplay] as String?;
    if (tdName != null) {
      final mode = TimeDisplayMode.values.where((m) => m.name == tdName);
      if (mode.isNotEmpty) {
        ref.read(timeDisplayProvider.notifier).restore(mode.first);
      }
    }
    final pfName = prefs[AppPreferences.kPlayheadFollow] as String?;
    if (pfName != null) {
      final mode = PlayheadFollowMode.values.where((m) => m.name == pfName);
      if (mode.isNotEmpty) {
        ref.read(playheadFollowProvider.notifier).restore(mode.first);
      }
    }
    final ros = prefs[AppPreferences.kReturnOnStop] as bool?;
    if (ros != null) {
      ref.read(returnOnStopProvider.notifier).restore(ros);
    }
    final vb = prefs[AppPreferences.kVideoBackend] as String?;
    if (vb != null) {
      ref.read(videoBackendProvider.notifier).restore(vb);
    }
  }

  /// Restores every remembered picker folder. Each notifier knows its own
  /// preference key, so adding one here is a single line — and forgetting
  /// it is the failure mode this loop exists to prevent.
  void _restoreLastDirs(Map<String, dynamic> prefs) {
    for (final n in <LastDirNotifier>[
      ref.read(lastImportDirProvider.notifier),
      ref.read(lastVideoImportDirProvider.notifier),
      ref.read(lastAdmDestDirProvider.notifier),
      ref.read(lastExportDirProvider.notifier),
      ref.read(lastLogExportDirProvider.notifier),
    ]) {
      final dir = prefs[n.prefKey] as String?;
      if (dir != null) n.restore(dir);
    }
  }

  void _restoreColormap(Map<String, dynamic> prefs) {
    final name = prefs[AppPreferences.kColormap] as String?;
    if (name != null) {
      ref.read(colormapProvider.notifier).restore(name);
    }
  }

  Future<void> _maybeReopenLastProject() async {
    // The session to auto-load (CLI --session, or the last-project
    // path resolved by the startup bootstrap in main.dart when
    // kReopenLastProject is on) is threaded through
    // autoLoadSessionProvider. AppShell only consumes it; it does not
    // re-decide kReopenLastProject here.
    //
    // The provider is overridden with the startup path for the life
    // of the ProviderScope, so subsequent AppShell mounts (triggered
    // by returning to landing and entering Creator again) would
    // re-read the same value and re-load the initial session —
    // silently overwriting whatever the user just selected. Guard
    // with a module-level flag so auto-load runs exactly once per
    // process.
    if (_autoLoadConsumed) return;
    _autoLoadConsumed = true;
    final autoPath = ref.read(autoLoadSessionProvider);
    if (autoPath == null) return;
    Log.i(LogCat.session, 'Auto-loading session: $autoPath');
    var loaded = false;
    try {
      loaded = await ref.read(sessionProvider.notifier).loadFile(autoPath);
    } on Exception catch (e) {
      Log.w(LogCat.session, 'Failed to auto-load session', e);
    } catch (e) {
      // Error subclasses (AssertionError, StateError, ...) too: under
      // --quit-after-load the process must always reach the verdict in
      // the finally below, or CI hangs on a window nobody will close.
      Log.e(LogCat.session, 'Unexpected error during auto-load: $e');
    } finally {
      if (ref.read(quitAfterLoadProvider)) {
        quitAfterStartupOpen(
          ref.read(eclipsaStudioEngineProvider),
          opened: loaded,
          what: 'session',
        );
      }
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    // Stamped before the shutdown guard below, so the timestamp does
    // not freeze at whatever tick preceded the teardown.
    _lastElapsed = elapsed;

    // Quit tears the engine down while the ticker is still running:
    // the exit handler awaits EclipsaStudioEngine.shutdown() and nothing
    // stops this ticker, which is disposed only in dispose() and that
    // does not run before the process exits. Every later tick would
    // read cleared meter state and report it as a fault — the false
    // "rawPeaks empty" warning that ends a normal quit — and keep
    // calling transport and meter entry points that do not check
    // whether the engine is initialised (ES-662).
    if (ref.read(eclipsaStudioEngineProvider)?.isShutDown ?? false) return;

    // Read meter values from C++ engine at display rate.
    _updateMetersFromEngine(dt);

    // Route audio-thread health counters through Log.* → JSONL.
    // The audio callback can't call engine_log() directly, so it writes
    // into shared meter state and we pick the changes up here.
    _pollAudioDiagnostics(elapsed);

    // Pick up the upstream lazy temporal-unit scan completion so the
    // timeline duration updates the moment the worker publishes a
    // total-frames value. `playbackOpen` returns immediately after
    // descriptor parse + codec init under the lazy path; `totalFrames`
    // stays 0 until this poll observes the worker finishing.
    _pollPlaybackScanState();

    // Whether a user seek was armed when this tick began. Captured
    // before the play-transition branch below consumes the flag (the
    // click-timeline-then-play fast path, ES-473) so the loop wrap
    // (ES-535) can still tell "the user just relocated the playhead"
    // apart from "playback ran past the region end".
    final seekArmedAtTickEntry = ref
        .read(transportProvider.notifier)
        .seekPending;

    // Sync transport state to C++ engine on transitions.
    final playing = ref.read(playingProvider);
    if (playing != _wasPlaying) {
      _wasPlaying = playing;
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine != null) {
        if (playing) {
          // Sync position before starting playback so the engine
          // begins from the current Dart playhead.
          final transport = ref.read(transportProvider);
          engine.transportSeek(transport.seconds);
          // The position is now synced — drain any armed user seek
          // (it would re-forward the same position) and stamp the
          // throttle, so click-timeline-then-play costs one engine
          // fade+prime cycle instead of two (ES-473).
          ref.read(transportProvider.notifier).consumeSeek();
          _lastSeekForwardAt = DateTime.now();
          engine.transportPlay();
        } else {
          engine.transportPause();
          // Clears the level meters so the bars/holds decay out, but
          // keeps the element and output-bus clip latches: overload
          // markers must survive a transport stop (ES-528) — they clear
          // on meter tap, mode switch, or session load.
          engine.meterResetLevels();
        }
      }
    }

    // Helper: forward any pending user seek to the engine. Only
    // consumes the seek flag when we actually have an engine to hand
    // it to, so a transient null engine does not silently lose the
    // seek (it will be re-attempted on the next tick). Forwards are
    // coalesced to one per _kSeekForwardInterval (ES-473): a held-back
    // seek stays armed and retries next tick, so the final position
    // of a drag always reaches the engine.
    bool seekThrottleOpen() =>
        DateTime.now().difference(_lastSeekForwardAt) >= _kSeekForwardInterval;
    void syncSeekIfPending(String reason) {
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine == null) {
        if (!_noEngineWarned &&
            ref.read(transportProvider.notifier).consumeSeek()) {
          _noEngineWarned = true;
          Log.w(LogCat.transport, 'Dropped $reason seek: engine unavailable');
        }
        return;
      }
      final notifier = ref.read(transportProvider.notifier);
      if (!notifier.seekPending || !seekThrottleOpen()) return;
      notifier.consumeSeek();
      engine.transportSeek(ref.read(transportProvider).seconds);
      _lastSeekForwardAt = DateTime.now();
    }

    // Helper: after an internal wrap relocation (loop wrap, timeline
    // end), sync the engine immediately so the next audio callback
    // reads from the wrap target (and the next tick's position read
    // reflects that), then drain the seek flag the relocation just
    // armed so the next tick does not re-issue the same seek.
    void syncWrapToEngine() {
      ref
          .read(eclipsaStudioEngineProvider)
          ?.transportSeek(ref.read(transportProvider).seconds);
      ref.read(transportProvider.notifier).consumeSeek();
    }

    // Helper: wrap the playhead to [sample] and sync the engine.
    // Uses seekSample — an internal relocation that must not move the
    // play-start mark (unlike a user seek).
    void wrapPlaybackTo(int sample) {
      ref.read(transportProvider.notifier).seekSample(sample);
      syncWrapToEngine();
    }

    // While paused: forward any pending scrub to the engine, OR pull
    // the engine's frame counter into Dart when no scrub is pending.
    // The pull handles the buffer or two the audio thread processes
    // between observing the pause flag and the next control-thread
    // read — without it, Dart's samplePosition lags engine.position,
    // and the seek-on-resume in the play-start branch rewinds the
    // playhead by ~10–20 ms.
    if (!playing) {
      final engine = ref.read(eclipsaStudioEngineProvider);
      final notifier = ref.read(transportProvider.notifier);
      if (engine == null) {
        // Don't drain the seek flag without an engine to forward to;
        // a transient null (e.g. mid-reconfigure) should retry next
        // tick. Mirrors the old syncSeekIfPending no-engine guard.
        if (!_noEngineWarned) {
          _noEngineWarned = true;
          Log.w(
            LogCat.transport,
            'No engine on paused tick — scrub will retry',
          );
        }
      } else if (notifier.seekPending) {
        // Coalesce scrub storms (ES-473): forward at most one seek per
        // _kSeekForwardInterval; a held-back seek retries next tick.
        // Crucially, do NOT fall through to the position pull below
        // while a seek is armed — it would stomp the dragged playhead
        // with the engine's pre-seek position.
        if (seekThrottleOpen()) {
          notifier.consumeSeek();
          engine.transportSeek(ref.read(transportProvider).seconds);
          _lastSeekForwardAt = DateTime.now();
        }
      } else if (engine.isAudioThreadRunning) {
        notifier.setSamplePosition(engine.transportPositionFrames());
      }
    }

    // Only when playing: advance transport.
    if (playing) {
      final looping = ref.read(loopingProvider);
      final loopRegion = ref.read(loopRegionProvider);

      // Handle user-initiated seeks first — sync engine before
      // reading the audio position back.
      syncSeekIfPending('playback');

      // Use the audio thread's position as ground truth (immune to
      // UI frame-rate drift that the old advance(dt) accumulator
      // suffered from, which caused cumulative A/V desync). Skipped
      // while a coalesced seek is still armed (ES-473): the engine
      // hasn't been told the new position yet, so pulling its counter
      // would stomp the dragged playhead back to the pre-seek spot.
      final eng = ref.read(eclipsaStudioEngineProvider);
      final seekHeld = ref.read(transportProvider.notifier).seekPending;
      if (eng != null && seekHeld) {
        // A coalesced seek is armed but not yet forwarded — hold the
        // dragged playhead as-is for this tick (≤ 50 ms) regardless
        // of device state; the read-back (or fallback advance)
        // resumes once the seek lands. Falling through to advance(dt)
        // here would walk the playhead the user is dragging.
      } else if (eng != null) {
        if (eng.isAudioThreadRunning) {
          final frames = eng.transportPositionFrames();
          // Source the rate from the engine, not transport.sampleRate:
          // `frames` is in engine-rate, so converting through any stale
          // transport rate scales audioSeconds by the rate ratio and
          // drift-seeks the video to the wrong time (ES-218).
          final sampleRate = eng.currentSampleRate;
          // Playback that reached the end since the last tick reads
          // past it by what the engine rendered since then: one tick
          // and one audio block, plus 100 ms for devices that deliver
          // blocks in bursts and for a late tick (ES-967).
          final pastEndTolerance =
              ((dt + 0.1) * sampleRate).ceil() + eng.currentBufferSize;
          ref
              .read(transportProvider.notifier)
              .setSamplePosition(frames, pastEndTolerance: pastEndTolerance);
          // Drift-correct the video player against the audio-thread
          // clock. The video listener in video_sync.dart handles
          // large jumps (>100 ms) from user seeks; this path handles
          // the gentle accumulated drift during continuous playback.
          if (sampleRate > 0) {
            final audioSeconds = frames / sampleRate;
            // Fire and forget — syncToAudio has its own in-flight
            // guard so we do not queue up calls on slow ticks. This
            // site is inside `if (playing)`, so playing is always true.
            ref
                .read(videoProvider.notifier)
                .syncToAudio(audioSeconds, playing: true);
          }
          // Stuck-position detection: if the audio thread is marked
          // running but its frame counter hasn't advanced for ~500 ms
          // of wall-clock time while we think we're playing, the
          // device is almost certainly hung. Log once.
          if (frames == _lastAudioFrames) {
            _stuckTickCount++;
            if (_stuckTickCount > 30 && !_audioThreadStuckWarned) {
              _audioThreadStuckWarned = true;
              Log.e(
                LogCat.transport,
                'Audio-thread position stuck at $frames '
                'while playing — device may be hung or xrun '
                'recovery failed.',
              );
            }
          } else {
            _lastAudioFrames = frames;
            _stuckTickCount = 0;
            _audioThreadStuckWarned = false;
          }
        } else {
          // Engine present but device never opened (or failed to
          // reopen). Fall back to UI-timer advance so the playhead
          // keeps moving, and warn once so the user knows no audio
          // is actually playing.
          if (!_audioThreadStuckWarned) {
            _audioThreadStuckWarned = true;
            Log.e(
              LogCat.transport,
              'Audio thread not running — playhead advancing on '
              'UI timer; no audio output. Check output device.',
            );
            _notifyIfAudioOutputUnavailable(ref, context);
          }
          ref.read(transportProvider.notifier).advance(dt);
        }
      } else {
        // No engine at all — this is "engine dylib missing" territory.
        // Fall back to advance(dt) so the UI is not frozen, and warn
        // loudly once.
        if (!_noEngineWarned) {
          _noEngineWarned = true;
          Log.e(
            LogCat.engine,
            'Transport running in UI-timer fallback: C++ engine '
            'unavailable. No audio will play. Run ./build.sh run '
            'to build the engine.',
          );
        }
        ref.read(transportProvider.notifier).advance(dt);
      }

      final updated = ref.read(transportProvider);

      // Whether the playhead has run into the timeline end (shared by
      // the loop-region and plain end-of-timeline branches below).
      final atTimelineEnd = shouldWrapAtTimelineEnd(
        pos: updated.samplePosition,
        durationSamples: updated.durationSamples,
      );

      // Loop region boundary check (clamp to current duration).
      if (looping && loopRegion != null) {
        final effectiveEnd = loopRegion.endSample.clamp(
          0,
          updated.durationSamples,
        );
        final crossedLoopEnd = shouldLoopWrap(
          prevPos: _prevTickSamplePos,
          pos: updated.samplePosition,
          effectiveEnd: effectiveEnd,
          userSeekArmed: seekArmedAtTickEntry,
        );
        if (crossedLoopEnd) {
          wrapPlaybackTo(
            loopRegion.startSample.clamp(0, updated.durationSamples),
          );
        } else if (atTimelineEnd) {
          // Playhead was deliberately placed past the region and has
          // now run into the timeline end with looping armed: wrap to
          // the region start (region wins over 0, matching
          // returnToPlayStart's precedence). Level-triggered on
          // purpose — there is nothing past the timeline end to
          // respect a placement at.
          wrapPlaybackTo(
            loopRegion.startSample.clamp(0, updated.durationSamples),
          );
        }
      } else if (atTimelineEnd) {
        // End of timeline (the unknown-duration guard lives in
        // shouldWrapAtTimelineEnd).
        //
        // This is also what bounds video-only playback (ES-220): the
        // engine's frame counter free-runs (it has no media length —
        // and must keep advancing, since the silent audio thread is the
        // clock the video syncs to), so the stop is enforced here. The
        // timeline end is max(video, audio) — see _recalcDuration — so
        // a video-only session stops at the video's end.
        if (looping) {
          // resetPosition (not wrapPlaybackTo(0)): a whole-timeline
          // wrap also sets the play-start to 0.
          ref.read(transportProvider.notifier).resetPosition();
          syncWrapToEngine();
        } else {
          ref.read(playingProvider.notifier).stopAtTimelineEnd();
        }
      }

      // Follow playhead
      final followMode = ref.read(playheadFollowProvider);
      final overridden = ref.read(followOverrideProvider);
      if (followMode != PlayheadFollowMode.off && !overridden) {
        final vp = ref.read(timelineViewportProvider);
        if (vp.zoomLevel > 1.0) {
          final visibleFrac = 1.0 / vp.zoomLevel;
          final maxScroll = 1.0 - visibleFrac;
          if (maxScroll > 0) {
            final startFrac = vp.scrollOffset * maxScroll;
            final endFrac = startFrac + visibleFrac;
            final playhead = ref.read(transportProvider).fraction;

            if (followMode == PlayheadFollowMode.step) {
              if (playhead > endFrac) {
                final newStart = playhead - 0.1 * visibleFrac;
                final newScroll = (newStart / maxScroll).clamp(0.0, 1.0);
                ref
                    .read(timelineViewportProvider.notifier)
                    .setScroll(newScroll);
              }
            } else {
              final midFrac = startFrac + 0.5 * visibleFrac;
              if (playhead >= midFrac) {
                final newStart = playhead - 0.5 * visibleFrac;
                final newScroll = (newStart / maxScroll).clamp(0.0, 1.0);
                ref
                    .read(timelineViewportProvider.notifier)
                    .setScroll(newScroll);
              }
            }
          }
        }
      }
    }

    // Runs on every tick — paused included — so the loop wrap's
    // edge trigger (ES-535) always compares against where the playhead
    // actually was one tick ago.
    _prevTickSamplePos = ref.read(transportProvider).samplePosition;
  }

  /// Read meter values from the C++ audio engine.
  ///
  /// The audio thread writes meter data into shared memory; we just read it
  /// here at ~60 Hz for display. No simulation — real WAV data drives meters.
  ///
  // Bar bodies show the engine's short-window RMS (50 ms EMA — fast
  // attack without per-block flicker); peak-hold lines and clip
  // latches ride on the raw peaks. The exponential release is a floor
  // under the bars — it governs every fall (the 50 ms RMS decays
  // faster than this) including the pause fade, and sets the fall rate
  // for expired peak holds. The math lives in meters/meter_ballistics.dart
  // (pure, unit-tested); see kMeterReleaseDbPerSec there.

  // Peak-hold ballistics (fed the raw peaks — the RMS bars they
  // annotate always sit below them). Trackers are keyed by list
  // position, so they are reset whenever _meterOrderKey changes
  // (element add/remove/reorder, session swap, mode switch) — without
  // that, hold state would transfer to whatever element now occupies
  // the index.
  final NestedPeakHoldTracker _sidebarHoldTracker = NestedPeakHoldTracker();
  final NestedPeakHoldTracker _elementHoldTracker = NestedPeakHoldTracker();
  final PeakHoldTracker _outputHoldTracker = PeakHoldTracker();
  // Single-slot hold for the limiter's gain reduction. Fed dB of
  // reduction rather than a linear level — the tracker's attack /
  // hold / decay is value-agnostic, and dB is what the GR bar plots.
  final PeakHoldTracker _grHoldTracker = PeakHoldTracker();
  String _meterOrderKey = '';
  int _lastClipClearEpoch = 0;
  // Whether the last published AnimatedMetrics had all meters/holds at
  // zero. Starts true — AnimatedMetrics.initial() is all-zero.
  bool _publishedIdle = true;

  /// Current smoothed FPS from SchedulerBinding frame timings.
  int _currentFps = 0;
  int _frameCount = 0;
  late DateTime _fpsWindowStart;

  void _onFrameTimings(List<FrameTiming> timings) {
    _frameCount += timings.length;
    final now = DateTime.now();
    final elapsed = now.difference(_fpsWindowStart).inMilliseconds;
    if (elapsed >= 500) {
      _currentFps = (_frameCount * 1000 / elapsed).round();
      _frameCount = 0;
      _fpsWindowStart = now;
    }
  }

  void _updateMetersFromEngine(double dt) {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;

    // Per-tick linear release multiplier from the dB/s rate. dt is the
    // real wall-clock delta, unclamped above: after the ticker was
    // suspended (window hidden/occluded) the first tick spans the whole
    // gap, and the release fast-forwards through it so stale levels
    // collapse to idle instead of re-animating their fall (ES-452).
    final dtc = sanitizeMeterDt(dt);
    final decayFactor = meterDecayFactor(dtc);

    // A meter tap bumps the clip-clear epoch: clear the engine's sticky
    // clip flags (element and output-bus alike; during playback the
    // audio thread applies it on its next block).
    final clipEpoch = ref.read(clipClearEpochProvider);
    if (clipEpoch != _lastClipClearEpoch) {
      _lastClipClearEpoch = clipEpoch;
      engine.meterResetClips();
    }

    final playing = ref.read(playingProvider);
    final rawPeaks = engine.readMeterPeaks();
    final rawRms = engine.readMeterRms();
    final rawClips = engine.readMeterClips();
    final rawSh = playing ? engine.readShSnapshots() : const <List<double>>[];
    final loudness = engine.readLoudness();
    final current = ref.read(animatedMetricsProvider);
    final prev = current.sidebarMeters;
    final prevRaw = current.elementMeters;

    final mode = ref.read(workspaceModeProvider);
    // Per-element meter data mapped to UI element order. Bar bodies are
    // driven by the short-window RMS (smooth but responsive); the raw
    // peaks feed the peak-hold lines and the clip latch. Clip flags
    // latch engine-side at the element meter tap (pre mix-gain), so a
    // clipped channel can show a bar below 0 dB when mix gains
    // attenuate — accepted.
    final uiPeaksRaw = <List<double>>[];
    final uiPeaks = <List<double>>[];
    final uiRmsRaw = <List<double>>[];
    final uiRms = <List<double>>[];
    final uiSh = <List<double>>[];
    final uiClips = <List<bool>>[];
    // Identifies the element order the meter rows were built for —
    // used to reset the positional peak-hold trackers on change.
    final String orderKey;

    // Append engine slot [slot]'s meter data (or empty rows when the
    // slot is absent), scaled by the linear mix gain [g]. Aliasing the
    // pool-backed rows for the g == 1.0 cases is safe only because
    // they are consumed synchronously below (_applyMeterDecay and the
    // hold trackers copy before returning); uiSh and uiClips are
    // retained in AnimatedMetrics, so those always copy.
    void addMappedSlot(int? slot, double g) {
      if (slot != null && slot < rawPeaks.length) {
        final rp = rawPeaks[slot];
        uiPeaksRaw.add(rp);
        uiPeaks.add(g == 1.0 ? rp : [for (final v in rp) v * g]);
      } else {
        uiPeaksRaw.add(const <double>[]);
        uiPeaks.add(const <double>[]);
      }
      if (slot != null && slot < rawRms.length) {
        final rr = rawRms[slot];
        uiRmsRaw.add(rr);
        uiRms.add(g == 1.0 ? rr : [for (final v in rr) v * g]);
      } else {
        uiRmsRaw.add(const <double>[]);
        uiRms.add(const <double>[]);
      }
      uiClips.add(
        slot != null && slot < rawClips.length
            ? List<bool>.from(rawClips[slot])
            : const <bool>[],
      );
      if (slot != null && slot < rawSh.length) {
        final rs = rawSh[slot];
        uiSh.add([for (final v in rs) v * g]);
      } else {
        uiSh.add(const <double>[]);
      }
    }

    if (mode == WorkspaceMode.playback) {
      // Playback: AEs come from playbackSessionProvider; engine adds them
      // to AudioGraph in this same order during open_iamf, so the meter
      // slot is just the list index. The presentation's mix gains
      // (per-element gain + folded sub-mix output gain) are applied at
      // the mix-bus sum — after the per-element meter tap — so rescale
      // here or the scene ignores the presentation's balance (ES-294).
      // For the default presentation the engine follows the stream's
      // per-TU gains, which the Dart side cannot mirror; this static
      // default-gain rescale is an approximation there (same class the
      // probe flags for param-mode-0 elements).
      final session = ref.read(playbackSessionProvider);
      final aes = session?.audioElements ?? const <PlaybackAe>[];
      final scales = _playbackMeterScales(session);
      orderKey = 'p:${identityHashCode(session)}';
      for (var slot = 0; slot < aes.length; slot++) {
        addMappedSlot(slot, slot < scales.length ? scales[slot] : 1.0);
      }
    } else {
      // Creator: map engine-order peaks to UI order via engineOrderProvider.
      final engineOrder = ref.read(engineOrderProvider);
      final elements = ref.read(elementsProvider);

      // Build engine-slot lookup: element ID → engine slot index.
      final idToSlot = <int, int>{};
      for (var s = 0; s < engineOrder.length; s++) {
        idToSlot[engineOrder[s]] = s;
      }

      // Look up the active mix presentation's gains: per-element mix
      // gain plus the sub-mix's output mix gain, both applied at the
      // mix-bus sum — after the per-element meter tap — so fold them
      // into the levels here (ES-294).
      final mixes = ref.read(mixesNotifierProvider);
      final mixIdx = ref.read(activeMixProvider);
      final subIdx = ref.read(activeSubMixProvider);
      final activeSub =
          (mixIdx >= 0 &&
              mixIdx < mixes.length &&
              subIdx >= 0 &&
              subIdx < mixes[mixIdx].subMixes.length)
          ? mixes[mixIdx].subMixes[subIdx]
          : null;
      final outDb = activeSub?.outputMixGain ?? 0.0;

      orderKey = 'c:${elements.map((e) => e.id).join('.')}';

      // Produce per-element rows in UI order. The *Raw variants are
      // post-DSP only (element view); the others are scaled by mix
      // gains (mix/renderer view).
      for (final elem in elements) {
        final mgDb = (activeSub?.settingsFor(elem.id).mixGain ?? 0.0) + outDb;
        final mgLin = mgDb == 0.0 ? 1.0 : math.pow(10, mgDb / 20).toDouble();
        addMappedSlot(idToSlot[elem.id], mgLin);
      }

      // Mismatch warnings (Creator-mode only: Playback has no
      // engineOrderProvider to compare against). An empty engine order
      // is only a fault while the UI has elements to map; an empty
      // session has nothing to report. A session load sets the elements
      // and then awaits the video and the WAV info before it syncs the
      // engine, so the two disagree for a few hundred ms on every load,
      // which the latch's grace period covers (ES-693).
      if (_emptyOrder.tick(engineOrder.isEmpty && elements.isNotEmpty)) {
        Log.w(
          LogCat.meters,
          'engineOrder is empty but elements has ${elements.length} '
          'entries',
        );
      }
      if (_emptyPeaks.tick(rawPeaks.isEmpty && engineOrder.isNotEmpty)) {
        Log.w(
          LogCat.meters,
          'rawPeaks empty but '
          'engineOrder has ${engineOrder.length} entries',
        );
      }
    }

    // Bar bodies show RMS with the exponential release as a floor:
    // attacks track the engine's fast RMS integration directly, while
    // falls (including the pause fade) are clamped to the release
    // rate, which is slower than the 50 ms RMS decay.
    final bars = applyMeterDecay(uiRms, prev, playing, decayFactor);
    final elementBars = applyMeterDecay(
      uiRmsRaw,
      prevRaw,
      playing,
      decayFactor,
    );

    // Read output RMS/peaks from C++ (post-OAR render). RMS drives the
    // bars (with the same pause-fade floor); peaks drive the hold line
    // and clip latch.
    final rawOutput = playing ? engine.readOutputPeaks(32) : const <double>[];
    final rawOutputRms = playing ? engine.readOutputRms(32) : const <double>[];
    final prevOutput = current.meters;
    final outLen = math.max(rawOutputRms.length, prevOutput.length);
    final outputBars = decayRow(rawOutputRms, prevOutput, outLen, decayFactor);

    // Output clip flags are latched engine-side by the audio thread
    // (never misses an over between UI frames — same semantics as the
    // element flags) and cleared by meterResetClips only — the pause
    // meterResetLevels keeps the latches so overload markers survive
    // a transport stop (ES-528).
    final rawOutputClips = engine.readOutputClips(32);
    final outputClips = List<bool>.generate(
      outLen,
      (i) => i < rawOutputClips.length && rawOutputClips[i],
    );

    // The hold trackers are positional — drop their state when the
    // element order they were tracking changes.
    if (orderKey != _meterOrderKey) {
      _meterOrderKey = orderKey;
      _sidebarHoldTracker.reset();
      _elementHoldTracker.reset();
      _outputHoldTracker.reset();
    }

    // Peak-hold lines follow the raw peaks (not the RMS bars): instant
    // attack, 2 s hold, then the same dB/s fall as the bar release.
    // When paused the engine peaks are zeroed by meterResetLevels but
    // keep their shape, so held lines decay out naturally; the output
    // row loses its shape (rawOutput is empty), so substitute zeros
    // shaped like the fading bars.
    final sidebarHolds = _sidebarHoldTracker.update(uiPeaks, dtc, decayFactor);
    final elementHolds = _elementHoldTracker.update(
      uiPeaksRaw,
      dtc,
      decayFactor,
    );
    final outputHolds = _outputHoldTracker.update(
      playing ? rawOutput : List<double>.filled(outputBars.length, 0),
      dtc,
      decayFactor,
    );

    // Limiter gain reduction from shared memory (linear, 1.0 = none).
    final limiterGr = playing ? engine.limiterGr : 1.0;
    // ... and its peak hold, in dB of reduction as a positive magnitude.
    // Feeding 0 while stopped lets an existing hold fall away on the
    // same ballistics as the meters rather than freezing on screen.
    final limiterGrPeakDb = _grHoldTracker.update(
      [DbUtils.linearGrToDb(limiterGr)],
      dtc,
      decayFactor,
    )[0];

    // Engine CPU from shared memory (0.0–1.0 → 0–100%).
    final engineCpu = (engine.audioCpuLoad * 100).round();

    // Skip notifying watchers when nothing changed (all meters and
    // peak holds idle, clip flags unchanged BY VALUE — the lists are
    // rebuilt every frame, so identity would never match — status
    // values unchanged, AND loudness unchanged). The skip is gated on
    // _publishedIdle: the first tick where everything reaches zero
    // must still publish, or the provider keeps the previous frame's
    // last pre-floor values forever (a stuck ~1 px bar / peak line).
    final metersIdle =
        outputBars.every((v) => v == 0) &&
        bars.every((ch) => ch.every((v) => v == 0)) &&
        elementBars.every((ch) => ch.every((v) => v == 0)) &&
        outputHolds.every((v) => v == 0) &&
        sidebarHolds.every((ch) => ch.every((v) => v == 0)) &&
        elementHolds.every((ch) => ch.every((v) => v == 0));
    if (metersIdle &&
        _publishedIdle &&
        boolGridEquals(uiClips, current.elementClips) &&
        boolRowEquals(outputClips, current.outputClips) &&
        limiterGr == current.limiterGr &&
        // Not covered by metersIdle: the hold decays on its own clock,
        // so skipping while it falls would freeze the line on screen.
        limiterGrPeakDb == current.limiterGrPeakDb &&
        engineCpu == current.engineCpu &&
        _currentFps == current.fps &&
        loudness.lufsIntegrated == current.lufsIntegrated &&
        loudness.truePeak == current.truePeak &&
        loudness.lufsMomentary == current.lufsMomentary &&
        loudness.lufsShortTerm == current.lufsShortTerm) {
      return;
    }
    _publishedIdle = metersIdle;

    ref
        .read(animatedMetricsProvider.notifier)
        .set(
          AnimatedMetrics(
            meters: outputBars,
            sidebarMeters: bars,
            elementMeters: elementBars,
            shSnapshots: playing ? uiSh : const [],
            meterPeakHolds: outputHolds,
            sidebarPeakHolds: sidebarHolds,
            elementPeakHolds: elementHolds,
            elementClips: uiClips,
            outputClips: outputClips,
            lufsIntegrated: loudness.lufsIntegrated,
            truePeak: loudness.truePeak,
            lufsMomentary: loudness.lufsMomentary,
            lufsShortTerm: loudness.lufsShortTerm,
            limiterGr: limiterGr,
            limiterGrPeakDb: limiterGrPeakDb,
            engineCpu: engineCpu,
            fps: _currentFps,
          ),
        );
  }

  /// Read audio-thread health counters from shared memory and emit
  /// Log.w / Log.i messages for any new events.
  ///
  /// Per-callback diagnostics are too frequent to log individually, so
  /// the audio callback writes counters into EclipsaStudioMeterState and we
  /// surface them here on the UI thread — which then routes them
  /// through the normal Log → JSONL pipeline.
  void _pollAudioDiagnostics(Duration elapsed) {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;

    // Forward C++ log messages staged in the engine's log ring (all
    // engine_log()/engine_log_rt() traffic) into the JSONL pipeline.
    // EclipsaStudioEngine's periodic timer is the baseline drain; draining
    // here too gives per-frame latency while a session is open.
    engine.drainRtLogs();

    final diag = engine.readAudioDiagnostics();

    // Device restart (stop + start) resets the engine counters to 0.
    // When that happens, rebase our prev counters and reset throttles
    // so the next run gets its own fresh first-N detailed logs.
    if (diag.callbackCount < _prevCallbackCount ||
        diag.dropoutCount < _prevDropoutCount ||
        diag.overrunCount < _prevOverrunCount ||
        diag.underrunCount < _prevUnderrunCount) {
      _prevCallbackCount = 0;
      _prevDropoutCount = 0;
      _prevOverrunCount = 0;
      _prevUnderrunCount = 0;
      _dropoutLoggedCount = 0;
      _overrunLoggedCount = 0;
      _underrunLoggedCount = 0;
      _lastAudioRollupAt = Duration.zero;
    }

    // First-callback transition (0 → ≥1): log once per device run so
    // there's a breadcrumb in the JSONL file confirming the audio
    // thread actually fired.
    if (_prevCallbackCount == 0 && diag.callbackCount > 0) {
      Log.i(
        LogCat.audio,
        'Audio thread started — first callback observed '
        '(cpu=${(diag.cpuLoad * 100).toStringAsFixed(1)}%)',
      );
    }
    _prevCallbackCount = diag.callbackCount;

    // Detailed per-event logging, capped so a flaky device doesn't
    // spam the log file.  Once the cap is hit we rely on the periodic
    // rollup below to surface further activity.
    final dropoutDelta = diag.dropoutCount - _prevDropoutCount;
    if (dropoutDelta > 0) {
      if (_dropoutLoggedCount < _maxLoggedPerAudioCategory) {
        final suffix = dropoutDelta > 1 ? ' (+${dropoutDelta - 1} more)' : '';
        Log.w(
          LogCat.audio,
          'AUDIO DROPOUT: '
          'behind=${diag.lastDropoutBehindMs.toStringAsFixed(2)}ms '
          'period=${diag.lastDropoutPeriodMs.toStringAsFixed(2)}ms '
          'cb=${diag.lastDropoutCb} total=${diag.dropoutCount}$suffix',
        );
        _dropoutLoggedCount++;
      }
      _prevDropoutCount = diag.dropoutCount;
    }

    final overrunDelta = diag.overrunCount - _prevOverrunCount;
    if (overrunDelta > 0) {
      if (_overrunLoggedCount < _maxLoggedPerAudioCategory) {
        final suffix = overrunDelta > 1 ? ' (+${overrunDelta - 1} more)' : '';
        Log.w(
          LogCat.audio,
          'AUDIO OVERRUN: '
          'elapsed=${diag.lastOverrunElapsedMs.toStringAsFixed(2)}ms '
          'period=${diag.lastOverrunPeriodMs.toStringAsFixed(2)}ms '
          'cb=${diag.lastOverrunCb} total=${diag.overrunCount}$suffix',
        );
        _overrunLoggedCount++;
      }
      _prevOverrunCount = diag.overrunCount;
    }

    final underrunDelta = diag.underrunCount - _prevUnderrunCount;
    if (underrunDelta > 0) {
      if (_underrunLoggedCount < _maxLoggedPerAudioCategory) {
        final suffix = underrunDelta > 1 ? ' (+${underrunDelta - 1} more)' : '';
        Log.w(
          LogCat.audio,
          'RING UNDERRUN: '
          'element=${diag.lastUnderrunElement} '
          'missing=${diag.lastUnderrunMissing} frames '
          'total=${diag.underrunCount}$suffix '
          '(${diag.underrunFrames} frames shorted)',
        );
        _underrunLoggedCount++;
      }
      _prevUnderrunCount = diag.underrunCount;
    }

    // Periodic rollup (every ~10 s while anything bad has happened).
    // Matches the cadence of the old C++-side summary so reading the
    // log file for dropout context is unchanged.
    if (elapsed - _lastAudioRollupAt >= _audioRollupInterval) {
      _lastAudioRollupAt = elapsed;
      if (diag.dropoutCount > 0 ||
          diag.overrunCount > 0 ||
          diag.underrunCount > 0) {
        Log.i(
          LogCat.audio,
          'audio stats: cb=${diag.callbackCount} '
          'drops=${diag.dropoutCount} overruns=${diag.overrunCount} '
          'underruns=${diag.underrunCount} '
          '(${diag.underrunFrames} frames) '
          'cpu=${(diag.cpuLoad * 100).toStringAsFixed(1)}%',
        );
      }
    }
  }

  /// Poll the upstream IAMF lazy-scan state and refresh the timeline
  /// duration once `total_samples_ready` flips. The upstream
  /// `IamfStreamFactory::OpenFromBytes` is configured with
  /// `lazy_temporal_unit_scan = true`, so `playbackOpen` returns after
  /// descriptor parse + codec init (~1-2 s on a 543 MB Opus IAMF) and
  /// runs the temporal-unit scan on a worker thread. The transport
  /// duration is unknown until the worker finishes; this poll makes
  /// the duration appear retroactively without blocking the open path.
  ///
  /// No-op outside Playback mode: `playbackStatus()` returns
  /// `sessionOpen == false` whenever no IAMF session is open, which
  /// short-circuits before any provider writes.
  void _pollPlaybackScanState() {
    final session = ref.read(playbackSessionProvider);
    if (session == null) {
      // Reset latches so the next opened session re-arms the
      // single-shot completion log.
      if (_playbackScanWatchPath != null) {
        _playbackScanWatchPath = null;
        _playbackScanCompletedLogged = false;
      }
      return;
    }
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) return;

    if (_playbackScanWatchPath != session.path) {
      _playbackScanWatchPath = session.path;
      _playbackScanCompletedLogged = false;
    }

    // Once the duration is published and we've already mirrored it to
    // the transport, there's nothing left to poll for.
    if (_playbackScanCompletedLogged) return;

    final status = engine.playbackStatus();
    if (!status.sessionOpen) return;
    if (!status.totalSamplesReady) return;

    final newTotal = status.totalFrames;
    if (newTotal <= 0) return;
    if (newTotal != session.totalFrames) {
      ref.read(playbackSessionProvider.notifier).updateTotalFrames(newTotal);
      // newTotal is in FILE frames; publish via the shared helper so
      // the duration lands in engine-rate frames like the open path —
      // publishing file frames here flipped the transport's clock
      // unit mid-session for mismatched-rate files (ES-34).
      publishPlaybackDuration(
        ref,
        fileFrames: newTotal,
        fileRate: session.sampleRate,
      );
    }
    // Confirm the provider write committed before latching, so a
    // never-mirrored value can't strand the Inspector header on
    // "Computing…".
    final mirrored = ref.read(playbackSessionProvider);
    if (mirrored == null || mirrored.totalFrames != newTotal) return;
    _playbackScanCompletedLogged = true;
    Log.i(
      LogCat.app,
      'IAMF lazy scan complete: total_frames=$newTotal '
      '(rate=${session.sampleRate}, '
      'duration=${(newTotal / session.sampleRate).toStringAsFixed(1)}s)',
    );
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    windowManager.removeListener(this);
    // Releasing the listener without clearing preventClose would
    // strand the window: the OS keeps swallowing close requests but
    // nobody is left to honor them. Restore default close handling so
    // the landing screen (which has no WindowListener) can still quit.
    // On Windows, close interception must STAY armed after the
    // workspace unmounts: main() owns it for the whole process
    // lifetime, and _EclipsaStudioAppState.onWindowClose handles
    // closes whenever no workspace is mounted (ES-390). macOS disarms
    // here as before so a plain window close works from the landing
    // screen.
    if (!Platform.isWindows) {
      unawaited(windowManager.setPreventClose(false));
    }
    _shellScopeNode.dispose();
    _ticker.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  @override
  void onWindowEnterFullScreen() => _refreshVideoSurfaceFrame();

  @override
  void onWindowLeaveFullScreen() => _refreshVideoSurfaceFrame();

  // A pull-based video backend (AVFoundation) composites a black texture
  // after the render surface is rebuilt for a fullscreen transition until a
  // frame is re-pushed; nudge the current (paused) frame back out once the
  // transition completes. No-op for free-running backends / during playback.
  void _refreshVideoSurfaceFrame() {
    ref.read(videoProvider.notifier).refreshSurfaceFrame();
  }

  // Notice-dialog serialization (ES-184, ES-490): warnings and blockers in
  // quick succession (a session load can raise several) must not stack
  // modals. While one is open, queue the rest in arrival order and
  // show them one at a time as each closes.
  bool _noticeDialogOpen = false;
  final List<ImportNotice> _pendingNoticeDialogs = [];

  void _showNoticeDialog(ImportNotice notice) {
    if (_noticeDialogOpen) {
      _pendingNoticeDialogs.add(notice);
      return;
    }
    _noticeDialogOpen = true;
    final dialog = notice.blocker
        ? showImportErrorDialog(context, notice.message)
        : showWarningDialog(
            context,
            title: notice.title ?? 'Warning',
            message: notice.message,
            actionLabel: notice.actionLabel,
            onAction: notice.onAction,
          );
    dialog.whenComplete(() {
      _noticeDialogOpen = false;
      if (_pendingNoticeDialogs.isNotEmpty && mounted) {
        _showNoticeDialog(_pendingNoticeDialogs.removeAt(0));
      }
    });
  }

  @override
  void onWindowFocus() {
    // When the main window regains focus (e.g. after the user Cmd-
    // Tabs back from another app), Flutter's primary focus is often
    // left empty, which silently disables our shell-level keyboard
    // shortcuts until the user clicks inside the app. Re-request
    // focus on our scope so spacebar play/pause etc. keep working.
    //
    // `hasFocus` (not `hasPrimaryFocus`) is the right check: if a
    // descendant TextField was being edited when the window lost
    // focus, it may still be the primary focus node on re-activation
    // — `hasFocus` is true in that case and we must NOT steal focus
    // back, or we'd tear the user's in-progress edit apart. Only
    // re-request when the whole subtree is genuinely unfocused.
    if (!_shellScopeNode.hasFocus) {
      _shellScopeNode.requestFocus();
    }
  }

  Future<void> _handleWindowClose() async {
    if (!await confirmExit(context, ref)) return;
    // Take the video pop-out down with the main window. The pop-out is
    // its own OS window, so with it still open, closing this window
    // does not quit the app on macOS (quit-on-last-window-close never
    // fires) — the workspace lives on headless, audio rolling, until
    // the pop-out is closed by hand. shutdown() closes the pop-out and
    // marks the video notifier shut down, which also stops the
    // pop-out's answering 'closed' notify from reloading the clip into
    // the now-dead window. The pop-out's multi-step close is not
    // awaited: both windows go away concurrently, and macOS terminates
    // the app once the pop-out (the last window) finishes closing.
    if (ref.read(videoProvider).isPoppedOut) {
      // The user chose to close: a failing pop-out shutdown must not keep
      // the window open with the exit half done.
      try {
        await ref.read(videoProvider.notifier).shutdown();
      } on Object catch (e, st) {
        Log.e(LogCat.video, 'Pop-out shutdown on close failed: $e', st);
      }
    }
    // preventClose is now off, so requestWindowClose() terminates
    // directly — a hard process kill on Windows (avoids the ANGLE
    // GL-teardown crash from plugin shutdown), close() on macOS.
    await windowManager.setPreventClose(false);
    markExitConfirmed(ref);
    await requestWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when theme changes so T.* colors are re-evaluated.
    ref.watch(themeModeProvider);
    final activeTab = ref.watch(activeTabProvider);

    // Show error snackbar when session operations fail
    ref.listen(sessionProvider.select((s) => s.lastError), (prev, next) {
      if (next != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next), backgroundColor: T.errorRed),
        );
        ref.read(sessionProvider.notifier).clearError();
      }
    });

    // Surface audio/video import feedback (rejected files, decode
    // errors, element-limit overflow, etc.) from `importNoticeProvider`
    // — see drop/picker handlers in `elements_view.dart` and
    // `video_panel.dart`. Blockers (nothing was imported, ES-184) and
    // warnings (something is wrong but the operation completed, ES-490)
    // get a dialog — a bottom-of-window SnackBar is too easy to miss
    // for anything that needs attention. Informational notices (the
    // operation succeeded, possibly with caveats) keep the SnackBar,
    // styled distinctly from `sessionProvider.lastError` — they are
    // not errors, so neutral elevated-surface color, not `T.errorRed`.
    ref.listen(importNoticeProvider, (prev, next) {
      if (next != null) _onImportNotice(next);
    });

    // Menu bar lives at the app root in AppMenuBar so there is exactly
    // one PlatformMenuBar mounted across landing + workspace.
    return Scaffold(
      backgroundColor: T.bgDeep,
      // A FocusScope (not a plain Focus) so that when a TextField
      // calls unfocus() — default disposition UnfocusDisposition.scope
      // — focus walks UP to this scope and stops, instead of
      // leaping past it to the root MaterialApp scope where our
      // key handler isn't attached. Without this, spacebar
      // play/pause silently stops working after any inline edit.
      //
      // Shortcuts stand down only while a text editor has focus — those
      // key events are typing, not commands. Any other focused
      // descendant (a button, a list row, the 3D renderer) must NOT
      // block them: Space is the universal transport key (ES-79), and
      // handling it here during the bubble phase also keeps it from
      // reaching the app-level ActivateIntent shortcut that would
      // "click" the focused button instead (the intermittent
      // Space-opens-the-import-dialog bug).
      //
      // The tab shortcuts (Cmd+digit on macOS, Ctrl+digit elsewhere)
      // are the exception: they type nothing, so they are matched
      // before the text-field check. A field in the tab being left
      // loses focus, because the IndexedStack excludes hidden tabs from
      // focus.
      body: FocusScope(
        node: _shellScopeNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          final tab = workspaceTabForKey(
            event,
            ref.read(workspaceModeProvider),
          );
          if (tab != null) {
            ref.read(activeTabProvider.notifier).set(tab);
            return KeyEventResult.handled;
          }
          return textInputHasFocus()
              ? KeyEventResult.ignored
              : _handleKey(event);
        },
        child: _buildBody(activeTab),
      ),
    );
  }

  Widget _buildBody(String activeTab) {
    // Inline / pop-out mode (video fullscreen lives in the pop-out window).
    // Pop-out opens a separate window — main UI stays visible.
    return Stack(
      children: [
        const VideoTransportSync(),
        const DirtyTracker(),
        Column(
          children: [
            const Topbar(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    VideoPanel(
                      maxHeight: videoPanelMaxHeight(constraints.maxHeight),
                    ),
                    Expanded(child: _buildContent(activeTab)),
                  ],
                ),
              ),
            ),
            const Statusbar(),
          ],
        ),
      ],
    );
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Space — toggle play/stop via the shared transport toggle
    // (analyzing guard and return-on-stop behaviour live there).
    // Always handled: even when the toggle swallows a start (IAMF
    // duration scan running) the key must not fall through and
    // activate a focused button. Works with the pop-out window open
    // too — that window is its own Flutter engine, so its key events
    // never reach this handler, and ours never reach it.
    if (key == LogicalKeyboardKey.space) {
      ref.read(playingProvider.notifier).toggleTransport();
      return KeyEventResult.handled;
    }

    // +/= — zoom in
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.numpadAdd) {
      ref.read(timelineViewportProvider.notifier).zoomByAroundPlayhead(1.25);
      return KeyEventResult.handled;
    }

    // - — zoom out
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      ref.read(timelineViewportProvider.notifier).zoomByAroundPlayhead(0.8);
      return KeyEventResult.handled;
    }

    // 0 — reset zoom
    if (key == LogicalKeyboardKey.digit0) {
      ref.read(timelineViewportProvider.notifier).setZoom(1.0);
      ref.read(timelineViewportProvider.notifier).setScroll(0.0);
      return KeyEventResult.handled;
    }

    // Escape — clear loop region
    if (key == LogicalKeyboardKey.escape) {
      final region = ref.read(loopRegionProvider);
      if (region != null) {
        ref.read(loopRegionProvider.notifier).clear();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // L — toggle looping. Bare key only: Cmd/Ctrl+L is the Loudness
    // Report menu accelerator (app_menu_bar.dart); the native macOS
    // menu consumes it before this handler, but the guard keeps the
    // two bindings from colliding on any path that reaches us.
    if (key == LogicalKeyboardKey.keyL &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isControlPressed) {
      ref.read(loopingProvider.notifier).toggle();
      return KeyEventResult.handled;
    }

    // D — toggle monitor DIM (ES-629). Bare key only, same guard as L;
    // global so it works from every view, and the text-field check at
    // the FocusScope above keeps it out of typing.
    if (key == LogicalKeyboardKey.keyD &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isControlPressed) {
      ref.read(monitorDimProvider.notifier).toggle();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // Tab id → index in the IndexedStack below. Kept stable so a tab
  // switch never rebuilds the underlying view (e.g. the 3D renderer's
  // GL context is created once and reused).
  static const _tabStackIndex = <String, int>{
    WorkspaceTabs.elements: 0,
    WorkspaceTabs.mix: 1,
    WorkspaceTabs.renderer: 2,
    WorkspaceTabs.inspector: 3,
  };

  Widget _buildContent(String tab) {
    final index = _tabStackIndex[tab] ?? 0;
    return IndexedStack(
      index: index,
      children: const [
        ElementsView(),
        MixView(),
        RendererView(),
        InspectorView(),
      ],
    );
  }
}
