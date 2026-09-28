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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi_bridge.dart';
import '../logging/log.dart';
import '../meters/meter_provider.dart';
import '../session/app_preferences.dart';
import '../session/recent_qc_files.dart';
import '../session/recent_sessions.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../theme.dart';
import '../util/device_rate_tool.dart';
import '../video/video_backend_kind.dart';
import '../views/routing_matrix_view.dart';
import 'app_button.dart';
import 'app_dialog.dart';
import 'app_shell.dart' show applyMonitoringForDevice;
import 'asio_trademark_notice.dart';
import 'chrome_surface.dart';
import 'console_widgets.dart';
import 'dialog_shell.dart';
import 'eyebrow_label.dart';

// Common buffer sizes offered in the Audio tab.
const _kBufferSizes = [64, 128, 256, 512, 1024, 2048];

/// General-tab segmented option sets, at file level so the width test
/// (console_segment_width_test.dart) measures the real labels — a
/// label edit here is a label edit there.
const kTimeDisplayOptions = [
  (TimeDisplayMode.mmss, 'MM:SS'),
  (TimeDisplayMode.samples, 'Samples'),
];
const kPlayheadFollowOptions = [
  (PlayheadFollowMode.off, 'Off'),
  (PlayheadFollowMode.step, 'Step'),
  (PlayheadFollowMode.continuous, 'Continuous'),
];
// Derived from the generated theme registry rather than hand-listed, so
// adding a theme is a token file plus a registry entry with no code
// change here. Order follows AppThemeMode's declaration order, which is
// the order themes.json lists them in.
final kThemeOptions = [
  for (final mode in AppThemeMode.values) (mode, kThemeMeta[mode]!.label),
];

