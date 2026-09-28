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

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/axes_gizmo_painter.dart';
import '../ffi_bridge.dart' show PlaybackAeKind;
import '../loudness/loudness_report_dialog.dart';
import '../meters/db_utils.dart';
import '../meters/meter_provider.dart';
import '../meters/mini_multichannel_meter.dart';
import '../meters/multichannel_meter_painter.dart';
import '../models/audio_element_enums.dart' show BinauralProfile;
import '../playback/iamf_probe.dart' show IamfAe;
import '../playback/playback_session.dart';
import '../renderer/element_stats.dart';
import '../renderer/mollweide_painter.dart';
import '../renderer/scene_bridge.dart';
import '../renderer/sh_utils.dart' show ShDirectivity;
import '../renderer/three_js_renderer.dart';
import '../renderer/viz_module.dart';
import '../renderer/viz_state.dart';
import '../state.dart';
import '../theme.dart';
import '../util/monitoring_tooltips.dart';
import '../widgets/ae_type_badge.dart';
import '../widgets/app_button.dart';
import '../widgets/console_widgets.dart' show ConsoleToggle;
import '../widgets/mix_status_badge.dart';
import '../widgets/solo_mute_button.dart';
import '../widgets/viz_hud.dart';
import '../widgets/viz_panel.dart';
import '../workspace/workspace_mode.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Channel count helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate channel count from a layout string (e.g. "7.1.4" → 12).
int channelCountForLayout(String layout) {
  final l = layout.toLowerCase();
  if (l.contains('mono') || l.contains('object')) return 1;
  if (l.contains('stereo') || l.contains('binaural')) return 2;
  if (l.contains('9.1.6')) return 16;
  if (l.contains('7.1.5.4')) return 16;
  if (l.contains('7.1.4')) return 12;
  if (l.contains('7.1.2')) return 10;
  if (l.contains('7.1')) return 8;
  if (l.contains('5.1.4')) return 10;
  if (l.contains('5.1.2')) return 8;
  if (l.contains('5.1')) return 6;
  if (l.contains('3.1.2')) return 6;
  if (l.contains('4oa')) return 25;
  if (l.contains('3oa')) return 16;
  if (l.contains('2oa')) return 9;
  if (l.contains('1oa')) return 4;
  return 2;
}

// ─────────────────────────────────────────────────────────────────────────────
// Playback-mode AE → AudioElement adapter
//
// Creator-mode widgets in this file are tightly coupled to AudioElement.
// In Playback mode the AE list lives on `playbackSessionProvider` as
// `List<PlaybackAe>` (engine-reported) cross-referenced by id with
// `IamfProbeReport.audioElements` for the layout label. Synthesize one
// AudioElement per entry so SceneBridge + the meter widgets work
// unchanged. Slot index in EclipsaStudioMeterState matches the list position
// (engine adds AEs to AudioGraph in this order during open_iamf).
// ─────────────────────────────────────────────────────────────────────────────

class _PlaybackRendererInputs {
  final List<AudioElement> elements;
  final List<int> engineOrder;
  const _PlaybackRendererInputs(this.elements, this.engineOrder);
}

_PlaybackRendererInputs _playbackRendererInputs(PlaybackSession s) {
  final probeById = <int, IamfAe>{
    for (final p in s.report.audioElements) p.id: p,
  };
  final elements = <AudioElement>[];
  final order = <int>[];
  for (var i = 0; i < s.audioElements.length; i++) {
    final ae = s.audioElements[i];
    final probe = probeById[ae.audioElementId];
    final type = switch (ae.kind) {
      PlaybackAeKind.channelBased => 'Channel',
      PlaybackAeKind.sceneBased => 'Scene',
      PlaybackAeKind.objectBased => 'Object',
      PlaybackAeKind.unknown => 'Channel',
    };
    final layout = switch (ae.kind) {
      PlaybackAeKind.channelBased => probe?.layoutLabel ?? 'Stereo',
      PlaybackAeKind.sceneBased => '${probe?.ambisonicsOrder ?? 1}OA',
      PlaybackAeKind.objectBased => 'Object',
      PlaybackAeKind.unknown => 'Stereo',
    };
    final color = switch (ae.kind) {
      PlaybackAeKind.sceneBased => T.typeScene.toARGB32(),
      PlaybackAeKind.objectBased => T.typeObject.toARGB32(),
      _ => T.typeChannel.toARGB32(),
    };
    final order_ = ae.kind == PlaybackAeKind.sceneBased
        ? (probe?.ambisonicsOrder ?? 1).clamp(1, 4)
        : 1;
    elements.add(
      AudioElement(
        id: ae.audioElementId,
        name: 'AE ${i + 1}',
        type: type,
        layout: layout,
        codec: 'IAMF',
        color: color,
        ambisonicsOrder: order_,
        // Monitoring solo/mute lives on the playback session (the
        // synthesized elements are rebuilt every frame); carry it in
        // so the S/M buttons reflect it.
        solo: s.soloedAeIds.contains(ae.audioElementId),
        mute: s.mutedAeIds.contains(ae.audioElementId),
      ),
    );
    order.add(ae.audioElementId);
  }
  return _PlaybackRendererInputs(elements, order);
}

// ─────────────────────────────────────────────────────────────────────────────
// Renderer View (top-level)
// ─────────────────────────────────────────────────────────────────────────────

