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

import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../import/wav_import_plan.dart';
import '../logging/log.dart';
import '../meters/meter_provider.dart';
import '../meters/mini_multichannel_meter.dart';
import '../export/iamf_profile_rules.dart';
import '../models/audio_element_enums.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../theme.dart';
import '../util/monitoring_tooltips.dart';
import '../video/video_provider.dart';
import '../video/video_track.dart';
import '../waveform/waveform.dart';
import '../widgets/ae_type_badge.dart';
import '../widgets/drop_zone.dart';
import '../widgets/element_format_dialog.dart';
import '../widgets/gain_knob.dart';
import '../widgets/inline_edit_field.dart';
import '../widgets/mix_status_badge.dart';
import '../widgets/remove_x_button.dart';
import '../widgets/resize_handle.dart';
import '../widgets/routing_labels.dart';
import '../widgets/routing_matrix_dialog.dart';
import '../widgets/solo_mute_button.dart';
import '../widgets/time_ruler.dart';
import '../widgets/track_lanes.dart';
import 'element_card.dart' show RenameField, showDeleteDialog;

/// Mutable track panel width (resizable by the user).
/// Not persisted — resets to [T.trackPanel] on app restart.
class _TrackPanelWidthNotifier extends Notifier<double> {
  @override
  double build() => T.trackPanel;
  void set(double v) => state = v;
}

final trackPanelWidthProvider =
    NotifierProvider<_TrackPanelWidthNotifier, double>(
      _TrackPanelWidthNotifier.new,
    );

/// Build a fresh [AudioElement] from a decoded WAV, assigning the next
/// free id relative to [existing]. Layout/type/color are derived from
/// the channel count via [defaultConfigForChannelCount]. Used by both
/// the "create new element" and "replace element with different channel
/// count" flows.
AudioElement _buildElementFromWav(
  List<AudioElement> existing,
  String wavPath,
  WavInfo wavInfo, [
  ElementConfig? configOverride,
]) {
  final nextId = existing.isEmpty
      ? 1
      : existing.map((e) => e.id).reduce(max) + 1;

  // Callers with an unambiguous type (e.g. ADM import, which knows whether it
  // rendered a channel bed, a scene, or a binaural stereo) pass an override;
  // otherwise the type is inferred from the channel count.
  final cfg = configOverride ?? defaultConfigForChannelCount(wavInfo.channels);
  final type = cfg.type;
  final layout = cfg.layout ?? '${wavInfo.channels}ch';
  final isDual = cfg.isDual ?? false;
  final ambisonicsOrder = cfg.ambisonicsOrder ?? 1;
  final color = _colorForElementType(type);

  return AudioElement(
    id: nextId,
    name: p.basenameWithoutExtension(wavPath),
    type: type,
    layout: layout,
    codec: 'WAV ${wavInfo.bitsPerSample}bit',
    color: color,
    wavPath: wavPath,
    wavInfo: wavInfo,
    isDual: isDual,
    ambisonicsOrder: ambisonicsOrder,
  );
}

/// Theme colour (ARGB) assigned to elements of [type].
int _colorForElementType(String type) => type == 'Object'
    ? T.typeObject.toARGB32()
    : type == 'Scene'
    ? T.typeScene.toARGB32()
    : T.typeChannel.toARGB32();

/// Format a WAV decode/IO failure into a short user-facing message.
///
/// Used both in info SnackBars and as blocker-dialog copy (ES-184), and
/// by the landing card's WAV-drop pre-validation (workspace_actions).
/// Never returns null — if the exception is an unexpected type,
/// returns a generic fallback.
String wavImportErrorMessage(String wavPath, Object e) {
  final name = p.basename(wavPath);
  if (e is FormatException) {
    return 'Cannot import "$name": ${e.message}';
  }
  if (e is FileSystemException) {
    final reason = e.osError?.message ?? e.message;
    return 'Cannot read "$name": $reason';
  }
  return 'Cannot import "$name"';
}

/// Assign a WAV file to an existing element by id via drag-and-drop.
///
/// Returns `null` on success or a short user-facing error message on
/// failure. Callers typically aggregate these across a batch and push
/// a single summary to `importNoticeProvider`.
///
/// Behavior:
/// * Empty slot → assigns the WAV and syncs a new entry to the engine.
/// * Loaded slot with matching channel count → swaps the WAV in place,
///   preserving name/color/layout/gain/mute/solo/routing, and
///   re-registers the file with the engine.
/// * Loaded slot with a different channel count → removes the old
///   element (engine + state) and inserts a freshly-built element at
///   the same list index so the visual position is preserved.
///
/// [configOverride] applies to the different-channel-count path only —
/// the other two keep the element's existing config. Callers resolve
/// ambiguous channel counts through the element format dialog before
/// getting here (ES-152); without an override the count's default applies.
Future<String?> assignWavToElement(
  ProviderContainer container,
  int elementId,
  String wavPath, {
  ElementConfig? configOverride,
}) async {
  try {
    final newInfo = await WavDecoder.readInfo(wavPath);
    final elems = container.read(elementsProvider);
    final idx = elems.indexWhere((e) => e.id == elementId);
    if (idx < 0) return 'Element no longer exists';
    final old = elems[idx];
    final oldCh = old.wavInfo?.channels;

    // Evict stale peak data so waveforms recompute from the new file.
    final peakCache = container.read(peakCacheProvider);
    if (old.wavPath != null) peakCache.evictAll(old.wavPath!);
    if (wavPath != old.wavPath) peakCache.evictAll(wavPath);

    // Case A: empty slot → assign.
    if (oldCh == null) {
      final updated = List<AudioElement>.from(elems)
        ..[idx] = old.copyWith(
          wavPath: wavPath,
          wavInfo: newInfo,
          wavGeneration: old.wavGeneration + 1,
        );
      container.read(elementsProvider.notifier).set(updated);
      _recalcDuration(container, updated);
      return _syncElementToEngine(container, updated[idx]);
    }

    // Case B: same channel count → swap WAV, keep settings, reload in
    // the engine so the audio thread reads from the new file.
    if (oldCh == newInfo.channels) {
      final updated = List<AudioElement>.from(elems)
        ..[idx] = old.copyWith(
          wavPath: wavPath,
          wavInfo: newInfo,
          wavGeneration: old.wavGeneration + 1,
        );
      container.read(elementsProvider.notifier).set(updated);
      _recalcDuration(container, updated);
      final engine = container.read(eclipsaStudioEngineProvider);
      if (engine != null) {
        // The remove compacts engine slots (swap-with-last) and the
        // re-add appends — mirror both in the slot→element map (ES-531).
        engine.removeElement(old.id);
        container.read(engineOrderProvider.notifier).removeCompacted(old.id);
        final rc = engine.addElement(old.id, wavPath);
        Log.d(
          LogCat.engine,
          'replaceElement(id=${old.id}, '
          'path="$wavPath") -> rc=$rc',
        );
        if (rc == 0) {
          container.read(engineOrderProvider.notifier).set([
            ...container.read(engineOrderProvider),
            old.id,
          ]);
          final el = updated[idx];
          final (oarType, oarSubType, oarCh) = elementToOarType(el);
          engine.setElementType(el.id, oarType, oarSubType, oarCh);
          engine.setElementGain(el.id, el.gain);
          engine.setElementMute(el.id, el.mute);
          engine.setElementSolo(el.id, el.solo);
        } else {
          Log.w(
            LogCat.engine,
            'Failed to reload element ${old.id} after WAV swap '
            '(rc=$rc)',
          );
          return 'Engine failed to reload "${p.basename(wavPath)}"';
        }
      }
      return null;
    }

    // Case C: different channel count → delete old element, insert a
    // fresh one at the same index.
    final engine = container.read(eclipsaStudioEngineProvider);
    engine?.removeElement(old.id);
    container.read(engineOrderProvider.notifier).removeCompacted(old.id);

    final fresh = _buildElementFromWav(elems, wavPath, newInfo, configOverride);
    final updated = List<AudioElement>.from(elems)
      ..removeAt(idx)
      ..insert(idx, fresh);
    container.read(elementsProvider.notifier).set(updated);
    container
        .read(mixesNotifierProvider.notifier)
        .ensureElementSettings(fresh.id);
    _recalcDuration(container, updated);
    return _syncElementToEngine(container, fresh);
  } on FormatException catch (e) {
    Log.w(LogCat.elements, 'Invalid WAV file $wavPath', e);
    return wavImportErrorMessage(wavPath, e);
  } on FileSystemException catch (e) {
    Log.w(LogCat.elements, 'Could not read file $wavPath', e);
    return wavImportErrorMessage(wavPath, e);
  } catch (e, st) {
    // Defensive terminal catch: a RangeError / StateError from a
    // malformed WAV header would otherwise propagate up through the
    // caller's batch loop and abort it silently. Log with stack and
    // surface a generic message so the batch can continue.
    Log.e(LogCat.elements, 'Unexpected error importing $wavPath', e);
    Log.e(LogCat.elements, '$st');
    return wavImportErrorMessage(wavPath, e);
  }
}

/// Create a new [AudioElement] from a WAV file and append it to the
/// elements list.
///
/// Returns `null` on success or a short user-facing error message on
/// failure. Enforces the active IAMF profile's element, channel, and
/// type constraints — the caller is responsible for pre-filtering
/// drop/picker batches to avoid this, but the helper enforces the
/// limits too as a safety net.
Future<String?> addNewElementFromWav(
  ProviderContainer container,
  String wavPath, {
  ElementConfig? configOverride,
}) async {
  final profile = container.read(iamfProfileProvider);
  final elements = container.read(elementsProvider);
  if (elements.length >= profile.maxAudioElements) {
    return '${profile.label} profile limit of '
        '${profile.maxAudioElements} elements reached';
  }
  try {
    final wavInfo = await WavDecoder.readInfo(wavPath);
    final currentElements = container.read(elementsProvider);
    // Re-check in case the list grew during the async decode.
    if (currentElements.length >= profile.maxAudioElements) {
      return '${profile.label} profile limit of '
          '${profile.maxAudioElements} elements reached';
    }
    // Sum from the model fields (not wavInfo, which is absent for elements
    // whose WAV is missing/undecoded), matching profileConflicts and the ADM
    // dialog's budget so the three surfaces agree.
    final totalChannels = currentElements.fold<int>(
      0,
      (sum, e) => sum + audioElementChannelCount(e),
    );
    if (totalChannels + wavInfo.channels > profile.maxChannels) {
      return 'Adding ${wavInfo.channels} channels would exceed '
          'the ${profile.label} profile limit of '
          '${profile.maxChannels} total channels';
    }
    final newElement = _buildElementFromWav(
      currentElements,
      wavPath,
      wavInfo,
      configOverride,
    );
    if (newElement.type == 'Object' && !profile.allowObjectBased) {
      return 'Object-based elements are not allowed by '
          'the ${profile.label} profile';
    }
    // Mixed element types, mirroring profileConflicts' mixedTypesNotAllowed —
    // the gated pickers prevent this, but the WAV drop/picker path auto-types
    // from the channel count and would otherwise slip a second type past a
    // profile that forbids mixing (e.g. a Scene drop onto a Channel session
    // under Base).
    if (!profile.allowMixedTypes &&
        currentElements.any((e) => e.type != newElement.type)) {
      final existing =
          (currentElements.map((e) => e.type).toSet().toList()..sort()).join(
            ', ',
          );
      return '${profile.label} does not allow mixing element types '
          '(adding ${newElement.type} to $existing)';
    }
    // Expanded channel layouts (e.g. 9.1.6) are gated by the profile's spec
    // version, mirroring profileConflicts' elementLayoutNotAllowed — the
    // count/budget checks above don't catch a layout the profile predates.
    if (newElement.type == 'Channel') {
      final layout = LoudspeakerLayout.fromDisplayName(newElement.layout);
      if (layout != null && !profileAllowsLayout(profile, layout)) {
        final min = minProfileForLayout(layout);
        return 'The ${layout.displayName} layout is not allowed by the '
            '${profile.label} profile'
            '${min == null ? '' : ' (needs ${min.label})'}.';
      }
    }

    final updated = [...currentElements, newElement];
    container.read(elementsProvider.notifier).set(updated);
    container
        .read(mixesNotifierProvider.notifier)
        .ensureElementSettings(newElement.id);
    _recalcDuration(container, updated);
    return _syncElementToEngine(container, newElement);
  } on FormatException catch (e) {
    Log.w(LogCat.elements, 'Invalid WAV file $wavPath', e);
    return wavImportErrorMessage(wavPath, e);
  } on FileSystemException catch (e) {
    Log.w(LogCat.elements, 'Could not read file $wavPath', e);
    return wavImportErrorMessage(wavPath, e);
  } catch (e, st) {
    // Defensive terminal catch — see assignWavToElement for rationale.
    Log.e(LogCat.elements, 'Unexpected error importing $wavPath', e);
    Log.e(LogCat.elements, '$st');
    return wavImportErrorMessage(wavPath, e);
  }
}