/// Last-selected settings tab index, remembered across dialog opens
/// within the same app session.
int _lastSettingsTab = 0;

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  /// Index of the Audio tab, for [show]'s `initialTab`. Must match the
  /// labels list in build().
  static const tabAudio = 1;

  /// Show the dialog. [initialTab] overrides the remembered
  /// last-selected tab — used by shortcuts that target a specific tab
  /// (e.g. double-clicking the status bar's audio device label).
  static void show(BuildContext context, {int? initialTab}) {
    // The check showAppDialog's id guard would make anyway, run
    // here so a request that opens nothing cannot move the tab the
    // next open lands on. The open dialog would not switch tab
    // either: it reads _lastSettingsTab once, at construction.
    if (isAppDialogOpen(SettingsDialog)) return;
    if (initialTab != null) _lastSettingsTab = initialTab;
    showAppDialog(
      context: context,
      id: SettingsDialog,
      builder: (_) => const SettingsDialog(),
    );
  }

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  final _scrollController = ScrollController();
  // Clamp in case _lastSettingsTab persisted from a previous build with
  // more tabs (the Session tab used to be index 2).
  int _tab = _lastSettingsTab.clamp(0, 2);

  // Transient status shown in the Audio tab. Audio changes apply instantly
  // on selection (no Apply step); this only surfaces a reconfigure failure.
  String? _applyStatus;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Apply an audio change immediately — reconfigure the engine, then
  /// persist + sync state on success. On failure the provider is left
  /// untouched so the selectors revert to the running configuration.
  Future<void> _applyAudio({int? deviceIndex, int? bufferSize}) async {
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) {
      setState(() => _applyStatus = 'Engine not available.');
      return;
    }
    final current = ref.read(audioSettingsProvider);
    final devIdx = deviceIndex ?? current.deviceIndex;
    final bs = bufferSize ?? current.bufferSize;
    // The sample rate is not selectable: the engine follows the
    // device's hardware rate (adopting it after open). Request the
    // current rate; a new device that runs something else corrects it.
    final sr = current.sampleRate;

    final rc = engine.reconfigure(
      deviceIndex: devIdx,
      sampleRate: sr,
      bufferSize: bs,
    );
    ref.read(audioConfigEpochProvider.notifier).bump();
    if (rc != 0) {
      setState(() => _applyStatus = 'Failed to switch audio (error $rc).');
      return;
    }
    // The engine adopts the device's hardware rate (never forcing the
    // device clock, ES-518) — store what is actually in effect, not what
    // was asked for. The rate itself is never persisted.
    final actualSr = engine.currentSampleRate;
    ref
        .read(audioSettingsProvider.notifier)
        .update(
          AudioSettings(
            deviceIndex: devIdx,
            sampleRate: actualSr,
            bufferSize: bs,
          ),
        );
    // Engine SR may have changed; re-pin the transport clock so the seek
    // round-trip engine_frames to Dart.samplePosition stays identity.
    ref.read(transportProvider.notifier).rebaseSampleRate(actualSr);
    // Persist by device name so it survives device reordering. In
    // follow-system-default mode the open device is whatever the OS
    // picked, not a user choice — leave the pinned name on disk so
    // switching follow off (or an old build) restores the last
    // explicit pick (ES-467).
    final entries = <String, dynamic>{AppPreferences.kAudioBufferSize: bs};
    if (!ref.read(followSystemDefaultProvider)) {
      entries[AppPreferences.kAudioDeviceName] = engine.deviceName(devIdx);
    }
    await AppPreferences.setAll(entries);
    if (mounted) setState(() => _applyStatus = null);
  }

  /// Sentinel value for the "System Default" entry in the output
  /// device picker — device indices are always >= 0.
  static const _kSystemDefault = -1;

  /// Enter follow-system-default mode (ES-467) and reopen onto the
  /// current OS default if that is not already the open device.
  Future<void> _enableFollowSystemDefault() async {
    ref.read(followSystemDefaultProvider.notifier).set(true);
    final devices = ref.read(audioDevicesProvider);
    final defaultIdx = devices.indexWhere((d) => d.isDefault);
    if (defaultIdx >= 0 &&
        defaultIdx != ref.read(audioSettingsProvider).deviceIndex) {
      await _applyAudio(deviceIndex: defaultIdx);
    }
  }

  /// Pin an explicitly picked device, leaving follow mode if it was
  /// on. Picking the device that is already open (e.g. the resolved
  /// default while following) only re-pins — no stream reopen.
  Future<void> _pickDevice(int idx) async {
    if (ref.read(followSystemDefaultProvider)) {
      ref.read(followSystemDefaultProvider.notifier).set(false);
    }
    if (idx == ref.read(audioSettingsProvider).deviceIndex) {
      final engine = ref.read(eclipsaStudioEngineProvider);
      if (engine != null) {
        await AppPreferences.set(
          AppPreferences.kAudioDeviceName,
          engine.deviceName(idx),
        );
      }
      return;
    }
    await _applyAudio(deviceIndex: idx);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild this dialog when the theme or font size changes while it
    // is open. NOTE: this does NOT reach const-constructed children —
    // Dart canonicalizes them and Element.updateChild short-circuits, so
    // any child that reads T.* must not be const at its call site (or
    // must watch these providers itself).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final timeDisplay = ref.watch(timeDisplayProvider);
    final devices = ref.watch(audioDevicesProvider);
    final currentSettings = ref.watch(audioSettingsProvider);

    return DialogShell(
      width: 800,
      height: 600,
      bodyFit: DialogBodyFit.expand,
      footerDivider: true,
      insetPadding: const EdgeInsets.all(40),
      actions: [DialogShell.done(context)],
      // The tab row is the dialog's head: it has no title, and the
      // Light theme draws the row on the head's ground.
      headBelow: Center(
        child: _TabBar(
          selected: _tab,
          labels: const ['General', 'Audio', 'Monitoring'],
          onChanged: (i) => setState(() {
            _tab = i;
            _lastSettingsTab = i;
          }),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tab content (scrollable, fills available space)
          Expanded(
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thumbColor: WidgetStatePropertyAll(
                  T.textGhost.withValues(alpha: 0.4),
                ),
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(3),
              ),
              child: Scrollbar(
                thumbVisibility: true,
                controller: _scrollController,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(right: 14),
                  child: switch (_tab) {
                    0 => _buildGeneralTab(timeDisplay),
                    1 => _buildAudioTab(devices, currentSettings),
                    2 => _buildMonitoringTab(),
                    _ => throw StateError('Unknown settings tab: $_tab'),
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralTab(TimeDisplayMode timeDisplay) {
    // The concrete backend in effect (a stored `auto` maps to its resolved
    // kind). Drives the backend selector's current value.
    final videoBackend = resolveBackendKind(
      ref.watch(videoBackendProvider),
      currentTargetOs(),
    );

    // Option sets live at file level (kTimeDisplayOptions & co.) so
    // the width test measures the exact labels the controls render.
    final fontOptions = FontSizeMode.values.map((m) => (m, m.label)).toList();
    // Only explicit backends — `auto` is hidden since it currently just
    // aliases the platform default.
    final backendOptions = availableBackendKinds(currentTargetOs())
        .where((k) => k != VideoBackendKind.auto)
        .map((k) => (k, k.label))
        .toList();

    // One shared width -> all segmented controls form a stable column.
    // Measured (not hardcoded) so it tracks the font-size mode; this
    // build watches fontSizeModeProvider, so a mode switch recomputes
    // it in the same frame the labels rescale.
    final segWidth = ConsoleSegment.uniformWidth(context, [
      [for (final o in kTimeDisplayOptions) o.$2],
      [for (final o in kPlayheadFollowOptions) o.$2],
      [for (final o in fontOptions) o.$2],
      [for (final o in backendOptions) o.$2],
    ]);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EyebrowLabel('Playback'),
        const SizedBox(height: 12),
        _SettingsRow(
          label: 'Time display',
          description: 'Also toggleable by clicking the clock in the topbar.',
          control: ConsoleSegment<TimeDisplayMode>(
            width: segWidth,
            value: timeDisplay,
            options: kTimeDisplayOptions,
            onChanged: (v) => ref.read(timeDisplayProvider.notifier).set(v),
          ),
        ),
        const _RowGap(),
        _SettingsRow(
          label: 'Playhead follow',
          description: 'Auto-scroll timeline to keep the playhead visible.',
          control: ConsoleSegment<PlayheadFollowMode>(
            width: segWidth,
            value: ref.watch(playheadFollowProvider),
            options: kPlayheadFollowOptions,
            onChanged: (v) => ref.read(playheadFollowProvider.notifier).set(v),
          ),
        ),
        const _RowGap(),
        _SettingsRow(
          label: 'Return playhead on stop',
          description:
              'Snap the playhead back to where playback last started '
              'on Stop, Space, or end of timeline (non-loop). When '
              'Off, those actions pause in place.',
          control: ConsoleToggle(
            value: ref.watch(returnOnStopProvider),
            onChanged: (v) => ref.read(returnOnStopProvider.notifier).set(v),
          ),
        ),
        const _SectionGap(),
        const EyebrowLabel('Startup'),
        const SizedBox(height: 12),
        _SettingsRow(
          label: 'Reopen last project',
          description: 'Automatically load the most recent session on startup.',
          control: ConsoleToggle(
            value: ref
                .watch(reopenLastProjectProvider)
                .when(
                  data: (v) => v,
                  loading: () => false,
                  error: (_, _) => false,
                ),
            onChanged: (v) =>
                ref.read(reopenLastProjectProvider.notifier).set(v),
          ),
        ),
        const _SectionGap(),
        const EyebrowLabel('Appearance'),
        const SizedBox(height: 12),
        _SettingsRow(
          label: 'Theme',
          description: 'Switch the app\'s colours and controls.',
          control: ConsoleSelector<AppThemeMode>(
            width: 180,
            value: ref.watch(themeModeProvider),
            items: kThemeOptions,
            onChanged: (v) => ref.read(themeModeProvider.notifier).set(v),
          ),
        ),
        const _RowGap(),
        _SettingsRow(
          label: 'Font size',
          description: 'Scale UI text. Medium is the default.',
          control: ConsoleSegment<FontSizeMode>(
            width: segWidth,
            value: ref.watch(fontSizeModeProvider),
            options: fontOptions,
            onChanged: (v) => ref.read(fontSizeModeProvider.notifier).set(v),
          ),
        ),
        const _SectionGap(),
        const EyebrowLabel('Video'),
        const SizedBox(height: 12),
        _SettingsRow(
          label: 'Video backend',
          description:
              'Switching reloads the current video on the chosen backend.',
          control: ConsoleSegment<VideoBackendKind>(
            width: segWidth,
            value: videoBackend,
            options: backendOptions,
            onChanged: (v) => ref.read(videoBackendProvider.notifier).set(v),
          ),
        ),
        const _SectionGap(),
        const EyebrowLabel('Maintenance'),
        const SizedBox(height: 12),
        _SettingsRow(
          label: 'Reset to Defaults',
          description:
              'Resets all settings (except audio device configuration) '
              'and clears the Recent lists. Returns the app to a '
              'first-launch state.',
          control: AppButton(
            label: 'Reset',
            role: AppButtonRole.destructive,
            size: AppButtonSize.compact,
            onPressed: () {
              // Re-seed monitoring for the current device after the wipe
              // completes, so it refreshes live without a relaunch. Reset
              // keeps audio-device keys, so the device name stays valid.
              AppPreferences.reset()
                  .then((_) => applyMonitoringForDevice(ref))
                  .then(
                    (_) {},
                    onError: (Object e) => Log.w(
                      LogCat.session,
                      'Failed to re-apply monitoring after reset',
                      e,
                    ),
                  );
              RecentSessions.clear();
              RecentQcFiles.clear();
              T.setMode(T.defaultMode);
              T.setFontMode(FontSizeMode.medium);
              ref.invalidate(themeModeProvider);
              ref.invalidate(fontSizeModeProvider);
              // Not ref.invalidate: the provider is overridden in main()
              // with a startup-seed notifier, so invalidating rebuilds to
              // the launch-time value, not the default (see resetToDefault).
              ref.read(videoBackendProvider.notifier).resetToDefault();
              ref.invalidate(timeDisplayProvider);
              ref.invalidate(playheadFollowProvider);
              ref.invalidate(returnOnStopProvider);
              ref.invalidate(reopenLastProjectProvider);
              ref.invalidate(colormapProvider);
              // Monitoring (config + labels) is refreshed by the
              // applyMonitoringForDevice call sequenced after reset above.
              ref.read(recentSessionsProvider.notifier).refresh();
              ref.read(recentQcFilesProvider.notifier).refresh();
            },
          ),
        ),
        const SizedBox(height: 28),
        const EyebrowLabel('Storage Paths'),
        const SizedBox(height: 12),
        FutureBuilder<List<String>>(
          future: Future.wait([
            AppPreferences.path,
            RecentSessions.path,
            RecentQcFiles.path,
          ]),
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox.shrink();
            final paths = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PathRow(label: 'Settings', path: paths[0]),
                const SizedBox(height: T.gapSm),
                _PathRow(label: 'Recent sessions', path: paths[1]),
                const SizedBox(height: T.gapSm),
                _PathRow(label: 'Recent QC files', path: paths[2]),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildAudioTab(
    List<AudioDeviceInfo> devices,
    AudioSettings currentSettings,
  ) {
    final bufferSize = currentSettings.bufferSize;
    final sampleRate = currentSettings.sampleRate;
    final deviceIndex = currentSettings.deviceIndex;
    final mismatch = ref.watch(sampleRateMismatchProvider);

    final latencyMs = sampleRate > 0 ? (bufferSize / sampleRate * 1000) : 0.0;

    final selectedDevice = (devices.isNotEmpty && deviceIndex < devices.length)
        ? devices[deviceIndex]
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Output Device
        _SettingsRow(
          label: 'Output device',
          description:
              'Audio output used for monitoring. System Default '
              'follows the output selected in the OS.',
          // Not const: _UnavailableChip reads T.* — a const instance is
          // canonicalized and skips rebuilds on theme/font switches.
          control: devices.isEmpty
              ? _UnavailableChip()
              : ConsoleSelector<int>(
                  width: 220,
                  value: ref.watch(followSystemDefaultProvider)
                      ? _kSystemDefault
                      : (deviceIndex < devices.length ? deviceIndex : 0),
                  items: [
                    (_kSystemDefault, 'System Default'),
                    ...devices.map(
                      (d) => (
                        d.index,
                        d.isDefault ? '${d.name}  (default)' : d.name,
                      ),
                    ),
                  ],
                  onChanged: (v) => v == _kSystemDefault
                      ? _enableFollowSystemDefault()
                      : _pickDevice(v),
                ),
        ),
        // The picker enables ASIO when it lists an ASIO device, so the
        // Steinberg usage guidelines require the logo here (§1f).
        if (listsAsioDevice(devices)) ...[
          const SizedBox(height: T.gapSm),
          const AsioTrademarkNotice(),
        ],
        const _RowGap(),

        // Sample Rate — read-only: the engine adopts the device's
        // hardware rate (a rate mismatch causes clock-slip stutter),
        // so the rate is reported here, not selected. It is changed in
        // the OS tool ([deviceRateTool]); Eclipsa Studio adapts.
        _SettingsRow(
          label: 'Sample rate',
          description:
              'Follows the output device. Change it in '
              '$deviceRateTool; Eclipsa Studio adapts automatically.',
          control: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_formatRate(sampleRate), style: T.styleValue),
          ),
        ),
        if (mismatch != null) ...[
          const SizedBox(height: 4),
          Text(
            'Device hardware runs at ${_formatRate(mismatch.hwRate)} while '
            'the engine runs at ${_formatRate(mismatch.engineRate)}, so '
            'output is being resampled. Change the device rate in '
            '$deviceRateTool.',
            style: TextStyle(color: T.meterYellow, fontSize: T.fontBody),
          ),
        ],
        const _RowGap(),

        // Buffer Size
        _SettingsRow(
          label: 'Buffer size',
          description: 'Audio callback buffer in frames.',
          control: ConsoleSelector<int>(
            width: 160,
            value: _kBufferSizes.contains(bufferSize)
                ? bufferSize
                : _kBufferSizes.first,
            items: _kBufferSizes.map((b) => (b, '$b frames')).toList(),
            onChanged: (v) => _applyAudio(bufferSize: v),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Latency: ${latencyMs.toStringAsFixed(2)} ms',
          style: TextStyle(
            color: T.textTertiary,
            fontSize: T.fontBody,
            fontFamily: T.monoFamily,
          ),
        ),
        const _RowGap(),

        // Device info card (read-only)
        if (selectedDevice != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: T.decoControl(borderColor: T.border),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Device info',
                  style: TextStyle(
                    color: T.textSecondary,
                    fontSize: T.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _InfoRow(label: 'Name', value: selectedDevice.name),
                const SizedBox(height: 4),
                _InfoRow(
                  label: 'Max channels',
                  value: '${selectedDevice.maxChannels}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Audio applies instantly on selection; this surfaces a failure.
        if (_applyStatus != null)
          Align(
            alignment: Alignment.centerRight,
            child: Text(_applyStatus!, style: T.styleBodySecondary),
          ),
      ],
    );
  }

  static String _formatRate(int hz) {
    final k = hz / 1000.0;
    if (k == k.truncateToDouble()) {
      return '${k.toInt()} kHz';
    }
    return '${k.toStringAsFixed(1)} kHz';
  }

  Widget _buildMonitoringTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _ExposedTargetsSection(),
        const SizedBox(height: 24),
        Container(height: 1, color: T.border),
        const SizedBox(height: 24),
        // Not const: _SectionHeader reads T.* — a const instance is
        // canonicalized and skips rebuilds on theme/font switches.
        _SectionHeader(label: 'HEAD TRACKING'),
        const SizedBox(height: 8),
        Text('Coming soon.', style: T.styleCaption),
        const SizedBox(height: 24),
      ],
    );
  }
}

// Section header label.
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: T.fontBody,
        color: T.textMuted,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}

// ── Exposed targets — curated, switchable output set ───────────────────────
class _ExposedTargetsSection extends ConsumerWidget {
  const _ExposedTargetsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final config = ref.watch(monitoringConfigProvider);
    final devCh = ref.watch(outputDeviceChannelsProvider);
    final tooBig = config.targets
        .where((t) => t.layout.channels > devCh)
        .map((t) => t.layout.label)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Not const: _SectionHeader reads T.* (see the Monitoring tab).
            Expanded(child: _SectionHeader(label: 'MONITORING TARGETS')),
            const SizedBox(width: 8),
            _AddLayoutButton(config: config, deviceChannels: devCh),
            const SizedBox(width: 8),
            AppButton(
              label: 'Routing Matrix',
              size: AppButtonSize.compact,
              onPressed: () => RoutingMatrixView.open(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (tooBig.isNotEmpty) ...[
          _ClampWarning(labels: tooBig, deviceChannels: devCh),
          const SizedBox(height: 8),
        ],
        _ExposedTargetsList(config: config, deviceChannels: devCh),
      ],
    );
  }
}

class _ExposedTargetsList extends ConsumerWidget {
  final MonitoringConfig config;
  final int deviceChannels;
  const _ExposedTargetsList({
    required this.config,
    required this.deviceChannels,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(monitoringConfigProvider.notifier);
    final labels = ref.watch(outputLabelsProvider);
    final hwNames = ref.watch(outputChannelHardwareNamesProvider);
    final targets = config.targets;
    final canRemove = targets.length > 1;
    return Container(
      decoration: T.decoInset(),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: targets.length,
        onReorderItem: notifier.reorderTarget,
        itemBuilder: (context, i) {
          final t = targets[i];
          return _ExposedTargetRow(
            key: ValueKey(t.layout),
            index: i,
            target: t,
            active: t.layout == config.activeLayout,
            canRemove: canRemove,
            deviceChannels: deviceChannels,
            labels: labels,
            hwNames: hwNames,
            onLive: () => notifier.setActive(t.layout),
            onRemove: () => notifier.removeTarget(t.layout),
          );
        },
      ),
    );
  }
}

class _ExposedTargetRow extends StatelessWidget {
  final int index;
  final OutputTarget target;
  final bool active;
  final bool canRemove;
  final int deviceChannels;
  final Map<int, String> labels;
  final List<String> hwNames;
  final VoidCallback onLive;
  final VoidCallback onRemove;
  const _ExposedTargetRow({
    super.key,
    required this.index,
    required this.target,
    required this.active,
    required this.canRemove,
    required this.deviceChannels,
    required this.labels,
    required this.hwNames,
    required this.onLive,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final info = _targetInfo(target, deviceChannels, labels, hwNames);
    final unhealthy = info.exceeds || info.unrouted > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: T.border, width: 0.5)),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Icon(
                Icons.drag_indicator,
                size: T.iconSm,
                color: T.textGhost,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: active ? null : onLive,
            child: MouseRegion(
              cursor: active ? MouseCursor.defer : SystemMouseCursors.click,
              child: Icon(
                active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: T.iconSm,
                color: active ? T.purpleLight : T.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: T.gapSm),
          Text(
            target.layout.label,
            style: TextStyle(
              fontSize: T.fontBody,
              color: active ? T.textPrimary : T.textSecondary,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const SizedBox(width: T.gapSm),
          Expanded(
            child: Tooltip(
              message: info.mapFull,
              child: Text(
                info.map,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: T.monoFamily,
                  fontSize: T.fontCaption,
                  color: T.textMuted,
                ),
              ),
            ),
          ),
          if (unhealthy) ...[
            const SizedBox(width: T.gapPair),
            Tooltip(
              message: [
                if (info.exceeds)
                  'Routing exceeds the device’s $deviceChannels outputs. '
                      'Routes to outputs above $deviceChannels are silent.',
                if (info.unrouted > 0)
                  '${info.unrouted} channel${info.unrouted == 1 ? '' : 's'} '
                      'unrouted.',
              ].join(' '),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 13,
                color: T.meterYellow,
              ),
            ),
          ],
          const SizedBox(width: 8),
          GestureDetector(
            onTap: canRemove ? onRemove : null,
            child: MouseRegion(
              cursor: canRemove ? SystemMouseCursors.click : MouseCursor.defer,
              child: Icon(
                Icons.close,
                size: T.iconSm,
                color: canRemove
                    ? T.textTertiary
                    : T.textGhost.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explicit per-channel routing read straight off a target's matrix state:
/// [map] is a compact one-liner (`L:1 R:2 C:3 …`, `L:1,9` for a split, `LFE:–`
/// for an unrouted channel) ellipsized in the row; [mapFull] is the same
/// mapping one channel per line for the hover tooltip when [map] truncates.
/// Also reports whether routing overruns the device and how many channels
/// feed nothing.
({String map, String mapFull, bool exceeds, int unrouted}) _targetInfo(
  OutputTarget t,
  int deviceChannels,
  Map<int, String> labels,
  List<String> hwNames,
) {
  final speakers = t.layout.speakerLabels;
  var exceeds = false;
  var unrouted = 0;
  final compact = <String>[];
  final full = <String>[];
  for (var i = 0; i < t.routing.length; i++) {
    final speaker = i < speakers.length ? speakers[i] : 'Ch${i + 1}';
    final mask = t.routing[i];
    if (mask == 0) {
      unrouted++;
      compact.add('$speaker:–');
      full.add('$speaker → muted');
      continue;
    }
    final outsShort = <String>[];
    final outsFull = <String>[];
    for (var d = 0; d < kMaxRoutingChannels; d++) {
      if ((mask >> d) & 1 == 1) {
        if (d >= deviceChannels) exceeds = true;
        // Compact map keeps the bare number unless the output is named.
        outsShort.add(labels[d] ?? '${d + 1}');
        outsFull.add(
          outputChannelName(
            labels,
            d,
            hardwareName: d < hwNames.length ? hwNames[d] : '',
          ),
        );
      }
    }
    compact.add('$speaker:${outsShort.join(',')}');
    full.add('$speaker → ${outsFull.join(', ')}');
  }
  return (
    map: compact.join(' '),
    mapFull: full.join('\n'),
    exceeds: exceeds,
    unrouted: unrouted,
  );
}

class _AddLayoutButton extends ConsumerWidget {
  final MonitoringConfig config;
  final int deviceChannels;
  const _AddLayoutButton({required this.config, required this.deviceChannels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = OarLayout.values
        .where((l) => !config.isExposed(l))
        .toList();
    return AppButton(
      label: '+ Add Layout',
      size: AppButtonSize.compact,
      onPressed: available.isNotEmpty
          ? () => _showMenu(context, ref, available)
          : null,
    );
  }

  void _showMenu(
    BuildContext context,
    WidgetRef ref,
    List<OarLayout> available,
  ) {
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final pos = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + box.size.height + 4,
      overlay.size.width - bottomRight.dx,
      overlay.size.height - bottomRight.dy,
    );
    showMenu<OarLayout>(
      context: context,
      position: pos,
      color: T.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.radiusSm),
        side: BorderSide(color: T.border),
      ),
      items: [
        for (final l in available)
          PopupMenuItem<OarLayout>(
            value: l,
            enabled: l.channels <= deviceChannels,
            height: 30,
            child: Row(
              children: [
                Text(
                  '${l.label} (${l.channels}ch)',
                  style: TextStyle(
                    fontSize: T.fontBody,
                    color: l.channels <= deviceChannels
                        ? T.textPrimary
                        : T.textGhost,
                  ),
                ),
                if (l.channels > deviceChannels) ...[
                  const Spacer(),
                  Text('n/a', style: T.styleHint),
                ],
              ],
            ),
          ),
      ],
    ).then((l) {
      if (l != null) {
        ref.read(monitoringConfigProvider.notifier).addTarget(l);
      }
    });
  }
}

class _ClampWarning extends StatelessWidget {
  final List<String> labels;
  final int deviceChannels;
  const _ClampWarning({required this.labels, required this.deviceChannels});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: T.meterYellow.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.meterYellow.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: T.iconSm,
            color: T.meterYellow,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${labels.join(", ")} exceed this device’s '
              '$deviceChannels channels. Out-of-range routing is muted.',
              style: TextStyle(fontSize: T.fontCaption, color: T.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared settings row layout
// ---------------------------------------------------------------------------

/// The gap between two settings rows, 16 px in every theme. The Light
/// theme separates every pair of rows with a 2 px `chromeTabOn` line at
/// 32% across it, so the line sits in the gap with 7 px either side.
class _RowGap extends ConsumerWidget {
  const _RowGap();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _gap(ref, 16);
}

/// The gap between two settings sections, 28 px, with the same line.
class _SectionGap extends ConsumerWidget {
  const _SectionGap();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _gap(ref, 28);
}

Widget _gap(WidgetRef ref, double height) {
  // Self-tracked: the call sites are const, so a theme switch would not
  // otherwise reach this build.
  ref.watch(themeModeProvider);
  if (T.chromeStyle != ChromeStyle.raised) return SizedBox(height: height);
  return Padding(
    padding: EdgeInsets.symmetric(vertical: (height - 2) / 2),
    child: Container(height: 2, color: T.chromeTabOn.withValues(alpha: 0.32)),
  );
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final String description;
  final Widget control;

  const _SettingsRow({
    required this.label,
    required this.description,
    required this.control,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: T.textPrimary,
                  fontSize: T.fontHeading,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(description, style: T.styleBodySecondary),
            ],
          ),
        ),
        const SizedBox(width: 16),
        control,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Read-only info row
// ---------------------------------------------------------------------------

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ', style: T.styleBodySecondary),
        Text(value, style: T.styleBody),
      ],
    );
  }
}

/// Storage-path row: short label on the left, selectable absolute
/// path on the right. Used in the General tab to surface exactly
/// which files Reset to Defaults will touch.
class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Padding(
            // Optically align the label with the field's first text line.
            padding: const EdgeInsets.only(top: 6),
            child: Text(label, style: T.styleBodySecondary),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            // The raised style draws these as fields, on the same ground
            // as every other field.
            decoration:
                raisedField(T.radiusSm) ??
                BoxDecoration(
                  color: T.bgDeep,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: T.border, width: 1),
                ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    path,
                    style: TextStyle(
                      fontFamily: T.monoFamily,
                      fontSize: T.fontSmall,
                      color: T.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _CopyButton(text: path),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Copy-to-clipboard affordance for a path field: shows a brief
/// confirmation check, then reverts.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.text)).then(
      (_) {
        if (!mounted) return;
        setState(() => _copied = true);
        _revert?.cancel();
        _revert = Timer(const Duration(milliseconds: 1500), () {
          if (mounted) setState(() => _copied = false);
        });
      },
      onError: (Object e) =>
          Log.w(LogCat.session, 'Copy to clipboard failed', e),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Copy path',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _copy,
          behavior: HitTestBehavior.opaque,
          // 24 px hit target around the 15 px glyph.
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: Icon(
                _copied ? Icons.check : Icons.copy_outlined,
                size: T.iconSm,
                color: _copied ? T.indicatorGreen : T.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab bar
// ---------------------------------------------------------------------------

class _TabBar extends ConsumerStatefulWidget {
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  @override
  ConsumerState<_TabBar> createState() => _TabBarState();
}

class _TabBarState extends ConsumerState<_TabBar> {
  int? _hovered;

  @override
  Widget build(BuildContext context) {
    // Track theme/font so the tab bar doesn't freeze on a switch (the parent
    // may rebuild it as const).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final raised = T.chromeStyle == ChromeStyle.raised;
    return Container(
      // The raised style draws no well around its tabs. The rim stays in the
      // layout as a transparent colour: a border insets what it wraps,
      // so dropping it would move the row against every other theme's.
      decoration: raised
          ? T.decoControl(
              color: Colors.transparent,
              borderColor: T.border.withValues(alpha: 0),
            )
          : T.decoControl(borderColor: T.border),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(widget.labels.length, (i) {
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = i),
            onExit: (_) => setState(() {
              if (_hovered == i) _hovered = null;
            }),
            child: GestureDetector(
              onTap: () => widget.onChanged(i),
              child: raised ? _raisedCell(i) : _flatCell(i),
            ),
          );
        }),
      ),
    );
  }

  TextStyle _labelStyle({required bool active, required Color color}) =>
      TextStyle(
        color: color,
        fontSize: T.fontBodyL,
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      );

  /// The app's tab: a purple tint on the selected cell, in one well.
  Widget _flatCell(int i) {
    final active = i == widget.selected;
    final hovered = i == _hovered;
    final bg = active
        ? T.purple.withValues(alpha: 0.25)
        : hovered
        ? T.purple.withValues(alpha: 0.10)
        : Colors.transparent;
    final fg = active
        ? T.purpleLight
        : hovered
        ? T.textPrimary
        : T.textSecondary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(T.radiusSm),
      ),
      child: Text(
        widget.labels[i],
        style: _labelStyle(active: active, color: fg),
      ),
    );
  }

  /// The raised style's tab row in the dialog head: three tabs drawn as the
  /// workspace tabs, inverted. The unselected tabs carry the raised face with a
  /// `chromeTabOn` label, and the selected one is the accent outline with a
  /// `chromeTabOff` label. The row keeps the other styles' cell size and label
  /// weights, so it measures the same in every theme: each cell pays a 1 px
  /// margin out of the plain cell's 14 x 6 padding, and the rims cover the
  /// outer 2 px of what is left (the face insets its child by two of its three
  /// rims, the outline by none).
  Widget _raisedCell(int i) {
    final active = i == widget.selected;
    final label = Text(
      widget.labels[i],
      style: _labelStyle(
        active: active,
        color: active ? T.chromeTabOff : T.chromeTabOn,
      ),
    );
    return Container(
      margin: const EdgeInsets.all(1),
      child: active
          ? AccentOutline(
              radius: T.radiusSm,
              inset: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 5,
                ),
                child: label,
              ),
            )
          : RaisedFace(
              radius: T.radiusSm,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 3,
                ),
                child: label,
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// "Engine not available" placeholder chip
// ---------------------------------------------------------------------------

class _UnavailableChip extends StatelessWidget {
  const _UnavailableChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: T.decoControl(borderColor: T.border),
      child: Text(
        'Engine not available',
        style: TextStyle(color: T.textTertiary, fontSize: T.fontBodyL),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