class RendererView extends ConsumerWidget {
  const RendererView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // Left — Input panel
              SizedBox(width: 240, child: _InputPanel()),
              Container(width: 1, color: T.border),
              // Center — 3D Scene
              Expanded(child: _SceneArea()),
              Container(width: 1, color: T.border),
              // Right — Output panel
              SizedBox(width: 240, child: _OutputPanel()),
            ],
          ),
        ),
        Container(height: 1, color: T.border),
        // Bottom — Loudness bar
        const _LoudnessBar(),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Input Panel — audio element cards
// ─────────────────────────────────────────────────────────────────────────────

class _InputPanel extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Track theme/font so the panel repaints on a switch even while idle.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final mode = ref.watch(workspaceModeProvider);
    final metrics = ref.watch(animatedMetricsProvider);

    final List<AudioElement> elements;
    final List<int> engineOrder;
    // Per-element mix settings keyed by element id. Either the active
    // sub-mix's settings (Creator) or settings synthesized from the
    // active IAMF mix presentation (Playback).
    final MixElementSettings? Function(int id) settingsFor;

    if (mode == WorkspaceMode.playback) {
      final session = ref.watch(playbackSessionProvider);
      if (session == null) {
        elements = const [];
        engineOrder = const [];
        settingsFor = (_) => null;
      } else {
        final inputs = _playbackRendererInputs(session);
        elements = inputs.elements;
        engineOrder = inputs.engineOrder;
        final byId = <int, MixElementSettings>{};
        if (session.activeMixIndex >= 0 &&
            session.activeMixIndex < session.report.mixPresentations.length) {
          final mix = session.report.mixPresentations[session.activeMixIndex];
          // Display the gain the engine actually applies — the folded
          // element + sub-mix output gain across ALL sub-mixes
          // (computeMixApplication), not the first-sub-mix raw default.
          final app = computeMixApplication(mix, [
            for (final el in elements) el.id,
          ]);
          // Same for the headphones chip: mirror the rendering config
          // the engine pushes (ES-327). Spec ints map to the enums by
          // index; a missing entry means the engine keeps OAR's default
          // (world-locked / ambient), so the chip shows exactly that.
          final rendering = computeRenderingConfigs(mix);
          app.gainsByElementId.forEach((id, gain) {
            final cfg = rendering[id];
            byId[id] = MixElementSettings(
              elementId: id,
              mixGain: gain,
              headphonesMode: HeadphonesRenderingMode.values[cfg?.mode ?? 1],
              binauralProfile: BinauralProfile.values[cfg?.profile ?? 0],
            );
          });
        }
        settingsFor = (id) => byId[id];
      }
    } else {
      elements = ref.watch(elementsProvider);
      engineOrder = ref.watch(engineOrderProvider);
      final activeSub = _activeSubMix(ref);
      settingsFor = (id) => activeSub?.settingsFor(id);
    }

    final excludedIds = _excludedFromActiveMix(ref, elements);

    return Container(
      color: T.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: Text(
              'AUDIO ELEMENTS',
              style: TextStyle(
                fontSize: T.fontBody,
                color: T.textMuted,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(height: 1, color: T.border),
          // Element list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: elements.length,
              itemBuilder: (context, index) {
                final el = elements[index];
                final meterIdx = engineOrder.indexOf(el.id);
                final levels =
                    meterIdx >= 0 && meterIdx < metrics.sidebarMeters.length
                    ? metrics.sidebarMeters[meterIdx]
                    : <double>[];
                final peaks =
                    meterIdx >= 0 && meterIdx < metrics.sidebarPeakHolds.length
                    ? metrics.sidebarPeakHolds[meterIdx]
                    : null;
                final clipped =
                    meterIdx >= 0 && meterIdx < metrics.elementClips.length
                    ? metrics.elementClips[meterIdx]
                    : null;
                final settings = settingsFor(el.id);
                final excluded = excludedIds.contains(el.id);
                return _InputElementCard(
                  element: el,
                  levels: levels,
                  peaks: peaks,
                  clipped: clipped,
                  excludedFromMix: excluded,
                  mixSettings: settings,
                );
              },
            ),
          ),
          // Presentation output mix gain, pinned under the element list
          // whose levels it scales (ES-293). Renders nothing when no
          // mix/presentation is active.
          const _OutputMixGainReadout(),
        ],
      ),
    );
  }
}

/// Resolve the active sub-mix from the mix providers with defensive
/// clamping. Returns `null` when there are no mixes, so callers can
/// skip "not in mix" badging gracefully. Used by `_InputPanel`.
SubMix? _activeSubMix(WidgetRef ref) {
  final mixes = ref.watch(mixesNotifierProvider);
  if (mixes.isEmpty) return null;
  final mixIdx = ref.watch(activeMixProvider).clamp(0, mixes.length - 1);
  final mix = mixes[mixIdx];
  if (mix.subMixes.isEmpty) return null;
  final subIdx = ref
      .watch(activeSubMixProvider)
      .clamp(0, mix.subMixes.length - 1);
  return mix.subMixes[subIdx];
}