void _recalcDuration(ProviderContainer container, List<AudioElement> elements) {
  // Audio duration in seconds (longest element), but the transport
  // itself must clock at the engine output rate: the audio thread
  // advances at the device rate (post-resampling), so the seek
  // round-trip engine_frames ⇄ Dart.samplePosition only stays exact
  // when both sides share the same sample-rate basis. If we stored the
  // WAV's rate here instead, a click at fraction f would seek the
  // engine to f × engine/wav of the timeline — the playhead would jump.
  final audioSeconds = longestAudioSeconds(elements);

  // Consider video duration.
  final videoDuration = container.read(videoProvider).duration;
  final videoSeconds = videoDuration != null
      ? videoDuration.inMilliseconds / 1000.0
      : 0.0;

  final maxSeconds = max(audioSeconds, videoSeconds);
  if (maxSeconds <= 0) return;

  final engine = container.read(eclipsaStudioEngineProvider);
  final transportRate = engine?.currentSampleRate ?? 48000;
  final samples = (maxSeconds * transportRate).ceil();
  container
      .read(transportProvider.notifier)
      .updateDuration(samples, transportRate);
}

/// Register a single element with the C++ engine for metering.
///
/// Returns `null` on success or a short user-facing error message on
/// engine failure (rc != 0). Callers must propagate the error so the
/// user sees that the import didn't take effect — without this, the
/// element appears in the elements list but its meters flatline and
/// playback is silent.
///
/// Mirrors the per-element logic in [SessionNotifier._syncElementsToEngine]
/// — if the engine sync protocol changes, update both.
String? _syncElementToEngine(
  ProviderContainer container,
  AudioElement element,
) {
  if (element.wavPath == null) return null;
  final engine = container.read(eclipsaStudioEngineProvider);
  if (engine == null) {
    Log.d(
      LogCat.engine,
      'Engine null, cannot sync element '
      '${element.id}',
    );
    return null;
  }
  final rc = engine.addElement(element.id, element.wavPath!);
  Log.d(
    LogCat.engine,
    'addElement(id=${element.id}, '
    'name="${element.name}", '
    'path="${element.wavPath}") -> rc=$rc',
  );
  if (rc != 0) {
    Log.w(
      LogCat.engine,
      'Failed to add element ${element.id} '
      '"${element.name}" (rc=$rc)',
    );
    return 'Engine failed to load "${p.basename(element.wavPath!)}"';
  }
  // Register element type with OAR renderer and commit so the
  // change takes effect immediately (including during playback).
  final (oarType, oarSubType, oarCh) = elementToOarType(element);
  engine.setElementType(element.id, oarType, oarSubType, oarCh);
  engine.commitRenderingConfig();
  engine.setElementGain(element.id, element.gain);
  engine.setElementMute(element.id, element.mute);
  engine.setElementSolo(element.id, element.solo);
  engine.setElementInputRouting(element.id, element.inputRouting);
  pushElementObjectPosition(engine, element);
  final order = [...container.read(engineOrderProvider), element.id];
  container.read(engineOrderProvider.notifier).set(order);
  Log.d(LogCat.engine, 'engineOrder updated: $order');
  return null;
}

class ElementsView extends ConsumerWidget {
  const ElementsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No theme/font watches here — they'd be dead: the const _Timeline
    // child short-circuits parent rebuilds, so _TimelineState tracks
    // the modes itself.
    return const _Timeline();
  }
}

/// Replace an element in the elements list by ID and sync
/// audio-critical properties (gain, mute, solo) to the C++ engine.
void _updateElementById(WidgetRef ref, AudioElement updated) {
  final elems = ref.read(elementsProvider);
  final idx = elems.indexWhere((e) => e.id == updated.id);
  if (idx < 0) return;
  final previous = elems[idx];
  final list = List<AudioElement>.from(elems)..[idx] = updated;
  ref.read(elementsProvider.notifier).set(list);

  // Immediately sync changed audio properties to the C++ engine.
  final engine = ref.read(eclipsaStudioEngineProvider);
  if (engine == null) return;
  final typeChanged =
      updated.type != previous.type ||
      updated.layout != previous.layout ||
      updated.ambisonicsOrder != previous.ambisonicsOrder ||
      updated.isDual != previous.isDual;
  if (typeChanged) {
    final (oarType, oarSubType, oarCh) = elementToOarType(updated);
    engine.setElementType(updated.id, oarType, oarSubType, oarCh);
  }
  if (updated.gain != previous.gain) {
    engine.setElementGain(updated.id, updated.gain);
  }
  if (updated.mute != previous.mute) {
    engine.setElementMute(updated.id, updated.mute);
  }
  if (updated.solo != previous.solo) {
    engine.setElementSolo(updated.id, updated.solo);
  }
  if (!listEquals(updated.inputRouting, previous.inputRouting)) {
    engine.setElementInputRouting(updated.id, updated.inputRouting);
  }
  // Object position: sync on any position-affecting change AND on
  // type change (an element re-typed to Object needs its position
  // pushed before it is audible on loudspeaker layouts).
  if (typeChanged ||
      updated.azimuth != previous.azimuth ||
      updated.elevation != previous.elevation ||
      updated.distance != previous.distance ||
      updated.spread != previous.spread) {
    pushElementObjectPosition(engine, updated);
  }
}

/// Removes an element from the engine and every provider that tracks
/// it, keeping the slot→element map in lockstep with the engine's
/// compaction (see [EngineOrderNotifier.removeCompacted], ES-531).
void deleteElementById(ProviderContainer container, int elementId) {
  final elems = container.read(elementsProvider);
  final idx = elems.indexWhere((e) => e.id == elementId);
  if (idx < 0) return;

  final engine = container.read(eclipsaStudioEngineProvider);
  engine?.removeElement(elementId);
  container.read(engineOrderProvider.notifier).removeCompacted(elementId);

  container
      .read(mixesNotifierProvider.notifier)
      .removeElementSettings(elementId);

  final updated = List<AudioElement>.from(elems)..removeAt(idx);
  container.read(elementsProvider.notifier).set(updated);
  _recalcDuration(container, updated);
}

class _Timeline extends ConsumerStatefulWidget {
  const _Timeline();

  @override
  ConsumerState<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends ConsumerState<_Timeline> {
  final _trackScrollController = ScrollController();

  /// The track list's metrics, updated when its extent or viewport
  /// changes. The controller notifies on offset changes only, so the
  /// vertical scrollbar listens to both (ES-761).
  final _trackMetrics = ValueNotifier<ScrollMetrics?>(null);

  @override
  void dispose() {
    _trackScrollController.dispose();
    _trackMetrics.dispose();
    super.dispose();
  }

  bool _onTrackMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) _trackMetrics.value = n.metrics;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final elements = ref.watch(elementsProvider);
    final cache = ref.watch(peakCacheProvider);
    final mixes = ref.watch(mixesNotifierProvider);
    final activeMixIdx = ref.watch(activeMixProvider);
    final activeMix = activeMixIdx < mixes.length ? mixes[activeMixIdx] : null;

    final panelW = ref.watch(trackPanelWidthProvider);
    // Small gap so the playhead at t=0 doesn't overlap the divider.
    const timelineInset = 6.0;
    final timelineLeft = panelW + timelineInset;
    // Channel-label gutter: every time-mapped surface — ruler, video
    // bar, waveform blocks, playhead, zoom bar — shares one origin,
    // shifted right by the gutter width so t=0 starts after the label
    // column. The fontSizeModeProvider watch above keeps the measured
    // width in step with label rescales.
    final gutterW = _channelGutterWidth(context, elements);
    final waveformLeft = timelineLeft + gutterW;
    final handleLeft = max(timelineLeft, waveformLeft - ResizeHandle.extent);