/// Ids of [elements] excluded from the active mix, in either mode:
/// the active sub-mix's `included` flags in Creator, the selected mix
/// presentation's element set in Playback. Empty when there is no
/// active mix to gate on. These elements are audibly gated by the
/// engine, so the renderer greys their card and hides them from the
/// 3D scene.
Set<int> _excludedFromActiveMix(WidgetRef ref, List<AudioElement> elements) {
  final mode = ref.watch(workspaceModeProvider);
  if (mode == WorkspaceMode.playback) {
    final session = ref.watch(playbackSessionProvider);
    final mps = session?.report.mixPresentations ?? const [];
    final idx = session?.activeMixIndex ?? -1;
    if (idx < 0 || idx >= mps.length) return const {};
    return computeMixApplication(mps[idx], [
      for (final el in elements) el.id,
    ]).excludedElementIds;
  }
  final activeSub = _activeSubMix(ref);
  if (activeSub == null) return const {};
  return {
    for (final el in elements)
      if (!activeSub.settingsFor(el.id).included) el.id,
  };
}

class _InputElementCard extends ConsumerWidget {
  final AudioElement element;
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;
  final bool excludedFromMix;
  final MixElementSettings? mixSettings;

  const _InputElementCard({
    required this.element,
    required this.levels,
    this.peaks,
    this.clipped,
    this.excludedFromMix = false,
    this.mixSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Color(element.color);
    final type = element.type.toLowerCase();
    final isObject = type.contains('object');
    final channelCount = channelCountForLayout(element.layout);
    // The card's chips are read-only indicators; their tooltips say
    // where the value is edited (Creator) or that it comes from the
    // file (Playback) — see ES-328.
    final playback = ref.watch(workspaceModeProvider) == WorkspaceMode.playback;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: T.bgSurface,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.borderLight),
      ),
      // Excluded elements stay listed (with the NOT IN MIX badge) but
      // read as inactive — they are audibly gated by the engine.
      child: Opacity(
        opacity: excludedFromMix ? 0.45 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name + S/M (full width)
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                const SizedBox(width: T.gapPair),
                Expanded(
                  child: Text(
                    element.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: T.fontBody,
                      color: T.textValue,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // Mix-excluded elements are already silent, so
                // engaging S/M is disabled (clear-only): an engaged
                // button stays tappable to un-latch a solo/mute set
                // before the exclusion (ES-297).
                SoloMuteButton(
                  label: 'S',
                  tooltip: excludedFromMix && !element.solo
                      ? kSoloMuteExcludedTooltip
                      : kSoloTooltip,
                  active: element.solo,
                  activeColor: T.meterYellow,
                  onTap: () =>
                      _toggleSoloMute(ref, element, solo: !element.solo),
                  enabled: !excludedFromMix || element.solo,
                ),
                const SizedBox(width: 4),
                SoloMuteButton(
                  label: 'M',
                  tooltip: excludedFromMix && !element.mute
                      ? kSoloMuteExcludedTooltip
                      : kMuteTooltip,
                  active: element.mute,
                  activeColor: T.meterRed,
                  onTap: () =>
                      _toggleSoloMute(ref, element, mute: !element.mute),
                  enabled: !excludedFromMix || element.mute,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Details + meter
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AeTypeBadge(type: element.type, layout: element.layout),
                        if (isObject) ...[
                          const SizedBox(height: T.gapPair),
                          Tooltip(
                            message: playback
                                ? 'Position of this object element, as '
                                      'authored in the file.'
                                : 'Position of this object element. Edit it '
                                      'in the Elements tab.',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _PropRow(
                                  'Az',
                                  '${element.azimuth.toStringAsFixed(1)}°',
                                ),
                                _PropRow(
                                  'El',
                                  '${element.elevation.toStringAsFixed(1)}°',
                                ),
                                _PropRow(
                                  'Dist',
                                  element.distance.toStringAsFixed(2),
                                ),
                                if (element.isDual)
                                  _PropRow(
                                    'Spread',
                                    '${element.spread.toStringAsFixed(1)}°',
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        _MixStatus(
                          excludedFromMix: excludedFromMix,
                          mixGain: mixSettings?.mixGain ?? 0,
                          playback: playback,
                        ),
                        if (!excludedFromMix && mixSettings != null) ...[
                          const SizedBox(height: 4),
                          _BinauralSettings(
                            settings: mixSettings!,
                            element: element,
                            playback: playback,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: T.gapPair),
                  SizedBox(
                    width: (channelCount * 5.0).clamp(12, 60),
                    child: MiniMultichannelMeter(
                      levels: levels.isEmpty
                          ? List.filled(math.max(1, channelCount), 0.0)
                          : levels,
                      peaks: peaks,
                      clipped: clipped,
                      onClipClear: () =>
                          ref.read(clipClearEpochProvider.notifier).bump(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MixStatus extends StatelessWidget {
  final bool excludedFromMix;
  final double mixGain;
  final bool playback;

  const _MixStatus({
    required this.excludedFromMix,
    required this.mixGain,
    required this.playback,
  });

  @override
  Widget build(BuildContext context) {
    if (excludedFromMix) {
      return MixStatusBadge(
        tooltip: playback
            ? 'The selected presentation does not include this element, '
                  'as authored in the file.'
            : MixStatusBadge.creatorTooltip,
      );
    }
    return Tooltip(
      message: playback
          ? 'Mix gain of this element in the selected presentation, '
                'as authored in the file.'
          : 'Mix gain of this element in the active mix. Edit it on '
                'the element\'s channel strip in the Mix tab.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: T.bgControls,
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune, size: 10, color: T.textGhost),
            const SizedBox(width: 4),
            Text(
              '${mixGain.toStringAsFixed(1)} dB',
              style: TextStyle(
                fontSize: T.fontCaption,
                fontFamily: T.monoFamily,
                color: T.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BinauralSettings extends StatelessWidget {
  final MixElementSettings settings;
  final AudioElement element;
  final bool playback;

  const _BinauralSettings({
    required this.settings,
    required this.element,
    required this.playback,
  });

  @override
  Widget build(BuildContext context) {
    final mode = settings.effectiveHeadphonesMode(element);
    final isStereo = mode == HeadphonesRenderingMode.stereo;

    return Tooltip(
      message: playback
          ? 'Headphones rendering mode and binaural profile of this '
                'element, as authored in the file.'
          : 'Headphones rendering mode and binaural profile of this '
                'element in the active mix. Edit them on the element\'s '
                'channel strip in the Mix tab.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: T.bgControls,
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones, size: 10, color: T.textGhost),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                isStereo
                    ? 'Stereo'
                    : '${mode.label.replaceFirst('Binaural ', '')} · '
                          '${settings.binauralProfile.displayName}',
                overflow: TextOverflow.ellipsis,
                style: T.styleHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _toggleSoloMute(
  WidgetRef ref,
  AudioElement element, {
  bool? solo,
  bool? mute,
}) {
  // In Playback the cards show synthesized elements, so the state
  // lives on the playback session; its notifier also mirrors the
  // change to the engine.
  if (ref.read(workspaceModeProvider) == WorkspaceMode.playback) {
    final notifier = ref.read(playbackSessionProvider.notifier);
    if (solo != null) notifier.setAeSolo(element.id, solo);
    if (mute != null) notifier.setAeMute(element.id, mute);
    return;
  }
  final elems = ref.read(elementsProvider);
  final idx = elems.indexWhere((e) => e.id == element.id);
  if (idx < 0) return;
  final updated = elems[idx].copyWith(
    solo: solo ?? elems[idx].solo,
    mute: mute ?? elems[idx].mute,
  );
  final list = List<AudioElement>.from(elems)..[idx] = updated;
  ref.read(elementsProvider.notifier).set(list);

  final engine = ref.read(eclipsaStudioEngineProvider);
  if (engine != null) {
    if (solo != null) engine.setElementSolo(element.id, updated.solo);
    if (mute != null) engine.setElementMute(element.id, updated.mute);
  }
}

class _PropRow extends StatelessWidget {
  final String label;
  final String value;
  const _PropRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(width: 42, child: Text(label, style: T.styleHint)),
          Text(
            value,
            style: TextStyle(
              fontFamily: T.monoFamily,
              fontSize: T.fontCaption,
              color: T.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scene Area — 3D viewport placeholder + layout overlay
// ─────────────────────────────────────────────────────────────────────────────

class _SceneArea extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SceneArea> createState() => _SceneAreaState();
}

class _SceneAreaState extends ConsumerState<_SceneArea> {
  late ThreeJsRenderer _renderer;
  late Widget _sceneWidget;

  @override
  void initState() {
    super.initState();
    _renderer = ThreeJsRenderer();
    _sceneWidget = _renderer.buildWidget();
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch theme so a mode change rebuilds and pushes the new
    // background colour into the GL clear color (the three_js
    // renderer caches it from Settings at init time).
    ref.watch(themeModeProvider);
    _renderer.setClearColor(T.bgDeep);
    final mode = ref.watch(workspaceModeProvider);
    final metrics = ref.watch(animatedMetricsProvider);
    final List<AudioElement> elements;
    final List<int> engineOrder;
    if (mode == WorkspaceMode.playback) {
      final session = ref.watch(playbackSessionProvider);
      if (session == null) {
        elements = const [];
        engineOrder = const [];
      } else {
        final inputs = _playbackRendererInputs(session);
        elements = inputs.elements;
        engineOrder = inputs.engineOrder;
      }
    } else {
      elements = ref.watch(elementsProvider);
      engineOrder = ref.watch(engineOrderProvider);
    }
    // Elements excluded from the active mix are audibly gated by the
    // engine — hide them from the 3D scene (and its overlays) so the
    // view shows what the selected mix actually renders. The input
    // panel keeps them listed, greyed out.
    final excludedIds = _excludedFromActiveMix(ref, elements);
    final sceneElements = excludedIds.isEmpty
        ? elements
        : [
            for (final el in elements)
              if (!excludedIds.contains(el.id)) el,
          ];
    final colormap = ref.watch(colormapProvider);
    // Watch so the scene rebuilds when modules are toggled or params
    // change. The actual VizState map is read via the notifier below.
    ref.watch(vizStateProvider);
    final vizNotifier = ref.read(vizStateProvider.notifier);
    final mollweideState = vizNotifier.stateFor('mollweide');
    final showMol = mollweideState.enabled;
    final mollweideDirIdx = (mollweideState.values['directivity'] ?? 2.0)
        .round()
        .clamp(0, 2);
    final shDir = switch (mollweideDirIdx) {
      0 => ShDirectivity.basic,
      1 => ShDirectivity.maxRe,
      _ => ShDirectivity.inPhase,
    };
    // Build id→slot map once, then look up per element in O(1).
    final idToSlot = <int, int>{
      for (var i = 0; i < engineOrder.length; i++) engineOrder[i]: i,
    };
    final elementLevels = <List<double>>[];
    for (final el in sceneElements) {
      final idx = idToSlot[el.id];
      if (idx != null && idx < metrics.sidebarMeters.length) {
        elementLevels.add(metrics.sidebarMeters[idx]);
      } else {
        elementLevels.add(const []);
      }
    }

    // Read per-element channel stats in engine-slot order, then
    // reorder to match the UI element list (same mapping as levels).
    // Skip the FFI read + copy entirely when no consumer needs it —
    // matches the audio-thread gate so idle visualizers cost nothing
    // on either side of the FFI boundary.
    final engine = ref.read(eclipsaStudioEngineProvider);
    final hudVisible = ref.watch(vizHudVisibleProvider);
    final statsNeeded =
        hudVisible ||
        VizRegistry.ofDomain(
          VizDomain.channel,
        ).any((m) => vizNotifier.stateFor(m.id).enabled);
    final rawStats = statsNeeded
        ? (engine?.readElementStats() ?? const <ElementStats>[])
        : const <ElementStats>[];
    final elementStats = <ElementStats>[];
    for (final el in sceneElements) {
      final idx = idToSlot[el.id];
      elementStats.add(
        (idx != null && idx < rawStats.length)
            ? rawStats[idx]
            : ElementStats.empty(),
      );
    }

    // metrics.shSnapshots is positionally aligned to the FULL element
    // list (see the tick loop's uiSh), and SceneBridge indexes it by
    // list position — re-align it to the filtered scene list or the
    // soundfield visuals would show the wrong element's data.
    final List<List<double>> sceneSh;
    if (identical(sceneElements, elements)) {
      sceneSh = metrics.shSnapshots;
    } else {
      final fullIndexById = <int, int>{
        for (var i = 0; i < elements.length; i++) elements[i].id: i,
      };
      sceneSh = [
        for (final el in sceneElements)
          switch (fullIndexById[el.id]) {
            final int i when i < metrics.shSnapshots.length =>
              metrics.shSnapshots[i],
            _ => const <double>[],
          },
      ];
    }

    // Build renderable scene from state
    final scene = SceneBridge.build(
      elements: sceneElements,
      engine: engine,
      levels: elementLevels,
      stats: elementStats,
      shSnapshots: sceneSh,
      colormap: colormap,
      vizNotifier: vizNotifier,
    );

    // Update the three_js renderer (does not rebuild widget)
    _renderer.updateScene(scene);

    final molVisible =
        showMol && scene.shCoeffs != null && scene.shCoeffs!.isNotEmpty;
    // Keep the centered HUD clear of the bottom-corner overlays: inset
    // it by the wider corner's footprint (edge inset + overlay width +
    // gap) on BOTH sides so it stays centered and only shrinks when
    // the scene is actually narrow (ES-317). The HUD's grids are Wraps,
    // so they reflow at the reduced width.
    final hudInset = molVisible
        ? T.gapMd +
              200 +
              T
                  .gapSm // Mollweide box (wider than the gizmo)
        : T.gapMd + 56 + T.gapSm; // AxesGizmo, always present

    return ColoredBox(
      color: T.bgDeep,
      child: Stack(
        children: [
          _sceneWidget,
          // Axes gizmo — bottom left
          Positioned(
            left: T.gapMd,
            bottom: T.gapMd,
            child: IgnorePointer(
              child: AxesGizmo(
                cameraRotation: _renderer.cameraRotationNotifier,
              ),
            ),
          ),
          // Camera presets — top right
          Positioned(
            right: T.gapMd,
            top: T.gapMd,
            child: _CameraPresetBar(onPreset: _renderer.setCameraPreset),
          ),
          // Visualizer modules panel — top left
          const Positioned(left: T.gapMd, top: T.gapMd, child: VizPanel()),
          // Stats HUD — bottom center, gated by toggle.
          if (hudVisible)
            Positioned(
              left: hudInset,
              right: hudInset,
              bottom: T.gapMd,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: VizHud(stats: elementStats, elements: sceneElements),
              ),
            ),
          // Mollweide overlay — bottom right
          if (molVisible)
            Positioned(
              right: T.gapMd,
              bottom: T.gapMd,
              child: IgnorePointer(
                child: Container(
                  width: 200,
                  height: 100,
                  decoration: BoxDecoration(
                    color: T.bgDeep.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(T.radiusSm),
                    border: Border.all(color: T.borderLight),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(T.radiusSm),
                    child: CustomPaint(
                      painter: MollweidePainter(
                        shCoeffs: scene.shCoeffs!,
                        order: scene.shOrder,
                        colormap: colormap,
                        directivity: shDir,
                        engine: ref.read(eclipsaStudioEngineProvider),
                        gridW: 192,
                        gridH: 96,
                      ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Camera Preset Bar
// ─────────────────────────────────────────────────────────────────────────────

class _CameraPresetBar extends StatelessWidget {
  final void Function(CameraPreset) onPreset;
  const _CameraPresetBar({required this.onPreset});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: T.bgSurface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.borderLight),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PresetBtn('Top', () => onPreset(CameraPreset.top)),
          Container(width: 1, height: 20, color: T.borderLight),
          _PresetBtn('Front', () => onPreset(CameraPreset.front)),
          Container(width: 1, height: 20, color: T.borderLight),
          _PresetBtn('3D', () => onPreset(CameraPreset.perspective)),
        ],
      ),
    );
  }
}

class _PresetBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PresetBtn(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: T.fontSmall,
              color: T.textTertiary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Output Panel — layout, meters, master volume
// ─────────────────────────────────────────────────────────────────────────────

class _OutputPanel extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Track theme/font so the panel repaints on a switch even while idle.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final metrics = ref.watch(animatedMetricsProvider);
    final monConfig = ref.watch(monitoringConfigProvider);
    final outCh = monConfig.layout.channels;
    final outLevels = metrics.meters.length >= outCh
        ? metrics.meters.sublist(0, outCh)
        : List.filled(outCh, 0.0);
    final outPeaks = metrics.meterPeakHolds.length >= outCh
        ? metrics.meterPeakHolds.sublist(0, outCh)
        : null;
    final outClips = metrics.outputClips.length >= outCh
        ? metrics.outputClips.sublist(0, outCh)
        : null;

    return Container(
      color: T.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with monitoring settings shortcut
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  'MONITORING',
                  style: TextStyle(
                    fontSize: T.fontBody,
                    color: T.textMuted,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                const _DimToggle(),
              ],
            ),
          ),
          Container(height: 1, color: T.border),

          // ── Output target switcher ────────────────────────────────────
          // Daily switcher over the curated exposed set; full set
          // management (add/remove/routing) lives in the Settings dialog.
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _OutputTargetSwitcher(),
          ),

          // ── Output meters + GR bar ──────────────────────────────────────
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: MultichannelMeter(
                      levels: outLevels,
                      peaks: outPeaks,
                      clipped: outClips,
                      // Labels must come from the active layout, not the
                      // count-based default: the bars are the engine's
                      // output bus in OAR channel order, and 8 channels
                      // alone can't tell 5.1.2 from 7.1 (ES-552).
                      labels: monConfig.layout.speakerLabels,
                      onClipClear: () =>
                          ref.read(clipClearEpochProvider.notifier).bump(),
                    ),
                  ),
                  const SizedBox(width: T.gapPair),
                  _GrBar(
                    gr: metrics.limiterGr,
                    peakDb: metrics.limiterGrPeakDb,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Monitor DIM toggle (ES-629): a fixed −20 dB cut on the monitoring
/// output, after the render, the limiter and the meters, so the meters
/// beside it keep showing the program. Lives here, beside the output
/// meters, and not on the Mix view's master strip, which is exported
/// mix-presentation metadata; the status bar item and the D key reach
/// it from every view.
class _DimToggle extends ConsumerWidget {
  const _DimToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final dim = ref.watch(monitorDimProvider);
    return Tooltip(
      message: kMonitorDimTooltip,
      child: ConsoleToggle(
        label: 'DIM',
        value: dim,
        activeColor: T.objAmber,
        onChanged: (v) => ref.read(monitorDimProvider.notifier).set(v),
      ),
    );
  }
}

/// Read-only dB readout of the active presentation's output mix gain
/// (ES-293): the active sub-mix's `outputMixGain` in Creator, the
/// selected presentation's sub-mix `outputMixGainDb` in Playback.
/// Pinned as a footer under the audio elements list whose levels it
/// scales; editing stays in the mix editor's master strip — this is a
/// readout, not a control. Hidden (including its separator) when no
/// mix/presentation is active.
class _OutputMixGainReadout extends ConsumerWidget {
  const _OutputMixGainReadout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final mode = ref.watch(workspaceModeProvider);

    final bool hasMix;
    final double? gainDb; // null with hasMix → differs per sub-mix
    if (mode == WorkspaceMode.playback) {
      // Resolution logic (incl. the disagreeing-sub-mix branch) lives
      // in playbackOutputMixGainReadout, where it is unit-testable.
      final readout = playbackOutputMixGainReadout(
        ref.watch(playbackSessionProvider),
      );
      hasMix = readout.show;
      gainDb = readout.gainDb;
    } else {
      final activeSub = _activeSubMix(ref);
      hasMix = activeSub != null;
      gainDb = activeSub?.outputMixGain;
    }
    if (!hasMix) return const SizedBox.shrink();

    final message = mode == WorkspaceMode.playback
        ? (gainDb == null
              ? 'Output mix gain of the selected presentation. It '
                    'differs between this presentation\'s sub-mixes, so no '
                    'single value applies.'
              : 'Output mix gain of the selected presentation, as authored '
                    'in the file. Applied to everything in the mix.')
        : 'Output mix gain of the active mix, applied to everything in '
              'the mix. Edit it in the mix editor\'s master strip.';
    return Column(
      children: [
        Container(height: 1, color: T.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Tooltip(
            message: message,
            child: Row(
              children: [
                Text(
                  'OUTPUT MIX GAIN',
                  style: TextStyle(
                    fontSize: T.fontBody,
                    color: T.textMuted,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  gainDb == null ? '—' : '${gainDb.toStringAsFixed(1)} dB',
                  style: T.styleValue,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Output Target Switcher — wrapping label-only buttons over the exposed set
// ─────────────────────────────────────────────────────────────────────────────

class _OutputTargetSwitcher extends ConsumerWidget {
  const _OutputTargetSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final config = ref.watch(monitoringConfigProvider);
    final devCh = ref.watch(outputDeviceChannelsProvider);
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final t in config.targets)
            _SwitcherButton(
              label: t.layout.label,
              active: t.layout == config.activeLayout,
              enabled: t.layout.channels <= devCh,
              onTap: () => ref
                  .read(monitoringConfigProvider.notifier)
                  .setActive(t.layout),
            ),
        ],
      ),
    );
  }
}

class _SwitcherButton extends StatelessWidget {
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  const _SwitcherButton({
    required this.label,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Active chip: solid accent gradient + on-accent text + soft glow so the
    // selected monitoring system is unmistakable. Inactive chips stay subtle
    // (bgDeep fill, hairline border) to maximize the contrast between them.
    // Disabled targets (layout channels > device channels) dim the fill,
    // border, glow and inactive label by `dim`; the gradient stops carry
    // their own alpha since withValues() can't reach a gradient through a
    // single fill color. The active chip's label is not dimmed.
    final dim = enabled ? 1.0 : 0.35;
    final child = Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? null : T.bgDeep.withValues(alpha: dim),
        gradient: active
            ? LinearGradient(
                colors: [
                  T.purple.withValues(alpha: dim),
                  T.pink.withValues(alpha: dim),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: active ? Colors.transparent : T.border.withValues(alpha: dim),
          width: 1,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: T.purple.withValues(alpha: 0.45 * dim),
                  blurRadius: 6,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: T.fontBody,
          // The active chip's label is textPrimary at full strength
          // when disabled: dimmed, accentFg on the dimmed accent fill
          // fell to 1.29:1 in High Contrast and 1.35:1 in Light;
          // textPrimary is at least 6.1:1 on it in every theme.
          // Inactive chips dim as before.
          color: enabled
              ? (active ? T.accentFg : T.textTertiary)
              : (active
                    ? T.textPrimary
                    : T.textTertiary.withValues(alpha: dim)),
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
    if (!enabled) return IgnorePointer(child: child);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GR Bar — thin vertical gain-reduction indicator
// ─────────────────────────────────────────────────────────────────────────────

/// Full-scale of the GR bar, in dB of reduction. A −1 dBFS limiter on
/// mixed program works in roughly the top 6 dB; the previous 24 dB
/// scale spent three quarters of the bar on depths you never see.
/// Reduction past this pins the fill — the readout still shows the
/// true value.
const double _kGrRangeDb = 12.0;

/// Interior tick positions, in dB of reduction. Unlabelled by design:
/// at 12 px of bar width there is no room for numbers, and evenly
/// spaced thirds are learned in one glance.
const List<double> _kGrTicksDb = [3.0, 6.0, 9.0];

class _GrBar extends StatelessWidget {
  final double gr;
  final double peakDb;
  const _GrBar({required this.gr, required this.peakDb});

  @override
  Widget build(BuildContext context) {
    // GR as a positive dB magnitude, matching the Loudness Report's GR
    // lane (0 = no reduction, growing downward). Passed UNCLAMPED: the
    // painter bounds the geometry at full scale, but the readout has to
    // keep showing the true depth past it.
    final grDb = DbUtils.linearGrToDb(gr);

    return SizedBox(
      width: 18,
      child: Container(
        decoration: T.decoControl(borderColor: T.border, borderWidth: 0.5),
        child: CustomPaint(
          painter: _GrBarPainter(
            grDb: grDb,
            peakDb: peakDb,
            fontMode: T.fontMode,
            themeMode: T.mode,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _GrBarPainter extends CustomPainter {
  final double grDb;
  final double peakDb;
  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  const _GrBarPainter({
    required this.grDb,
    required this.peakDb,
    required this.fontMode,
    required this.themeMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();

    const padV = 6.0;
    const labelH = 14.0;
    final barAreaH = size.height - padV * 2 - labelH;
    if (barAreaH <= 0) return;

    final barX = 3.0;
    final barW = size.width - 6.0;

    // Track background.
    paint.color = T.bgDeep;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(barX, padV, barW, barAreaH),
        const Radius.circular(1),
      ),
      paint,
    );

    // Filled portion — grows downward from top.
    final fillH = barAreaH * (grDb / _kGrRangeDb).clamp(0.0, 1.0);
    if (fillH > 0) {
      paint.color = T.purple;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(barX, padV, barW, fillH),
          const Radius.circular(1),
        ),
        paint,
      );
    }

    // Interior ticks. Each one is drawn in whichever colour reads
    // against what is behind it at that height — a dark notch where the
    // fill has reached it, a hairline where the track is still bare —
    // so the scale stays legible at every reduction depth.
    paint
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    for (final db in _kGrTicksDb) {
      final y = padV + barAreaH * (db / _kGrRangeDb);
      paint.color = y <= padV + fillH
          ? T.bgDeep.withValues(alpha: 0.55)
          : T.borderLight;
      canvas.drawLine(Offset(barX, y), Offset(barX + barW, y), paint);
    }

    // Peak hold — a neutral bright line rather than another accent, so
    // it reads on both the purple fill and the bare track without
    // taking on colour meaning (ES-191).
    if (peakDb > 0.05) {
      final py = padV + barAreaH * (peakDb / _kGrRangeDb).clamp(0.0, 1.0);
      paint
        ..color = T.textPrimary.withValues(alpha: 0.85)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(barX, py), Offset(barX + barW, py), paint);
    }
    paint.style = PaintingStyle.fill;

    // Label at bottom: reduction depth to one decimal, unsigned like
    // the Loudness Report's GR lane. At the 1–3 dB depths this limiter
    // actually works at, whole dB was too coarse to compare laws by.
    final label = grDb > 0.05 ? grDb.toStringAsFixed(1) : 'GR';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: T.fontMeter,
          color: T.textTertiary,
          fontFamily: T.monoFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, padV + barAreaH + 3));
  }

  @override
  bool shouldRepaint(_GrBarPainter old) =>
      old.grDb != grDb ||
      old.peakDb != peakDb ||
      old.fontMode != fontMode ||
      old.themeMode != themeMode;
}

// ─────────────────────────────────────────────────────────────────────────────
// Loudness Bar — BS.1770-4 measurements + scene info
// ─────────────────────────────────────────────────────────────────────────────

class _LoudnessBar extends ConsumerWidget {
  const _LoudnessBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // const _LoudnessBar() is canonicalised, so without watching theme/font it
    // (and its const children) would freeze on a switch.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    return Container(
      height: 36,
      color: T.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const _LiveLoudnessGroup(),
          const Spacer(),
          const _LoudnessReportButton(),
        ],
      ),
    );
  }
}

/// The live meters (ES-615): momentary and short-term loudness and the
/// true peak of the monitoring render, each shown as soon as it has a
/// value. The true peak is the highest since play or the last reset,
/// measured after the always-on −1 dBFS limiter, so it describes what
/// is heard, not the exported (unlimited) stream. Nothing here reaches
/// the IAMF file; the programme's figures are the Loudness Report's,
/// shown per layout in the Mix view.
class _LiveLoudnessGroup extends ConsumerWidget {
  const _LiveLoudnessGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final metrics = ref.watch(animatedMetricsProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Names the group: these are live monitoring meters, not the
        // programme's measurement, which the Loudness Report button at
        // the bar's other end leads to. Not const: the chip reads T.*
        // in build and a const instance would skip theme and font
        // changes, because its parent never rebuilds it.
        Tooltip(
          message:
              'Live meters of the monitoring render: what has played since '
              'the last stop, through the monitoring limiter. Not the '
              'programme measurement and not written to the IAMF file.',
          preferBelow: false,
          child: _LabelChip(label: 'LIVE', emphasized: true),
        ),
        const SizedBox(width: 12),
        _LoudnessValue(
          label: 'MOMENTARY',
          tooltip:
              'Momentary loudness of the monitoring render, 400 ms window. '
              'Live only; not written to the IAMF file.',
          value: metrics.lufsMomentary,
          unit: 'LUFS',
          valid: metrics.lufsMomentary > -119,
        ),
        const SizedBox(width: 16),
        _LoudnessValue(
          label: 'SHORT-TERM',
          tooltip:
              'Short-term loudness of the monitoring render, 3 s window. '
              'Live only; not written to the IAMF file.',
          value: metrics.lufsShortTerm,
          unit: 'LUFS',
          valid: metrics.lufsShortTerm > -119,
        ),
        const SizedBox(width: 16),
        _LoudnessValue(
          label: 'TRUE PEAK',
          tooltip:
              'Highest true peak of the monitoring render since play or the '
              'last reset, after the −1 dBFS limiter. Live only; the exported '
              'stream is not limited. Click to reset the live meters.',
          value: metrics.truePeak,
          unit: 'dBTP',
          valid: metrics.truePeak > -99,
          onTap: () =>
              ref.read(eclipsaStudioEngineProvider)?.meterResetLevels(),
        ),
      ],
    );
  }
}

/// The Loudness Report button at the bar's right end (ES-615). The bar
/// shows no programme figures: the report measures each tagged layout
/// separately and the Mix view's LAYOUTS bar carries those per layout.
/// Greyed in Playback, like the menu item: there is no offline measure
/// path for a loaded IAMF file (ES-520).
class _LoudnessReportButton extends ConsumerWidget {
  const _LoudnessReportButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final isCreator = ref.watch(workspaceModeProvider) == WorkspaceMode.creator;
    return Tooltip(
      message: isCreator
          ? 'Measure the programme offline, per layout. The report\'s '
                'figures are what the export writes into the IAMF file; the '
                'values here are live monitoring meters.'
          : 'The Loudness Report measures a session\'s sources; it is not '
                'available for a loaded IAMF file.',
      preferBelow: false,
      child: AppButton(
        label: 'Loudness Report',
        size: AppButtonSize.compact,
        onPressed: isCreator ? () => LoudnessReportDialog.show(context) : null,
      ),
    );
  }
}

/// The small label chip of a [_LoudnessValue]; [emphasized] for the
/// group's LIVE tag, which reads in the secondary text colour so it
/// stands out from the value labels without claiming a spec colour.
class _LabelChip extends StatelessWidget {
  final String label;
  final bool emphasized;
  const _LabelChip({required this.label, this.emphasized = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: emphasized ? T.bgSelected : T.bgControls,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: T.fontCaption,
          fontWeight: FontWeight.w700,
          color: emphasized ? T.textSecondary : T.textTertiary,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _LoudnessValue extends StatelessWidget {
  final String label;
  final String tooltip;
  final double value;
  final String unit;

  /// When false, display `---.-` regardless of [value].
  final bool valid;

  /// Optional click action (the live true peak resets on click).
  final VoidCallback? onTap;

  const _LoudnessValue({
    required this.label,
    required this.tooltip,
    required this.value,
    required this.unit,
    this.valid = true,
    this.onTap,
  });

  String get _valueStr =>
      valid ? AnimatedMetrics.formatLoudness(value) : '---.-';

  @override
  Widget build(BuildContext context) {
    final valueColor = valid ? T.textSecondary : T.textTertiary;
    Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _LabelChip(label: label),
        const SizedBox(width: T.gapXs),
        Text(
          _valueStr,
          style: TextStyle(
            fontFamily: T.monoFamily,
            fontSize: T.fontBodyL,
            fontWeight: FontWeight.w500,
            color: valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 3),
        Text(
          unit,
          style: TextStyle(fontSize: T.fontCaption, color: T.textTertiary),
        ),
      ],
    );
    if (onTap != null) {
      row = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: row),
      );
    }
    return Tooltip(message: tooltip, preferBelow: false, child: row);
  }
}