    return Container(
      color: T.bgBase,
      child: Column(
        children: [
          // Ruler + tracks with shared playhead line
          Expanded(
            child: Stack(
              children: [
                // Panel background + divider (extends into
                // the inset gap so the border doesn't
                // overlap track controls).
                // Panel + label-gutter backdrop: one strip so the
                // gutter column reads continuously across the video
                // row, add slot, and below the last track.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: waveformLeft,
                  child: Container(
                    decoration: BoxDecoration(
                      color: trackPanelStripColor(),
                      border: Border(
                        right: BorderSide(color: T.border, width: 0.5),
                      ),
                    ),
                  ),
                ),
                // Content
                Positioned.fill(
                  child: Column(
                    children: [
                      // Time ruler
                      Container(
                        height: TimeRulerStrip.height,
                        color: TimeRulerStrip.ground,
                        child: Row(
                          children: [
                            SizedBox(width: waveformLeft),
                            const Expanded(child: _RulerWithSelection()),
                            const SizedBox(width: _VerticalZoomStrip.width),
                          ],
                        ),
                      ),
                      Container(height: 1, color: T.border),
                      // Video duration track. Its lane stops where the
                      // ruler's does, short of the vertical zoom strip,
                      // so the two map time on the same scale (ES-758).
                      // The strip's ground continues up beside it; the
                      // row is 0 px tall without a video, and so is the
                      // ground.
                      Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              right: _VerticalZoomStrip.width,
                            ),
                            child: VideoTrack(panelWidth: waveformLeft),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            bottom: 0,
                            width: _VerticalZoomStrip.width,
                            child: DecoratedBox(
                              decoration: _VerticalZoomStrip.decoration(),
                            ),
                          ),
                        ],
                      ),
                      // Audio tracks + vertical zoom
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: NotificationListener(
                                onNotification: _onTrackMetrics,
                                child: _AudioTracksArea(
                                  elements: elements,
                                  cache: cache,
                                  scrollController: _trackScrollController,
                                  activeMix: activeMix,
                                  panelWidth: timelineLeft,
                                  gutterWidth: gutterW,
                                ),
                              ),
                            ),
                            _VerticalZoomStrip(
                              scrollController: _trackScrollController,
                              metrics: _trackMetrics,
                            ),
                          ],
                        ),
                      ),
                      _TimelineZoomBar(panelWidth: waveformLeft),
                    ],
                  ),
                ),
                // Single playhead line spanning ruler + all tracks
                Positioned(
                  left: waveformLeft,
                  right: _VerticalZoomStrip.width,
                  top: 0,
                  bottom: 0,
                  child: RepaintBoundary(child: _PlayheadOverlay()),
                ),
                // Resize handle on the divider at waveformLeft, laid
                // over the channel-label gutter so the ruler and lanes
                // right of the line keep their pointer input (ES-748).
                // It never starts left of timelineLeft, where the track
                // panels end: with a gutter narrower than the handle (0
                // before any WAV is loaded) it would cover their delete
                // buttons, so it reaches past the line instead. The
                // gutter width does not depend on the panel width, so
                // the line follows the pointer 1:1.
                Positioned(
                  left: handleLeft,
                  top: 0,
                  bottom: 0,
                  child: ResizeHandle(
                    axis: Axis.horizontal,
                    borderOffset: waveformLeft - handleLeft,
                    onDragUpdate: (dx) {
                      final w = (panelW + dx).clamp(120.0, 320.0);
                      ref.read(trackPanelWidthProvider.notifier).set(w);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Height of the controls column in `_AudioTrack`, without the panel's
/// own drawing. [meterChannels] is the element's output channel count,
/// which is what the mini meter draws.
///
/// The four constants are the rows of that column, co-located with it
/// so they stay in sync with the widget tree: the premix row is a
/// 24 px name over a 4 px gap over a 28 px gain, the separator is its
/// padding plus a 1 px divider, the type pill is a 24 px chip over a
/// 4 px gap, and the badge row is drawn only when the element is
/// excluded from the mix but is budgeted always.
double trackPanelColumnHeight(AudioElement elem, int meterChannels) {
  const premix = 56.0;
  const separator = 9.0;
  const typePill = 28.0;
  const badges = 16.0;
  final params = elem.type == 'Object' ? (elem.isDual ? 92.0 : 72.0) : 20.0;
  final meter = meterChannels * 5.0 + 9;
  return premix + separator + typePill + params + badges + meter;
}

/// Minimum height of one track's row: the controls column, the padding
/// it lays out in, and whatever the panel's own drawing adds outside
/// that box.
double trackPanelMinHeight(AudioElement elem, int meterChannels) =>
    trackPanelColumnHeight(elem, meterChannels) +
    kTrackPanelPadding.vertical +
    trackPanelVerticalOverhead(kTrackPanelPadding);

class _AudioTrack extends ConsumerStatefulWidget {
  final AudioElement element;
  final PeakCache cache;
  final int reorderIndex;
  final bool excludedFromMix;
  final double panelWidth;

  /// Width of the channel-label gutter between the panel and the
  /// waveform area; 0 when no element has audio.
  final double gutterWidth;

  const _AudioTrack({
    super.key,
    required this.element,
    required this.cache,
    required this.reorderIndex,
    required this.excludedFromMix,
    required this.panelWidth,
    required this.gutterWidth,
  });

  @override
  ConsumerState<_AudioTrack> createState() => _AudioTrackState();
}

class _AudioTrackState extends ConsumerState<_AudioTrack> {
  bool _isDragOver = false;
  bool _editing = false;
  bool _editingGain = false;

  WaveformStyle get _style {
    switch (widget.element.type) {
      case 'Object':
        return WaveformStyle.object;
      case 'Channel':
        return WaveformStyle.channel;
      case 'Scene':
        return WaveformStyle.scene;
      default:
        return WaveformStyle.object;
    }
  }

  String get _typeGlyph {
    switch (widget.element.type) {
      case 'Object':
        return '\u25C9'; // ◉
      case 'Channel':
        return '\u2630'; // ☰
      case 'Scene':
        return '\u25CE'; // ◎
      default:
        return '\u25C9';
    }
  }

  Future<void> _onDragDone(DropDoneDetails details) async {
    final wavFiles = details.files
        .where((f) => f.path.toLowerCase().endsWith('.wav'))
        .toList();
    final rejected = details.files.length - wavFiles.length;

    if (wavFiles.isEmpty) {
      // Nothing importable in the drop — blocker (ES-184).
      final what = rejected == 1
          ? 'The dropped file is not a WAV file'
          : 'None of the dropped files are WAV files';
      ref
          .read(importNoticeProvider.notifier)
          .showBlocker(
            '$what \u2014 nothing was imported.\n\n'
            'Audio elements accept WAV files (16/24/32-bit).',
          );
      return;
    }

    ref
        .read(lastImportDirProvider.notifier)
        .set(p.dirname(wavFiles.first.path));

    // Resolve an ambiguous channel count before replacing (ES-152). The
    // different-count / same-count / undecodable decision lives in
    // planWavReplace (unit-tested, ES-432).
    final wavPath = wavFiles.first.path;
    // The try covers only the decode: a dialog failure must not be
    // swallowed into the "malformed WAV" fallthrough, which would
    // silently guess a default config over the user's choice.
    WavInfo? info;
    try {
      info = await WavDecoder.readInfo(wavPath);
    } catch (_) {
      // Unreadable/malformed WAV — fall through; assignWavToElement
      // re-decodes and surfaces the standard error message.
    }
    final replacePlan = await planWavReplace(
      path: wavPath,
      newInfo: info,
      currentChannels: widget.element.wavInfo?.channels,
      profile: ref.read(iamfProfileProvider),
      prompt:
          ({
            required String path,
            required WavInfo info,
            required IamfProfile profile,
            required int remainingSameCount,
          }) async {
            if (!mounted) return null;
            return showElementFormatDialog(
              context,
              fileName: p.basename(path),
              channels: info.channels,
              profile: profile,
              sampleRate: info.sampleRate,
              confirmLabel: 'Replace',
            );
          },
    );
    if (replacePlan.aborted) return; // Cancelled — keep the element.
    final configOverride = replacePlan.override;
    if (!mounted) return;

    final err = await assignWavToElement(
      ProviderScope.containerOf(context, listen: false),
      widget.element.id,
      wavPath,
      configOverride: configOverride,
    );

    final fyis = <String>[];
    if (wavFiles.length > 1) {
      final extras = wavFiles.length - 1;
      fyis.add(
        extras == 1
            ? '1 extra WAV ignored \u2014 drop below to add as '
                  'new elements'
            : '$extras extra WAVs ignored \u2014 drop below to '
                  'add as new elements',
      );
    }
    if (rejected > 0) {
      fyis.add(
        rejected == 1
            ? '1 non-WAV file ignored'
            : '$rejected non-WAV files ignored',
      );
    }
    final notifier = ref.read(importNoticeProvider.notifier);
    if (err != null) {
      // The assignment itself failed — nothing was imported, so
      // escalate to a blocker dialog (ES-184), with the failure as the
      // lead paragraph and any FYIs kept apart from it.
      var message = err;
      if (fyis.isNotEmpty) {
        message += '\n\nAlso: ${fyis.join(' \u00B7 ')}.';
      }
      notifier.showBlocker(message);
    } else if (fyis.isNotEmpty) {
      notifier.show(fyis.join(' \u00B7 '));
    }
  }

  void _updateElement(AudioElement updated) {
    _updateElementById(ref, updated);
  }

  void _toggleSolo() {
    _updateElement(widget.element.copyWith(solo: !widget.element.solo));
  }

  void _toggleMute() {
    _updateElement(widget.element.copyWith(mute: !widget.element.mute));
  }

  void _setGain(double v) {
    _updateElement(widget.element.copyWith(gain: v));
  }

  /// Trim whitespace and an optional `dB` suffix so the inline editor
  /// accepts raw numbers ("3", "-5.5"), decorated numbers ("+3 dB"),
  /// and the value as it's displayed in the label.
  String _normalizeGainInput(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.endsWith('db')) s = s.substring(0, s.length - 2).trim();
    return s;
  }

  bool _isValidGainInput(String normalized) {
    final v = double.tryParse(normalized);
    return v != null && v.isFinite;
  }

  /// Parse the inline-editor input, clamp to the knob's [-60, +12] dB
  /// range, round to 0.1 dB (matching knob precision), and apply.
  ///
  /// Short-circuits when the rounded value equals the current gain
  /// so that text-form no-ops (`"3"` vs `3.0`, `"50"` clamped down
  /// to an already-maxed `+12.0`, whitespace-only edits, etc.) don't
  /// flow through [_setGain] and mark the session dirty. The
  /// [InlineEditField] string-equality guard can't catch these
  /// because it compares raw text, not numeric equivalence.
  void _commitGainFromText(String normalized) {
    final parsed = double.parse(normalized);
    // Matches GainKnob's default [min, max] — keep in lockstep if the
    // knob's range ever changes.
    final clamped = parsed.clamp(-60.0, 12.0);
    final rounded = (clamped * 10).round() / 10;
    if (rounded == widget.element.gain) return;
    _setGain(rounded);
  }

  /// Thin purple-bordered, filled decoration for the inline gain
  /// editor. Matches [RenameField] styling at meter-label scale.
  InputDecoration _gainFieldDecoration() {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(2),
      borderSide: BorderSide(color: T.purple, width: 1),
    );
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      filled: true,
      fillColor: T.bgElevated,
      border: border,
      enabledBorder: border,
      focusedBorder: border,
    );
  }

  void _renameElement(String newName) {
    _updateElement(widget.element.copyWith(name: newName));
    setState(() => _editing = false);
  }

  Future<void> _showContextMenu(BuildContext ctx, Offset position) async {
    final elem = widget.element;
    final v = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: T.bgElevated,
      items: [
        PopupMenuItem(
          value: 'rename',
          height: 32,
          child: Text('Rename', style: T.styleBody),
        ),
        // A WAV that failed to load (moved, or ungranted under the sandbox)
        // can be pointed at again without deleting the element (ES-628).
        if (elem.wavPath != null && elem.wavInfo == null)
          PopupMenuItem(
            value: 'locate',
            height: 32,
            child: Text('Locate WAV…', style: T.styleBody),
          ),
        PopupMenuItem(
          value: 'delete',
          height: 32,
          child: Text(
            'Delete',
            style: TextStyle(fontSize: T.fontBody, color: T.meterRed),
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (v == 'rename') setState(() => _editing = true);
    if (v == 'locate') {
      // Resolve the container before the picker; nothing here touches the
      // context after the await.
      final container = ProviderScope.containerOf(context, listen: false);
      await container.read(sessionProvider.notifier).locateWav(elem.id);
      return;
    }
    if (v == 'delete') {
      showDeleteDialog(
        context,
        elem.name,
        () => deleteElementById(
          ProviderScope.containerOf(context, listen: false),
          elem.id,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final elem = widget.element;
    final cache = widget.cache;
    final trackScale = ref.watch(
      timelineViewportProvider.select((v) => v.trackScale),
    );
    final channels = elem.wavInfo?.channels ?? 1;
    // The mini meter shows the element's output (post-routing) channels,
    // not the WAV's: the engine meters tap after the input remap, so a
    // 16ch WAV down-routed to a 5.1 bed meters 6 channels. The waveform
    // below keeps the WAV count — it draws the source file.
    final meterChannels = max(1, audioElementChannelCount(elem));
    final panelMin = trackPanelMinHeight(elem, meterChannels);
    // Waveform needs ~14px per channel + 8px vertical padding.
    final waveformNeed = channels * 14.0 + 8;
    final baseHeight = max(panelMin, waveformNeed);
    final trackHeight = max(panelMin, baseHeight * trackScale);

    return SizedBox(
      height: trackHeight,
      child: Row(
        children: [
          // Track info + controls panel. The Column below is
          // MainAxisSize.max under the row's bounded height, so the
          // panel fills the row in every theme; the card needs that,
          // since an opaque fill short of the row would leave bare
          // ground above and below it.
          GestureDetector(
            onSecondaryTapUp: (d) =>
                _showContextMenu(context, d.globalPosition),
            child: TrackPanel(
              width: widget.panelWidth,
              basePadding: kTrackPanelPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1: type icon + name + delete
                  Row(
                    children: [
                      ReorderableDragStartListener(
                        index: widget.reorderIndex,
                        child: Tooltip(
                          message: 'Drag to reorder',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: Center(
                                child: Text(
                                  _typeGlyph,
                                  style: TextStyle(
                                    fontSize: T.fontHeading,
                                    color: Color(elem.color),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: _editing
                            ? RenameField(
                                currentName: elem.name,
                                onRename: _renameElement,
                                onExit: () => setState(() => _editing = false),
                              )
                            : Tooltip(
                                message: elem.name,
                                child: GestureDetector(
                                  onDoubleTap: () =>
                                      setState(() => _editing = true),
                                  child: Text(
                                    elem.name,
                                    style: T.styleBodySecondary,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 2),
                      RemoveXButton(
                        width: 20,
                        height: 20,
                        onTap: () => showDeleteDialog(
                          context,
                          elem.name,
                          () => deleteElementById(
                            ProviderScope.containerOf(context, listen: false),
                            elem.id,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Row 2: gain knob, its readout, solo and mute.
                  Row(
                    children: [
                      Tooltip(
                        message:
                            'Source gain — applied to the WAV file before\n'
                            'the IAMF pipeline. Not written to IAMF metadata.',
                        child: GainKnob(
                          gainDb: elem.gain,
                          onChanged: _setGain,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: T.gapPair),
                      Expanded(
                        child: _editingGain
                            ? SizedBox(
                                height: 16,
                                child: InlineEditField(
                                  initialValue: elem.gain.toStringAsFixed(1),
                                  onCommit: _commitGainFromText,
                                  onExit: () =>
                                      setState(() => _editingGain = false),
                                  normalize: _normalizeGainInput,
                                  validate: _isValidGainInput,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                        signed: true,
                                      ),
                                  style: T.styleValueSmall,
                                  decoration: _gainFieldDecoration(),
                                ),
                              )
                            : GestureDetector(
                                onTap: () =>
                                    setState(() => _editingGain = true),
                                // One line, scaled down when the panel
                                // is too narrow: a wrap is taller than
                                // the 28 px knob at the large font, and
                                // an ellipsis would cut the digits.
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    _gainLabel(elem.gain),
                                    style: T.styleValueSmall,
                                    maxLines: 1,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 4),
                      // Mix-excluded elements are already silent, so
                      // engaging S/M is disabled (clear-only): an
                      // engaged button stays tappable to un-latch a
                      // solo/mute set before the exclusion (ES-297).
                      SoloMuteButton(
                        label: 'S',
                        tooltip: widget.excludedFromMix && !elem.solo
                            ? kSoloMuteExcludedTooltip
                            : kSoloTooltip,
                        active: elem.solo,
                        activeColor: T.meterYellow,
                        onTap: _toggleSolo,
                        enabled: !widget.excludedFromMix || elem.solo,
                      ),
                      const SizedBox(width: 4),
                      SoloMuteButton(
                        label: 'M',
                        tooltip: widget.excludedFromMix && !elem.mute
                            ? kSoloMuteExcludedTooltip
                            : kMuteTooltip,
                        active: elem.mute,
                        activeColor: T.meterRed,
                        onTap: _toggleMute,
                        enabled: !widget.excludedFromMix || elem.mute,
                      ),
                    ],
                  ),
                  // ── Separator ──
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Container(height: 1, color: T.border),
                  ),
                  // ── IAMF controls ──
                  _TrackTypeParams(element: elem),
                  // Badges
                  if (widget.excludedFromMix)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: MixStatusBadge(
                        tooltip: MixStatusBadge.creatorTooltip,
                      ),
                    ),
                  // Horizontal meter — isolated rebuild.
                  // Uses reorderIndex (list position) to look up
                  // meter data; this is correct because the parent
                  // rebuilds with updated indices after reorder.
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: SizedBox(
                      height: meterChannels * 5.0 + 6,
                      child: Consumer(
                        builder: (_, ref, _) {
                          final metrics = ref.watch(animatedMetricsProvider);
                          final raw =
                              widget.reorderIndex < metrics.elementMeters.length
                              ? metrics.elementMeters[widget.reorderIndex]
                              : const <double>[];
                          // Normalize to exactly meterChannels rows: the
                          // engine's count can briefly disagree right
                          // after a format/routing change is applied.
                          final levels = raw.length == meterChannels
                              ? raw
                              : List<double>.generate(
                                  meterChannels,
                                  (c) => c < raw.length ? raw[c] : 0.0,
                                );
                          final peaks =
                              widget.reorderIndex <
                                  metrics.elementPeakHolds.length
                              ? metrics.elementPeakHolds[widget.reorderIndex]
                              : null;
                          final clipped =
                              widget.reorderIndex < metrics.elementClips.length
                              ? metrics.elementClips[widget.reorderIndex]
                              : null;
                          return RotatedBox(
                            quarterTurns: 1,
                            child: MiniMultichannelMeter(
                              levels: levels,
                              peaks: peaks,
                              clipped: clipped,
                              onClipClear: () => ref
                                  .read(clipClearEpochProvider.notifier)
                                  .bump(),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Gutter + waveform under one DropTarget so the label strip
          // is not a dead zone for WAV drops. The row's divider
          // continues under both, level with the panel's; the box
          // takes the row's full height so the line sits on its
          // bottom edge whatever the content's height.
          Expanded(
            child: DecoratedBox(
              key: const ValueKey('track_row_divider'),
              decoration: trackRowDividerDecoration(),
              child: SizedBox(
                height: double.infinity,
                child: DropTarget(
                  onDragEntered: (_) => setState(() => _isDragOver = true),
                  onDragExited: (_) => setState(() => _isDragOver = false),
                  onDragDone: _onDragDone,
                  child: Row(
                    children: [
                      // Channel-label gutter: lane-aligned channel names,
                      // never overlaying the waveform. Empty (background
                      // only) while the track has no WAV.
                      if (widget.gutterWidth > 0)
                        _ChannelLabelGutter(
                          width: widget.gutterWidth,
                          labels: _gutterLaneLabels(elem),
                        ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(T.radiusMd),
                              border: Border.all(
                                color: _isDragOver
                                    ? Color(elem.color).withValues(alpha: 0.6)
                                    : Colors.transparent,
                                width: 1.5,
                              ),
                              color: _isDragOver
                                  ? Color(elem.color).withValues(alpha: 0.06)
                                  : null,
                            ),
                            child: elem.wavPath != null && elem.wavInfo != null
                                ? _TimelineWaveform(
                                    element: elem,
                                    cache: cache,
                                    style: _style,
                                  )
                                : DropZone(
                                    variant: DropZoneVariant.compact,
                                    primaryLabel: _isDragOver
                                        ? 'Drop WAV file'
                                        : 'No WAV file',
                                    isDragOver: _isDragOver,
                                    accentColor: Color(elem.color),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _gainLabel(double db) {
  final s = db.abs().toStringAsFixed(1);
  if (db > 0) return '+$s dB';
  if (db < 0) return '-$s dB';
  return '0.0 dB';
}

/// Channel labels for an element's output (IAMF dest) layout — the
/// base vocabulary for [_gutterLaneLabels].
List<String> _elementChannelLabels(AudioElement elem) {
  final (_, _, outCh) = elementToOarType(elem);
  return elem.type.toLowerCase().contains('scene')
      ? ambisonicsLabels(outCh)
      : iamfChannelLabels(channelCount: outCh, layoutHint: elem.layout);
}

/// Labels for a track's gutter, mirroring MultiChannelWaveform's row
/// resolution exactly: with routing the element renders outCh rows;
/// without, one row per WAV *source* channel — and each row takes the
/// provided label when in range, else the count-based standard label
/// (same fallback as the waveform's _channelLabel). Keeping count and
/// vocabulary in lockstep is what stops the fixed column drifting
/// against the rendered rows on count-mismatched layouts.
List<String> _gutterLaneLabels(AudioElement elem) {
  final wav = elem.wavInfo;
  if (elem.wavPath == null || wav == null) return const [];
  final (_, _, outCh) = elementToOarType(elem);
  final laneCount = elem.inputRouting != null ? outCh : wav.channels;
  final base = _elementChannelLabels(elem);
  return List.generate(
    laneCount,
    (i) => i < base.length ? base[i] : standardChannelLabel(i, laneCount),
  );
}

/// Measured width of the timeline's channel-label gutter: the widest
/// label of any loaded element at the gutter's label style, plus
/// padding — 0 when no element has audio (no gutter, no origin shift).
/// Measured (not hardcoded) so ambisonics label sets and the font-size
/// modes can't clip; ambient DefaultTextStyle merged and the text
/// scaler applied, matching what the rendered Text resolves. Labels
/// are deduped before measuring (the vocabulary is ~25 strings across
/// any session) and painters disposed — this runs per _Timeline build.
double _channelGutterWidth(BuildContext context, List<AudioElement> elements) {
  final labels = <String>{for (final e in elements) ..._gutterLaneLabels(e)};
  if (labels.isEmpty) return 0;
  final base = DefaultTextStyle.of(context).style;
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: base.merge(
          TextStyle(fontSize: T.fontSmall, fontWeight: FontWeight.w500),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final w = painter.width;
    painter.dispose();
    if (w > widest) widest = w;
  }
  if (widest == 0) return 0;
  return (widest + 12).ceilToDouble(); // 6 px padding each side
}

/// Fixed label column at the left edge of a track's waveform area:
/// channel names over the shared gutter backdrop, lane-aligned with
/// the waveform rows via [MultiChannelWaveform.laneHeight], never
/// overlapping audio.
class _ChannelLabelGutter extends StatelessWidget {
  const _ChannelLabelGutter({required this.width, required this.labels});

  final double width;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    // No decoration here: the continuous gutter strip (background +
    // right hairline) is painted once by the timeline's panel
    // backdrop, so the column reads as one piece across the video
    // row, the add slot, and the space below the last track.
    return SizedBox(
      width: width,
      // Fill the track row (the row's Row does not stretch-align).
      height: double.infinity,
      child: labels.isEmpty
          ? null
          // Match the waveform's exact vertical box: the track row
          // pads the block area by 4, and the waveform sits inside a
          // 1.5 px AnimatedContainer border plus the block border (0.5
          // px flat, 1 px beveled and raised) — Container decoration
          // borders inset children, so the gutter must mirror all of it
          // or lanes drift.
          : Padding(
              padding: EdgeInsets.symmetric(
                vertical: 4 + 1.5 + trackBlockBorderWidth(),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final n = labels.length;
                  final chHeight = MultiChannelWaveform.laneHeight(
                    constraints.maxHeight,
                    n,
                  );
                  // Shrink toward the 8 px floor as lanes tighten;
                  // below the height where even the floor clips, hide —
                  // an unreadable label is worse than none, and the
                  // element card still names the layout.
                  final fontSize = min(
                    T.fontSmall,
                    max(T.fontMeter, chHeight * 0.55),
                  );
                  final show = chHeight >= T.fontMeter + 3;
                  return Column(
                    children: [
                      for (var i = 0; i < n; i++)
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: i < n - 1
                                ? MultiChannelWaveform.spacing
                                : 0,
                          ),
                          child: ChannelLabelCell(
                            label: labels[i],
                            height: chHeight,
                            fontSize: fontSize,
                            show: show,
                            tooltip: channelFullName(labels[i]),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}

/// Positions a waveform block proportionally on the timeline.
///
/// The block's width matches its audio duration relative to the
/// transport, and scrolls/zooms in sync with the ruler and playhead.
class _TimelineWaveform extends ConsumerStatefulWidget {
  final AudioElement element;
  final PeakCache cache;
  final WaveformStyle style;

  const _TimelineWaveform({
    required this.element,
    required this.cache,
    required this.style,
  });

  @override
  ConsumerState<_TimelineWaveform> createState() => _TimelineWaveformState();
}

class _TimelineWaveformState extends ConsumerState<_TimelineWaveform> {
  late Widget _stableChild;
  late String _infoLabel;
  late Color _blockColor;
  late int _engineRate;
  // The block's decoration and lane style read T.* when the cached
  // child is built, so a theme switch has to rebuild it explicitly;
  // nothing in didUpdateWidget's list names the theme.
  late AppThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _engineRate = ref.read(audioSettingsProvider).sampleRate;
    _themeMode = T.mode;
    _rebuildStableChild();
  }

  @override
  void didUpdateWidget(_TimelineWaveform old) {
    super.didUpdateWidget(old);
    if (old.element.wavPath != widget.element.wavPath ||
        old.element.wavGeneration != widget.element.wavGeneration ||
        old.element.color != widget.element.color ||
        old.element.type != widget.element.type ||
        old.element.layout != widget.element.layout ||
        old.element.gain != widget.element.gain ||
        !listEquals(old.element.inputRouting, widget.element.inputRouting) ||
        old.style != widget.style ||
        old.cache != widget.cache) {
      _rebuildStableChild();
    }
  }

  void _rebuildStableChild() {
    final elem = widget.element;
    _blockColor = Color(elem.color);
    _infoLabel = fileInfoLabel(
      elem.wavInfo!,
      p.basename(elem.wavPath!),
      engineRate: _engineRate,
    );
    // The waveform renders per-output-channel (IAMF dest) rows when
    // an input routing is set, pulling data from the mapped WAV src
    // channels and silencing unrouted rows. Without routing, it
    // falls back to one row per WAV source channel (identity).
    final (_, _, outCh) = elementToOarType(elem);
    // Convert per-element gain (dB) to a linear amplitude multiplier so
    // the rendered envelope and RMS shrink/grow with the fader. 0 dB =
    // 1.0 (no change). The painter applies this uniformly; clipping at
    // the widget edge is handled by the surrounding ClipRect.
    final amplitudeScale = pow(10, elem.gain / 20).toDouble();
    _stableChild = Container(
      clipBehavior: Clip.hardEdge,
      decoration: trackBlockDecoration(_blockColor),
      child: MultiChannelWaveform(
        key: ValueKey('waveform_${elem.id}_${elem.wavGeneration}'),
        filePath: elem.wavPath!,
        style: trackLaneStyle(widget.style),
        cache: widget.cache,
        channelLabels: _elementChannelLabels(elem),
        inputRouting: elem.inputRouting,
        outputChannelCount: outCh,
        amplitudeScale: amplitudeScale,
        // Labels live in the track's fixed gutter column
        // (_ChannelLabelGutter), never over the waveform.
        showChannelLabels: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final transportDuration = ref.watch(
      transportProvider.select((t) => t.durationSeconds),
    );
    // Watching the engine rate keeps the resampling annotation in
    // step with rate-follow / device switches.
    final engineRate = ref.watch(
      audioSettingsProvider.select((s) => s.sampleRate),
    );
    if (engineRate != _engineRate) {
      _engineRate = engineRate;
      _rebuildStableChild();
    }
    ref.watch(themeModeProvider);
    if (T.mode != _themeMode) {
      _themeMode = T.mode;
      _rebuildStableChild();
    }
    final elem = widget.element;
    final fileDuration = elem.wavInfo!.durationSeconds;
    if (fileDuration <= 0 || transportDuration <= 0) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // Consumer rebuilds only the positioning on scroll —
        // _stableChild is stored in State and reused.
        return Consumer(
          builder: (context, ref, child) {
            final viewport = ref.watch(timelineViewportProvider);
            final visibleDuration = transportDuration / viewport.zoomLevel;
            final startTime =
                viewport.scrollOffset * (transportDuration - visibleDuration);
            final pxPerSec = w / visibleDuration;
            // Blocks start at t=0: the per-element time offset is
            // parked (no UI, no playback effect) pending the keep-or-
            // drop decision on ES-190 — full implementation in PR ES-303.
            final blockLeft = -startTime * pxPerSec;
            final blockWidth = fileDuration * pxPerSec;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                final x = details.localPosition.dx;
                final time = startTime + (x / w) * visibleDuration;
                final frac = (time / transportDuration).clamp(0.0, 1.0);
                ref.read(transportProvider.notifier).seek(frac);
              },
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: blockLeft,
                      width: blockWidth,
                      top: 0,
                      bottom: 0,
                      child: child!,
                    ),
                    // Dim the region past the end of this element's
                    // media so "element ends here" reads differently
                    // from "more media off-view". The
                    // longest element's edge coincides with the
                    // timeline end, so its overlay never shows.
                    if (blockLeft + blockWidth < w)
                      Positioned(
                        // Clamp: fully scrolled-past media would
                        // otherwise paint a viewport-times-zoom-wide
                        // box (correct but wasteful; ClipRect hides it).
                        left: max(blockLeft + blockWidth, 0.0),
                        right: 0,
                        top: 0,
                        bottom: 0,
                        // IgnorePointer: decorative only — must never
                        // swallow hits from future Stack siblings.
                        child: const IgnorePointer(child: _PastEndScrim()),
                      ),
                    Positioned(
                      left: max(blockLeft, 0.0) + 4,
                      right: w - min(blockLeft + blockWidth, w) + 4,
                      bottom: 4,
                      child: TrackInfoChip(
                        text: _infoLabel,
                        color: _blockColor,
                        alignment: Alignment.centerRight,
                        tooltip: elem.wavInfo!.sampleRate != _engineRate
                            ? 'Resampled from '
                                  '${elem.wavInfo!.sampleRate} Hz '
                                  'to the $_engineRate Hz '
                                  'engine rate.'
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          child: _stableChild,
        );
      },
    );
  }
}

/// Theme-aware scrim for the region past a track's end of media; see
/// [T.pastEndScrim] for the per-theme rationale.
class _PastEndScrim extends StatelessWidget {
  const _PastEndScrim();

  @override
  Widget build(BuildContext context) => ColoredBox(color: T.pastEndScrim);
}

/// Shift the timeline viewport by a fractional delta and suppress
/// playback auto-follow so the user's scrub isn't immediately yanked
/// back under the playhead. Shared by both the ruler
/// ([_RulerWithSelectionState]) and the tracks area
/// ([_AudioTracksAreaState]) so mouse-wheel and trackpad pans in
/// either region produce identical state transitions.
void _scrollTimelineBy(WidgetRef ref, double delta) {
  ref.read(timelineViewportProvider.notifier).scrollBy(delta);
  if (ref.read(playingProvider)) {
    ref.read(followOverrideProvider.notifier).set(true);
  }
}

/// Zoom the timeline by [factor] around [pivotFrac] — the pointer's
/// 0–1 position across the visible timeline area, so the time under
/// the cursor stays put. Suppresses playback auto-follow like
/// [_scrollTimelineBy], so a pinch or modifier+wheel zoom isn't
/// immediately yanked back under the playhead. Shared by the ruler
/// ([_RulerWithSelectionState]) and the tracks area
/// ([_AudioTracksAreaState]).
void _zoomTimelineBy(WidgetRef ref, double factor, double pivotFrac) {
  ref
      .read(timelineViewportProvider.notifier)
      .zoomAroundFraction(factor, pivotFrac);
  if (ref.read(playingProvider)) {
    ref.read(followOverrideProvider.notifier).set(true);
  }
}

/// True while the wheel-zoom modifier is held: Cmd on macOS, Ctrl
/// elsewhere (matching each platform's zoom convention).
bool get _zoomModifierPressed => Platform.isMacOS
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;

/// Wheel delta → zoom factor: scrolling up zooms in. The divisor sets
/// sensitivity (~1.5× per classic 120 px wheel notch).
double _wheelZoomFactor(double dy) => exp(-dy / 300);

/// Blocks user scrolling of the track list while the wheel-zoom
/// modifier is held, so Cmd/Ctrl+scroll zooms the timeline without
/// simultaneously scrolling the tracks vertically (the zoom Listener
/// cannot consume the event — Scrollable resolves pointer signals
/// independently). The modifier is checked live because Scrollable
/// consults the physics per scroll event.
class _ZoomModifierAwareScrollPhysics extends ScrollPhysics {
  const _ZoomModifierAwareScrollPhysics({super.parent});

  @override
  _ZoomModifierAwareScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _ZoomModifierAwareScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      !_zoomModifierPressed && super.shouldAcceptUserOffset(position);
}

/// Audio tracks area with a WAV add-new slot at the bottom.
class _AudioTracksArea extends ConsumerStatefulWidget {
  final List<AudioElement> elements;
  final PeakCache cache;
  final ScrollController scrollController;
  final Mix? activeMix;
  final double panelWidth;

  /// Channel-label gutter width between panel and waveforms;
  /// pointer→time math offsets by panel + gutter.
  final double gutterWidth;

  const _AudioTracksArea({
    required this.elements,
    required this.cache,
    required this.scrollController,
    required this.panelWidth,
    required this.gutterWidth,
    this.activeMix,
  });

  @override
  ConsumerState<_AudioTracksArea> createState() => _AudioTracksAreaState();
}

class _AudioTracksAreaState extends ConsumerState<_AudioTracksArea> {
  // Cumulative pinch scale at the previous pan-zoom update; dividing
  // it out yields each update's incremental zoom factor.
  double _lastPinchScale = 1.0;

  @override
  Widget build(BuildContext context) {
    final elems = widget.elements;
    final profile = ref.watch(iamfProfileProvider);
    final atLimit = elems.length >= profile.maxAudioElements;
    // Total item count: elements + optional add-new slot.
    final itemCount = elems.length + (atLimit ? 0 : 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final waveformLeft = widget.panelWidth + widget.gutterWidth;
        final timelineW = constraints.maxWidth - waveformLeft;
        return Listener(
          // Mouse wheel: Cmd/Ctrl+vertical → zoom around the pointer;
          // horizontal scroll → pan timeline.
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            final tlX = event.localPosition.dx - waveformLeft;
            if (tlX <= 0 || timelineW <= 0) return;
            if (_zoomModifierPressed && event.scrollDelta.dy != 0) {
              _zoomTimelineBy(
                ref,
                _wheelZoomFactor(event.scrollDelta.dy),
                tlX / timelineW,
              );
              return;
            }
            if (event.scrollDelta.dx != 0) {
              _scrollTimelineBy(ref, event.scrollDelta.dx / 500);
            }
          },
          onPointerPanZoomStart: (_) => _lastPinchScale = 1.0,
          // Trackpad pinch → zoom around the pointer; two-finger pan →
          // pan timeline. Negate dx so swipe-right reveals earlier
          // content (macOS natural-scroll).
          onPointerPanZoomUpdate: (event) {
            // Track the cumulative scale even while the pointer is
            // over the header panel, so a pinch crossing into the
            // timeline doesn't apply the accumulated jump at once.
            final factor = event.scale / _lastPinchScale;
            _lastPinchScale = event.scale;
            final tlX = event.localPosition.dx - waveformLeft;
            if (tlX <= 0 || timelineW <= 0) return;
            if (factor != 1.0) {
              _zoomTimelineBy(ref, factor, tlX / timelineW);
            }
            final dx = event.panDelta.dx;
            if (dx == 0) return;
            _scrollTimelineBy(ref, -dx / 500);
          },
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ReorderableListView.builder(
              scrollController: widget.scrollController,
              physics: const _ZoomModifierAwareScrollPhysics(),
              padding: EdgeInsets.zero,
              buildDefaultDragHandles: false,
              itemCount: itemCount,
              onReorderItem: (oldIndex, newIndex) {
                // newIndex is pre-adjusted (insertion position after
                // removal). Ignore drags involving the add-new slot:
                // oldIndex == elems.length is the slot itself, and
                // newIndex == elems.length means dropped below it.
                // newIndex == elems.length - 1 is a valid drop at
                // the end of the real list.
                if (oldIndex >= elems.length || newIndex >= elems.length) {
                  return;
                }
                ref.read(elementsProvider.notifier).reorder(oldIndex, newIndex);
              },
              itemBuilder: (context, i) {
                if (i >= elems.length) {
                  return _AddNewTrackSlot(
                    key: const ValueKey('__add_new__'),
                    // No channel labels on the add slot — its panel
                    // cell absorbs the gutter so the drop zone aligns
                    // with the waveform area above.
                    panelWidth: widget.panelWidth + widget.gutterWidth,
                  );
                }
                final elem = elems[i];
                final excluded =
                    widget.activeMix != null &&
                    !widget.activeMix!.settingsFor(elem.id).included;
                return _AudioTrack(
                  key: ValueKey(elem.id),
                  element: elem,
                  cache: widget.cache,
                  reorderIndex: i,
                  excludedFromMix: excluded,
                  panelWidth: widget.panelWidth,
                  gutterWidth: widget.gutterWidth,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Drop-zone slot rendered below the audio track list that creates a
/// new [AudioElement] per WAV file dropped (or picked via tap).
class _AddNewTrackSlot extends ConsumerStatefulWidget {
  final double panelWidth;
  const _AddNewTrackSlot({super.key, required this.panelWidth});

  @override
  ConsumerState<_AddNewTrackSlot> createState() => _AddNewTrackSlotState();
}

class _AddNewTrackSlotState extends ConsumerState<_AddNewTrackSlot> {
  bool _isDragOver = false;

  Future<void> _onDragDone(DropDoneDetails details) async {
    setState(() => _isDragOver = false);
    final wavFiles = details.files
        .where((f) => f.path.toLowerCase().endsWith('.wav'))
        .map((f) => f.path)
        .toList();
    final rejected = details.files.length - wavFiles.length;
    if (wavFiles.isNotEmpty) {
      ref.read(lastImportDirProvider.notifier).set(p.dirname(wavFiles.first));
    }
    await _importBatch(wavFiles, rejected);
  }

  Future<void> _pickAndAdd() async {
    final initialDir = ref.read(lastImportDirProvider);
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select WAV files to add as Audio Elements',
      type: FileType.custom,
      allowedExtensions: ['wav'],
      allowMultiple: true,
      initialDirectory: initialDir,
    );
    if (result == null) return;
    final wavFiles = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    if (wavFiles.isNotEmpty) {
      ref.read(lastImportDirProvider.notifier).set(p.dirname(wavFiles.first));
    }
    await _importBatch(wavFiles, 0);
  }

  /// Import [wavFiles] as new audio elements, capping at the active
  /// IAMF profile's element limit, and surface a single aggregated
  /// notice describing any skipped / failed items. [rejectedByExt]
  /// counts files that were dropped but didn't pass the WAV filter.
  Future<void> _importBatch(List<String> wavFiles, int rejectedByExt) async {
    // Deliberate snapshot: one profile for the whole batch (pre-filter,
    // dialogs, sticky map) keeps the run self-consistent even if the
    // profile changes mid-batch; addNewElementFromWav re-reads the live
    // profile per file and still enforces the real limits. `profile` is
    // only reassigned by a user-confirmed bump below.
    var profile = ref.read(iamfProfileProvider);
    final startProfile = profile;
    final currentCount = ref.read(elementsProvider).length;
    // A first element decides the session's shape, so into an *empty*
    // session the format dialog also offers interpretations beyond the
    // active profile and carries the confirmed switch in its result —
    // the same route as the landing screen's WAV drop. With elements
    // present the profile is settled; gated options stay disabled.
    final allowBump = currentCount == 0;
    final maxElements = startProfile.maxAudioElements;
    // Clamp against negatives: defensive against any future code path
    // that allows the element list to exceed the cap.
    final available = (maxElements - currentCount).clamp(0, maxElements);
    final toImport = wavFiles.take(available).toList();
    final overflow = wavFiles.length - toImport.length;

    // Resolve ambiguous channel counts before importing anything (ES-152):
    // one dialog per ambiguous file, in drop order, with an "apply to
    // remaining" choice that becomes sticky for that channel count.
    // Cancelling any dialog aborts the whole batch — nothing has been
    // imported yet at that point. Files whose header can't be read are
    // skipped here; addNewElementFromWav re-decodes below and produces
    // the standard per-file error message.
    final headers = <String, WavInfo>{};
    for (final path in toImport) {
      try {
        headers[path] = await WavDecoder.readInfo(path);
      } catch (_) {
        // Unreadable/malformed — handled by the import loop below.
      }
    }
    // The prompt order, sticky per-channel-count map, cancel-aborts,
    // and bump carry live in planWavBatch (unit-tested, ES-432); this
    // closure only contributes the real dialog and the mounted gate
    // (unmount reads as a cancel, aborting the batch like before).
    final plan = await planWavBatch(
      paths: toImport,
      headers: headers,
      profile: profile,
      allowProfileBump: allowBump,
      prompt:
          ({
            required String path,
            required WavInfo info,
            required IamfProfile profile,
            required int remainingSameCount,
          }) async {
            if (!mounted) return null;
            return showElementFormatDialog(
              context,
              fileName: p.basename(path),
              channels: info.channels,
              profile: profile,
              sampleRate: info.sampleRate,
              remainingSameCount: remainingSameCount,
              allowProfileBump: allowBump,
            );
          },
    );
    if (plan == null) return; // Cancelled — abort the whole batch.
    // The import runs under a confirmed bump, but the provider is only
    // stamped after the last dialog — cancelling any of them aborts
    // the batch with the session untouched.
    final overrides = plan.overrides;
    profile = plan.profile;
    if (!mounted) return;
    if (profile != startProfile) {
      Log.i(
        LogCat.elements,
        'WAV import: bumping profile ${startProfile.label} -> '
        '${profile.label} (user-confirmed, empty session)',
      );
      ref.read(iamfProfileProvider.notifier).set(profile);
    }

    // Aggregate distinct failure messages so a mixed batch of errors
    // (decode failure + engine reject + unreadable file) doesn't get
    // collapsed to whatever happened to fail first. Preserves
    // insertion order so the first distinct error stays up front.
    final failures = <String, int>{};
    final container = ProviderScope.containerOf(context, listen: false);
    for (final path in toImport) {
      final err = await addNewElementFromWav(
        container,
        path,
        configOverride: overrides[path],
      );
      if (err != null) {
        failures.update(err, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    final notices = <String>[];
    if (rejectedByExt > 0) {
      notices.add(
        rejectedByExt == 1
            ? '1 non-WAV file ignored'
            : '$rejectedByExt non-WAV files ignored',
      );
    }
    if (overflow > 0) {
      // The cap was taken from the pre-batch profile, so name that one
      // even if a bump was confirmed mid-batch.
      notices.add(
        '$overflow skipped \u2014 ${startProfile.label} profile '
        'limit of $maxElements elements',
      );
    }
    for (final entry in failures.entries) {
      notices.add(
        entry.value == 1 ? entry.key : '${entry.key} (\u00D7${entry.value})',
      );
    }
    if (notices.isNotEmpty) {
      // If not a single file made it in (all rejected by extension,
      // decode-failed, or over the profile limit), escalate to a
      // blocker dialog (ES-184); partial success stays a SnackBar.
      final failureCount = failures.values.fold(0, (a, b) => a + b);
      final successes = toImport.length - failureCount;
      final notifier = ref.read(importNoticeProvider.notifier);
      if (successes == 0) {
        notifier.showBlocker(
          '${notices.join('\n')}\n\n'
          'Nothing was imported. Audio elements accept WAV files '
          '(16/24/32-bit).',
        );
      } else {
        notifier.show(notices.join(' \u00B7 '));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: widget.panelWidth),
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _isDragOver = true),
            onDragExited: (_) => setState(() => _isDragOver = false),
            onDragDone: _onDragDone,
            child: SizedBox(
              height: DropZone.areaHeight,
              child: DropZone(
                variant: DropZoneVariant.area,
                icon: Icons.audio_file_outlined,
                primaryLabel: _isDragOver
                    ? 'Drop WAV files'
                    : 'Drop WAV files or click to browse',
                secondaryLabel: 'WAV \u00B7 16/24/32 bit',
                isDragOver: _isDragOver,
                onTap: _pickAndAdd,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Ruler with mouse-drag-to-select loop region and horizontal
/// scroll-to-pan the timeline.
///
/// - Mouse drag: set a loop region drawn as a semi-transparent purple
///   overlay. Auto-enables looping on release.
/// - Click: seek to that position; the loop region is left intact.
/// - Double-click: seek and clear the loop region (Escape also
///   clears).
/// - Mouse wheel / trackpad horizontal pan: scroll the timeline. The
///   drag-to-set-region path is gated on mouse-device events so
///   trackpad two-finger swipes aren't captured as drags —
///   Flutter's horizontal-drag recognizer explicitly opts in to
///   `PointerPanZoom` events via `addAllowedPointerPanZoom`, so
///   without the guard those pans would hijack the drag recognizer
///   and paint loop regions across the swipe path.
class _RulerWithSelection extends ConsumerStatefulWidget {
  const _RulerWithSelection();

  @override
  ConsumerState<_RulerWithSelection> createState() =>
      _RulerWithSelectionState();
}

/// One shared slop for the ruler's two click-vs-gesture decisions:
/// a drag must travel at least this far before it replaces the
/// selection (below it is an accidental micro-drag from a click), and
/// two quick clicks within this distance count as a double-click.
/// It MUST be a single constant: if the drag threshold were smaller
/// than the double-click slop, the jitter on a double-click's second
/// press could arm a drag and overwrite the selection with a sliver —
/// the exact footgun this exists to prevent. Deliberately far tighter
/// than Flutter's kDoubleTapSlop (100 px): two rapid clicks at
/// *different* ruler positions are scrubbing seeks, not a clear.
const double _kRulerClickSlopPx = 6.0;

class _RulerWithSelectionState extends ConsumerState<_RulerWithSelection> {
  double? _dragStartFrac;
  double _dragStartX = 0;
  // Cumulative pinch scale at the previous pan-zoom update; dividing
  // it out yields each update's incremental zoom factor.
  double _lastPinchScale = 1.0;
  // True once the current drag has passed [_kRulerClickSlopPx] and has
  // started writing the loop region.
  bool _dragArmed = false;
  // Manual double-click tracking — see _handleRulerTap.
  DateTime? _lastTapTime;
  double _lastTapX = 0;

  /// Seek to the click position; a second click within
  /// [kDoubleTapTimeout] and [_kRulerClickSlopPx] also clears the
  /// selection/loop region (issue ES-196). Double-click is detected
  /// manually because registering onDoubleTap would make Flutter hold
  /// every single click for ~300 ms to rule out a second one — every
  /// ordinary seek would turn laggy. Side effect (intended): the first
  /// click of a double-click seeks, so double-click means "put the
  /// playhead here and clear the selection".
  void _handleRulerTap(double x, double width) {
    ref.read(transportProvider.notifier).seek(_xToFraction(x, width));
    final now = DateTime.now();
    final isDoubleClick =
        _lastTapTime != null &&
        now.difference(_lastTapTime!) <= kDoubleTapTimeout &&
        (x - _lastTapX).abs() <= _kRulerClickSlopPx;
    if (isDoubleClick) {
      ref.read(loopRegionProvider.notifier).clear();
      // Reset so a triple-click doesn't read as two double-clicks.
      _lastTapTime = null;
    } else {
      _lastTapTime = now;
      _lastTapX = x;
    }
  }

  double _xToFraction(double x, double width) {
    final transport = ref.read(transportProvider);
    final vp = ref.read(timelineViewportProvider);
    if (width <= 0 || transport.durationSeconds <= 0) return 0.0;
    final visibleDuration = transport.durationSeconds / vp.zoomLevel;
    final startTime =
        vp.scrollOffset * (transport.durationSeconds - visibleDuration);
    final t = startTime + (x / width) * visibleDuration;
    return (t / transport.durationSeconds).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // Const-constructed upstream (`const Expanded(child:
    // _RulerWithSelection())`), so parent rebuilds skip this subtree —
    // track theme + font modes here or the ruler's painter is never
    // reconstructed with fresh T.* values after a mode switch.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final transport = ref.watch(transportProvider);
    final viewport = ref.watch(timelineViewportProvider);
    final loopRegion = ref.watch(loopRegionProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        return Listener(
          // Mouse wheel: Cmd/Ctrl+vertical → zoom around the pointer;
          // horizontal scroll → pan timeline.
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || width <= 0) return;
            if (_zoomModifierPressed && event.scrollDelta.dy != 0) {
              _zoomTimelineBy(
                ref,
                _wheelZoomFactor(event.scrollDelta.dy),
                event.localPosition.dx / width,
              );
              return;
            }
            if (event.scrollDelta.dx != 0) {
              _scrollTimelineBy(ref, event.scrollDelta.dx / 500);
            }
          },
          onPointerPanZoomStart: (_) => _lastPinchScale = 1.0,
          // Trackpad pinch → zoom around the pointer; two-finger pan →
          // pan timeline. Negate dx so swipe-right reveals earlier
          // content (macOS natural-scroll).
          onPointerPanZoomUpdate: (event) {
            final factor = event.scale / _lastPinchScale;
            _lastPinchScale = event.scale;
            if (factor != 1.0 && width > 0) {
              _zoomTimelineBy(ref, factor, event.localPosition.dx / width);
            }
            final dx = event.panDelta.dx;
            if (dx == 0) return;
            _scrollTimelineBy(ref, -dx / 500);
          },
          child: GestureDetector(
            // Single click seeks and leaves the selection/loop region
            // intact — only a drag (re)creates it; double-click or
            // Escape clears it (issue ES-196). This matches the waveform
            // lanes, where a tap never destroys the selection.
            onTapUp: (details) {
              _handleRulerTap(details.localPosition.dx, width);
            },
            // Drag to create loop region — mouse only. Trackpad pans
            // are already consumed by the `Listener` wrapper's
            // `onPointerPanZoomUpdate`, so bail out here to avoid
            // setting a loop region from a horizontal swipe.
            onHorizontalDragStart: (details) {
              if (details.kind == PointerDeviceKind.trackpad) {
                _dragStartFrac = null;
                _dragArmed = false;
                return;
              }
              _dragStartFrac = _xToFraction(details.localPosition.dx, width);
              _dragStartX = details.localPosition.dx;
              _dragArmed = false;
            },
            onHorizontalDragUpdate: (details) {
              if (_dragStartFrac == null) return;
              // Don't touch the existing selection until the pointer has
              // moved a few pixels — a stray 1 px drag while clicking
              // must not replace the selection with a sliver.
              if (!_dragArmed) {
                final dx = (details.localPosition.dx - _dragStartX).abs();
                if (dx < _kRulerClickSlopPx) return;
                _dragArmed = true;
              }
              final currentFrac = _xToFraction(details.localPosition.dx, width);
              ref
                  .read(loopRegionProvider.notifier)
                  .setFromFractions(_dragStartFrac!, currentFrac);
            },
            onHorizontalDragEnd: (_) {
              if (_dragStartFrac == null) return;
              final wasArmed = _dragArmed;
              _dragStartFrac = null;
              _dragArmed = false;
              if (!wasArmed) {
                // Sub-threshold wiggle: with a precise pointer the drag
                // recognizer wins the arena over onTapUp for ~any
                // movement, so treat the release as the click it really
                // was (seek + double-click bookkeeping).
                _handleRulerTap(_dragStartX, width);
                return;
              }
              // Auto-enable looping when a region is set
              final region = ref.read(loopRegionProvider);
              if (region != null) {
                ref.read(loopingProvider.notifier).set(true);
              }
            },
            child: Stack(
              children: [
                // Ruler paint
                CustomPaint(
                  painter: TimeRulerPainter(
                    durationSeconds: transport.durationSeconds,
                    zoomLevel: viewport.zoomLevel,
                    scrollOffset: viewport.scrollOffset,
                    playheadSeconds: transport.seconds,
                    fontMode: T.fontMode,
                    themeMode: T.mode,
                  ),
                  size: Size.infinite,
                ),
                // Loop region overlay
                if (loopRegion != null)
                  _LoopRegionOverlay(
                    loopRegion: loopRegion,
                    transport: transport,
                    viewport: viewport,
                    width: width,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LoopRegionOverlay extends StatelessWidget {
  final LoopRegion loopRegion;
  final TransportState transport;
  final TimelineViewport viewport;
  final double width;

  const _LoopRegionOverlay({
    required this.loopRegion,
    required this.transport,
    required this.viewport,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final duration = transport.durationSeconds;
    if (duration <= 0) return const SizedBox.shrink();

    final visibleDuration = duration / viewport.zoomLevel;
    final startTime = viewport.scrollOffset * (duration - visibleDuration);

    final loopStart = loopRegion.startSeconds(transport.sampleRate);
    final loopEnd = loopRegion.endSeconds(transport.sampleRate);

    final x1 = ((loopStart - startTime) / visibleDuration * width).clamp(
      0.0,
      width,
    );
    final x2 = ((loopEnd - startTime) / visibleDuration * width).clamp(
      0.0,
      width,
    );

    if ((x2 - x1).abs() < 1) return const SizedBox.shrink();

    return Positioned(
      left: x1,
      width: x2 - x1,
      top: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: T.purple.withValues(alpha: 0.15),
          border: Border.symmetric(
            vertical: BorderSide(
              color: T.purple.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// _VideoTrack stub removed — replaced by VideoPanel from video/video_panel.dart

/// Whether the timeline's scroll and zoom gutters take the `raised`
/// drawing: the `gutterBg` ground with no rim and bare `chromeTabOff`
/// glyphs.
bool raisedGutter() => T.chromeStyle == ChromeStyle.raised;

/// The hairline along a gutter's inner edge, transparent in the
/// `raised` style. It keeps its 0.5 px either way, since a border insets
/// what it wraps and a component's spacing does not vary by theme.
Color gutterRimColor() =>
    raisedGutter() ? T.border.withValues(alpha: 0) : T.border;

class _TimelineZoomBar extends ConsumerWidget {
  final double panelWidth;
  const _TimelineZoomBar({required this.panelWidth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewport = ref.watch(timelineViewportProvider);
    final vp = ref.read(timelineViewportProvider.notifier);

    return Container(
      height: 20,
      decoration: BoxDecoration(
        color: T.gutterBg,
        // The `raised` style draws no rim, so the ground alone
        // separates the gutter from the tracks. The side stays in the
        // layout as a transparent colour: a border insets what it
        // wraps, so dropping it would move the gutter's content 0.5 px
        // against every other theme's. The bar has square corners and
        // sits flush with the window in every theme.
        border: Border(top: BorderSide(color: gutterRimColor(), width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(width: panelWidth),
          // Horizontal scrollbar — visible only when zoomed in
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: viewport.zoomLevel > 1.0
                  ? _HorizontalScrollbar(
                      viewport: viewport,
                      onScroll: (v) => vp.setScroll(v),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          // Horizontal timeline zoom
          _ZoomButton(
            icon: Icons.remove,
            onTap: () => vp.zoomByAroundPlayhead(0.8),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () {
                vp.setZoom(1.0);
                vp.setScroll(0.0);
              },
              child: Icon(
                Icons.swap_horiz,
                size: T.iconSm,
                color: raisedGutter() ? T.chromeTabOff : T.textTertiary,
              ),
            ),
          ),
          _ZoomButton(
            icon: Icons.add,
            onTap: () => vp.zoomByAroundPlayhead(1.25),
          ),
          // Corner square aligned with vertical zoom strip
          const SizedBox(width: _VerticalZoomStrip.width),
        ],
      ),
    );
  }
}

class _VerticalZoomStrip extends ConsumerStatefulWidget {
  final ScrollController scrollController;

  /// Changes when the track list's extent or viewport changes, which
  /// [scrollController] does not report.
  final ValueListenable<ScrollMetrics?> metrics;

  const _VerticalZoomStrip({
    required this.scrollController,
    required this.metrics,
  });

  /// The strip's width. The ruler, the video row, the playhead and the
  /// zoom bar keep the same space free on the right, so every
  /// time-mapped surface spans the same width.
  static const double width = 20;

  /// The strip's ground and left rim, also drawn beside the video row.
  static BoxDecoration decoration() => BoxDecoration(
    color: T.gutterBg,
    // The `raised` style draws no rim here either, as above.
    border: Border(left: BorderSide(color: gutterRimColor(), width: 0.5)),
  );

  @override
  ConsumerState<_VerticalZoomStrip> createState() => _VerticalZoomStripState();
}

class _VerticalZoomStripState extends ConsumerState<_VerticalZoomStrip> {
  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    widget.metrics.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(_VerticalZoomStrip old) {
    super.didUpdateWidget(old);
    if (old.scrollController != widget.scrollController) {
      old.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
    if (old.metrics != widget.metrics) {
      old.metrics.removeListener(_onScroll);
      widget.metrics.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    widget.metrics.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final vp = ref.read(timelineViewportProvider.notifier);

    return Container(
      width: _VerticalZoomStrip.width,
      decoration: _VerticalZoomStrip.decoration(),
      child: Column(
        children: [
          // Vertical scrollbar — bottom gap mirrors the 8 px the
          // horizontal bar keeps before its zoom buttons.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _VerticalScrollbar(controller: widget.scrollController),
            ),
          ),
          // Zoom controls
          _ZoomButton(icon: Icons.add, onTap: () => vp.scaleTracksBy(1.25)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: GestureDetector(
              onTap: () => vp.setTrackScale(1.0),
              child: Icon(
                Icons.swap_vert,
                size: T.iconSm,
                color: T.textTertiary,
              ),
            ),
          ),
          _ZoomButton(icon: Icons.remove, onTap: () => vp.scaleTracksBy(0.8)),
        ],
      ),
    );
  }
}

/// Inset of a scrollbar thumb from every edge of its track.
const double _kThumbInset = 1;

/// Shortest a scrollbar thumb gets along its track, so it stays easy to
/// grab at high zoom.
const double _kMinThumbLength = 20;

/// Where a thumb sits along a track [trackLength] long: [length] is
/// [viewFraction] of the space inside the inset, at least
/// [_kMinThumbLength]; [offset] places it at [scrollFraction] of its
/// [travel], so at either end it stops [_kThumbInset] short of the
/// track's edge.
({double length, double offset, double travel}) _thumbGeometry(
  double trackLength,
  double viewFraction,
  double scrollFraction,
) {
  final inner = max(0.0, trackLength - 2 * _kThumbInset);
  final length = (viewFraction * inner)
      .clamp(min(_kMinThumbLength, inner), inner)
      .toDouble();
  final travel = inner - length;
  return (
    length: length,
    offset: _kThumbInset + scrollFraction.clamp(0.0, 1.0) * travel,
    travel: travel,
  );
}

/// The thumb's fill, its corners concentric with the track's.
BoxDecoration _thumbDecoration() => BoxDecoration(
  color: T.textGhost,
  borderRadius: BorderRadius.circular(max(0.0, T.radiusSm - _kThumbInset)),
);

class _VerticalScrollbar extends StatelessWidget {
  final ScrollController controller;

  const _VerticalScrollbar({required this.controller});

  static const EdgeInsets _padding = EdgeInsets.symmetric(
    horizontal: 5,
    vertical: 2,
  );

  @override
  Widget build(BuildContext context) {
    if (!controller.hasClients) return const SizedBox.shrink();

    final pos = controller.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) {
      return const SizedBox.shrink();
    }

    final maxExtent = pos.maxScrollExtent;
    final viewFraction =
        pos.viewportDimension / (pos.viewportDimension + maxExtent);
    final scrollFraction = controller.offset / maxExtent;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The track is the space inside the padding.
        final thumb = _thumbGeometry(
          constraints.maxHeight - _padding.vertical,
          viewFraction,
          scrollFraction,
        );

        return GestureDetector(
          onVerticalDragUpdate: thumb.travel <= 0
              ? null
              : (d) {
                  final delta = d.delta.dy / thumb.travel * maxExtent;
                  controller.jumpTo(
                    (controller.offset + delta).clamp(0.0, maxExtent),
                  );
                },
          child: Padding(
            padding: _padding,
            child: Stack(
              children: [
                // Track
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: T.bgDeep,
                      borderRadius: BorderRadius.circular(T.radiusSm),
                    ),
                  ),
                ),
                // Thumb
                Positioned(
                  key: const ValueKey('timeline_vertical_thumb'),
                  top: thumb.offset,
                  left: _kThumbInset,
                  right: _kThumbInset,
                  height: thumb.length,
                  child: Container(decoration: _thumbDecoration()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HorizontalScrollbar extends StatelessWidget {
  final TimelineViewport viewport;
  final ValueChanged<double> onScroll;

  const _HorizontalScrollbar({required this.viewport, required this.onScroll});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final thumb = _thumbGeometry(
          constraints.maxWidth,
          1.0 / viewport.zoomLevel,
          viewport.scrollOffset,
        );

        return GestureDetector(
          onHorizontalDragUpdate: thumb.travel <= 0
              ? null
              : (d) {
                  final delta = d.delta.dx / thumb.travel;
                  onScroll((viewport.scrollOffset + delta).clamp(0.0, 1.0));
                },
          child: Center(
            child: Container(
              height: 10,
              decoration: BoxDecoration(
                color: T.bgDeep,
                borderRadius: BorderRadius.circular(T.radiusSm),
              ),
              child: Stack(
                children: [
                  Positioned(
                    key: const ValueKey('timeline_horizontal_thumb'),
                    left: thumb.offset,
                    width: thumb.length,
                    top: _kThumbInset,
                    bottom: _kThumbInset,
                    child: Container(decoration: _thumbDecoration()),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ZoomButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 20,
        height: 20,
        // The `raised` style draws the zoom controls as bare glyphs:
        // the three button faces are hidden, and only the
        // `chromeTabOff` mark is drawn. Every other theme keeps the
        // app's small control face.
        decoration: raisedGutter()
            ? null
            : BoxDecoration(
                color: T.bgControls,
                borderRadius: BorderRadius.circular(T.radiusSm),
                border: Border.all(color: T.borderStrong, width: 0.5),
              ),
        child: Icon(
          icon,
          size: T.iconXs,
          color: raisedGutter() ? T.chromeTabOff : T.textTertiary,
        ),
      ),
    );
  }
}

/// Lightweight playhead overlay that draws a single vertical line.
///
/// Watches [transportProvider] and [timelineViewportProvider] independently
/// so waveform painters don't repaint every frame.
class _PlayheadOverlay extends ConsumerWidget {
  const _PlayheadOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transport = ref.watch(transportProvider);
    final viewport = ref.watch(timelineViewportProvider);

    return IgnorePointer(
      child: CustomPaint(
        painter: PlayheadPainter(
          durationSeconds: transport.durationSeconds,
          playheadSeconds: transport.seconds,
          zoomLevel: viewport.zoomLevel,
          scrollOffset: viewport.scrollOffset,
          color: T.playhead,
          style: T.chromeStyle,
        ),
        size: Size.infinite,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// IAMF type controls shown in the inline track panel.
// ---------------------------------------------------------------------------

class _TrackTypeParams extends ConsumerWidget {
  final AudioElement element;
  const _TrackTypeParams({required this.element});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FormatChip(
          element: element,
          onTap: () => _openFormatDialog(context, ref),
        ),
        const SizedBox(height: 4),
        if (element.type == 'Object') ..._objectParams(ref),
        if (element.type == 'Channel') ..._channelParams(),
        if (element.type == 'Scene') ..._sceneParams(),
      ],
    );
  }

  /// Open the Format & Routing dialog — the sole surface for switching
  /// an element's type/layout — and apply its result: the routing
  /// matrix plus an optional format change.
  Future<void> _openFormatDialog(BuildContext context, WidgetRef ref) async {
    final result = await showRoutingMatrixDialog(
      context: context,
      element: element,
      profile: ref.read(iamfProfileProvider),
    );
    if (!context.mounted || result == null) return; // Cancel
    // Patch the live element, not the constructor-frozen `element`
    // snapshot: this widget doesn't rebuild while the dialog is open,
    // so applying the result to the snapshot would silently revert any
    // concurrent edit (gain, mute, a WAV reload) when
    // _updateElementById wholesale-replaces the provider entry.
    final elems = ref.read(elementsProvider);
    final idx = elems.indexWhere((e) => e.id == element.id);
    if (idx < 0) return; // Deleted while the dialog was open.
    final live = elems[idx];
    // Empty list = identity routing; persist as null so the engine
    // takes its fast path instead of an explicit routing matrix.
    final routing = result.routing.isEmpty ? null : result.routing;
    var updated = live.copyWith(
      inputRouting: routing,
      clearInputRouting: routing == null,
    );
    // The dialog's format picker can re-type the element (e.g. a 16ch
    // 3OA WAV down-routed to a 1OA scene or a 5.1 bed).
    final cfg = result.config;
    if (cfg != null) {
      updated = updated.copyWith(
        type: cfg.type,
        layout: cfg.layout ?? updated.layout,
        color: _colorForElementType(cfg.type),
        isDual: cfg.isDual ?? false,
        ambisonicsOrder: cfg.ambisonicsOrder ?? 1,
      );
    }
    _updateElem(ref, updated);
  }

  List<Widget> _objectParams(WidgetRef ref) {
    return [
      _CompactSlider(
        label: 'Az',
        // Slider-space is the NEGATED azimuth: IAMF azimuth grows to
        // the LEFT (+90\u00B0 = hard left), but dragging a horizontal
        // slider right must move the object right to match the 3D
        // view, so the thumb position and the stored/displayed value
        // have opposite signs.
        value: -element.azimuth,
        min: -180,
        max: 180,
        resetValue: 0,
        valueText: '${element.azimuth.toStringAsFixed(1)}\u00B0',
        activeColor: T.typeObject,
        onChanged: (v) =>
            _updateElem(ref, element.copyWith(azimuth: -(v * 10).round() / 10)),
      ),
      const SizedBox(height: 2),
      _CompactSlider(
        label: 'El',
        value: element.elevation,
        min: -90,
        max: 90,
        resetValue: 0,
        valueText: '${element.elevation.toStringAsFixed(1)}\u00B0',
        activeColor: T.typeObject,
        onChanged: (v) => _updateElem(
          ref,
          element.copyWith(elevation: (v * 10).round() / 10),
        ),
      ),
      const SizedBox(height: 2),
      _CompactSlider(
        label: 'Dist',
        value: element.distance,
        min: 0,
        max: 1,
        resetValue: 1,
        valueText: element.distance.toStringAsFixed(2),
        activeColor: T.typeObject,
        onChanged: (v) => _updateElem(
          ref,
          element.copyWith(distance: (v * 100).round() / 100),
        ),
      ),
      if (element.isDual) ...[
        const SizedBox(height: 2),
        _CompactSlider(
          label: 'Spr',
          value: element.spread,
          min: 0,
          max: 180,
          valueText: '${element.spread.toStringAsFixed(1)}\u00B0',
          activeColor: T.typeObject,
          onChanged: (v) =>
              _updateElem(ref, element.copyWith(spread: (v * 10).round() / 10)),
        ),
      ],
    ];
  }

  List<Widget> _channelParams() {
    return const [];
  }

  List<Widget> _sceneParams() {
    return const [];
  }

  void _updateElem(WidgetRef ref, AudioElement updated) {
    _updateElementById(ref, updated);
  }
}

/// Clickable element-format chip — the entry point for the Format &
/// Routing dialog, which owns type/layout switching.
///
/// Same pill species as the passive [AeTypeBadge] in the mix and
/// renderer views (shared [aeTypePill] body), full-width, with a
/// trailing matrix glyph announcing what's behind the click — the
/// routing-matrix dialog. The glyph doubles as the routing-state cue:
/// purple (the matrix cells' colour) when a custom input routing is
/// active, type-coloured otherwise. Rests on the neutral control
/// background like the S/M buttons beside it — the type tint appears
/// only on hover and press.
class _FormatChip extends StatefulWidget {
  final AudioElement element;
  final VoidCallback onTap;

  const _FormatChip({required this.element, required this.onTap});

  @override
  State<_FormatChip> createState() => _FormatChipState();
}

class _FormatChipState extends State<_FormatChip> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final el = widget.element;
    final color = aeTypeColor(el.type);
    final routed = el.inputRouting != null;
    final fill = _pressed
        ? color.withValues(alpha: 0.20)
        : _hover
        ? color.withValues(alpha: 0.12)
        : T.bgControls;
    // One tooltip for the whole chip: a nested tooltip on the glyph
    // would stack with this one (hover reaches every MouseRegion whose
    // bounds contain the pointer, not just the innermost).
    final tip =
        'Audio element type \u2014 click to change type and input routing'
        '${routed ? '\nCustom input routing is active' : ''}';
    return Tooltip(
      message: tip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: aeTypePill(
            type: el.type,
            label: el.configLabel,
            height: 24,
            expand: true,
            fill: fill,
            borderColor: _hover || _pressed
                ? color.withValues(alpha: 0.6)
                : T.borderStrong,
            fontSize: T.fontBody,
            trailing: [
              Icon(
                Icons.grid_on,
                size: T.iconXs,
                color: routed
                    ? T.purple
                    : color.withValues(alpha: _hover ? 1.0 : 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact slider fitting within the 180px track panel.
class _CompactSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String valueText;
  final ValueChanged<double> onChanged;
  final Color activeColor;

  /// Double-clicking the slider delivers this value (in slider space)
  /// through [onChanged] — reset-to-default. Null disables the gesture.
  final double? resetValue;

  const _CompactSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueText,
    required this.onChanged,
    required this.activeColor,
    this.resetValue,
  });

  @override
  Widget build(BuildContext context) {
    Widget slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
        thumbColor: T.white,
        activeTrackColor: activeColor,
        inactiveTrackColor: T.bgDeep,
        overlayShape: SliderComponentShape.noOverlay,
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
    if (resetValue != null) {
      // The Slider still wins single taps/drags; only a double tap
      // resets. The first tap of the double tap may nudge the value —
      // the reset lands right after, so the nudge is imperceptible.
      slider = GestureDetector(
        onDoubleTap: () => onChanged(resetValue!),
        child: slider,
      );
    }
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              label,
              style: TextStyle(fontSize: T.fontCaption, color: T.textTertiary),
            ),
          ),
          Expanded(child: slider),
          SizedBox(
            width: 40,
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: T.styleValueSmall,
            ),
          ),
        ],
      ),
    );
  }
}
