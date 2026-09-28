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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../export/iamf_profile_rules.dart';
import '../loudness/loudness_measure_runner.dart';
import '../loudness/loudness_report_dialog.dart';
import '../loudness/programme_loudness.dart';
import '../meters/meter_provider.dart';
import '../meters/multichannel_meter_painter.dart';
import '../models/audio_element_enums.dart';
import '../state.dart';
import '../theme.dart';
import '../util/monitoring_tooltips.dart';
import '../widgets/ae_type_badge.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/console_widgets.dart';
import '../widgets/inline_edit_field.dart';
import '../widgets/remove_x_button.dart';
import '../widgets/solo_mute_button.dart';

/// Common languages for IAMF localized annotations.
const _languages = [
  'en',
  'en-US',
  'en-GB',
  'fr',
  'de',
  'es',
  'it',
  'ja',
  'ko',
  'zh',
  'pt',
  'ru',
  'ar',
  'hi',
  'nl',
  'sv',
  'da',
  'nb',
  'fi',
  'pl',
  'cs',
  'tr',
];

// ─────────────────────────────────────────────────────────────────────────────
// Mix View (top-level)
// ─────────────────────────────────────────────────────────────────────────────

class MixView extends ConsumerWidget {
  const MixView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final mixes = ref.watch(mixesNotifierProvider);
    final activeMixIdx = ref.watch(activeMixProvider);
    final activeSubIdx = ref.watch(activeSubMixProvider);
    final elements = ref.watch(elementsProvider);

    if (mixes.isEmpty) {
      return Container(
        color: T.bgBase,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No mix presentations',
                style: TextStyle(color: T.textGhost, fontSize: T.fontHeading),
              ),
              const SizedBox(height: 12),
              _addMixButton(ref),
            ],
          ),
        ),
      );
    }

    final mixIdx = activeMixIdx.clamp(0, mixes.length - 1);
    final mix = mixes[mixIdx];
    final subIdx = activeSubIdx.clamp(0, mix.subMixes.length - 1);
    final sub = mix.subMixes[subIdx];

    return Container(
      color: T.bgBase,
      child: Column(
        children: [
          _MixTabBar(mixes: mixes, activeMix: mixIdx),
          Container(height: 1, color: T.border),
          _HeaderBar(mix: mix),
          Container(height: 1, color: T.border),
          // Console area
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _ChannelStripArea(
                    mix: mix,
                    subMix: sub,
                    subMixIndex: subIdx,
                    elements: elements,
                  ),
                ),
                _MasterStrip(mix: mix, subMix: sub, subMixIndex: subIdx),
              ],
            ),
          ),
          Container(height: 1, color: T.border),
          _LayoutsBar(mix: mix, subMix: sub, subMixIndex: subIdx),
        ],
      ),
    );
  }

  static Widget _addMixButton(WidgetRef ref) {
    return GestureDetector(
      onTap: () {
        final idx = ref
            .read(mixesNotifierProvider.notifier)
            .createDefaultMix(ref.read(elementsProvider));
        ref.read(activeMixProvider.notifier).set(idx);
        ref.read(activeSubMixProvider.notifier).set(0);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: T.decoCard(),
        child: Text(
          '+ Add Mix Presentation',
          style: TextStyle(fontSize: T.fontHeading, color: T.textSecondary),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab Bar
// ─────────────────────────────────────────────────────────────────────────────

class _MixTabBar extends ConsumerWidget {
  final List<Mix> mixes;
  final int activeMix;

  const _MixTabBar({required this.mixes, required this.activeMix});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 36,
      color: T.bgSurface,
      child: Row(
        children: [
          const SizedBox(width: 16),
          ...mixes.asMap().entries.map(
            (e) => _buildTab(context, ref, e.key, e.value),
          ),
          GestureDetector(
            onTap: () {
              final idx = ref
                  .read(mixesNotifierProvider.notifier)
                  .createDefaultMix(ref.read(elementsProvider));
              ref.read(activeMixProvider.notifier).set(idx);
              ref.read(activeSubMixProvider.notifier).set(0);
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                '+',
                style: TextStyle(fontSize: T.fontTitle, color: T.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One mix-presentation tab: click selects, drag reorders (drop on
  /// another tab moves this one to that position), and the active tab
  /// carries an inline ✕ that deletes after confirmation (ES-180/ES-181).
  Widget _buildTab(BuildContext context, WidgetRef ref, int index, Mix mix) {
    final active = index == activeMix;
    // Never offer delete on the last remaining mix presentation.
    final canDelete = mixes.length > 1;

    // IntrinsicWidth keeps the tab sized to its label (clamped by the
    // constraints) while the Expanded text pushes the ✕ to the tab's
    // right edge; the fixed-height Row vertically centers both.
    final tabCore = IntrinsicWidth(
      child: Container(
        constraints: const BoxConstraints(minWidth: 100, maxWidth: 180),
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active ? T.bgSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                mix.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: T.fontBodyL,
                  color: active ? T.purpleLight : T.textTertiary,
                ),
              ),
            ),
            // ✕ on the active tab only — delete lives next to the thing
            // it deletes, without cluttering every tab (ES-180).
            if (active && canDelete) ...[
              const SizedBox(width: 4),
              RemoveXButton(
                // Full tab height for an easy target.
                height: 26,
                onTap: () => _confirmDeleteMix(context, ref, mix),
              ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      key: ValueKey(mix.id),
      // No vertical offset: the 36 px bar row centers the 26 px pill,
      // keeping it level with the layouts bar's chips below (ES-314).
      padding: const EdgeInsets.only(right: 6),
      child: Draggable<int>(
        data: index,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(opacity: 0.85, child: tabCore),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: tabCore),
        child: DragTarget<int>(
          onWillAcceptWithDetails: (d) => d.data != index,
          onAcceptWithDetails: (d) => _moveTab(ref, d.data, index),
          builder: (context, candidates, _) => Container(
            decoration: candidates.isNotEmpty
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(T.radiusSm),
                    border: Border.all(color: T.purple, width: 1),
                  )
                : null,
            child: GestureDetector(
              onTap: () {
                ref.read(activeMixProvider.notifier).set(index);
                ref.read(activeSubMixProvider.notifier).set(0);
              },
              // Grab cursor + tooltip: the app's standard cue for
              // drag-to-reorder (elements list, settings layouts).
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Tooltip(message: 'Drag to reorder', child: tabCore),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Reorder [from] → [to] and re-point [activeMixProvider] so the
  /// previously-active mix stays selected (selection follows the mix,
  /// not the slot). The sub-mix index is untouched — the active mix's
  /// sub-mixes are unaffected by tab order.
  void _moveTab(WidgetRef ref, int from, int to) {
    if (from == to) return;
    // Re-read at interaction time rather than trusting the widget's
    // captured fields (same discipline as _confirmDeleteMix).
    final mixes = ref.read(mixesNotifierProvider);
    final activeIdx = ref.read(activeMixProvider).clamp(0, mixes.length - 1);
    final activeId = mixes[activeIdx].id;
    ref.read(mixesNotifierProvider.notifier).reorderMix(from, to);
    final newIdx = ref
        .read(mixesNotifierProvider)
        .indexWhere((m) => m.id == activeId);
    if (newIdx >= 0) {
      ref.read(activeMixProvider.notifier).set(newIdx);
    }
  }
}

/// Confirm-and-delete for a mix presentation. On confirm, removes the
/// mix and re-points the active selection at the previous tab (sub-mix
/// index reset to 0). Shared logic formerly on the header bar's Delete
/// button; now reached from the tab ✕ (ES-180).
void _confirmDeleteMix(BuildContext context, WidgetRef ref, Mix mix) {
  showAppDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text('Delete Mix?', style: T.styleTitle),
      content: Text(
        'Delete "${mix.name}"?',
        style: TextStyle(color: T.textSecondary, fontSize: T.fontHeading),
      ),
      actions: [
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: () => Navigator.pop(ctx),
        ),
        AppButton(
          label: 'Delete',
          role: AppButtonRole.destructive,
          onPressed: () {
            Navigator.pop(ctx);
            final mixes = ref.read(mixesNotifierProvider);
            final i = mixes.indexWhere((m) => m.id == mix.id);
            ref.read(mixesNotifierProvider.notifier).removeMix(mix.id);
            ref.read(activeMixProvider.notifier).set(i > 0 ? i - 1 : 0);
            ref.read(activeSubMixProvider.notifier).set(0);
          },
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Header Bar — name, language
// ─────────────────────────────────────────────────────────────────────────────

class _HeaderBar extends ConsumerWidget {
  final Mix mix;
  const _HeaderBar({required this.mix});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 44,
      color: T.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Name
          Text('NAME  ', style: T.styleLabel),
          _InlineEdit(
            value: mix.name,
            width: 160,
            onChanged: (v) => ref
                .read(mixesNotifierProvider.notifier)
                .updateMix(mix.id, (m) => m.copyWith(name: v)),
          ),
          const SizedBox(width: 16),
          // Language
          Text('LANG  ', style: T.styleLabel),
          ConsoleSelector<String>(
            value: mix.language,
            items: _languages.map((l) => (l, l)).toList(),
            width: 70,
            onChanged: (v) => ref
                .read(mixesNotifierProvider.notifier)
                .updateMix(mix.id, (m) => m.copyWith(language: v)),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel Strip Area
// ─────────────────────────────────────────────────────────────────────────────

class _ChannelStripArea extends ConsumerWidget {
  final Mix mix;
  final SubMix subMix;
  final int subMixIndex;
  final List<AudioElement> elements;

  const _ChannelStripArea({
    required this.mix,
    required this.subMix,
    required this.subMixIndex,
    required this.elements,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final included = <AudioElement>[];
    final excluded = <AudioElement>[];
    for (final el in elements) {
      final s = subMix.settingsFor(el.id);
      if (s.included) {
        included.add(el);
      } else {
        excluded.add(el);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...included.map(
                (el) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: _ChannelStrip._stripWidth(el),
                    height: constraints.maxHeight - 16,
                    child: _ChannelStrip(
                      element: el,
                      settings: subMix.settingsFor(el.id),
                      mixId: mix.id,
                      subMixIndex: subMixIndex,
                    ),
                  ),
                ),
              ),
              if (excluded.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 80,
                    height: constraints.maxHeight - 16,
                    child: _AddElementStrip(
                      excluded: excluded,
                      mixId: mix.id,
                      subMixIndex: subMixIndex,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel Strip
// ─────────────────────────────────────────────────────────────────────────────

class _ChannelStrip extends ConsumerWidget {
  final AudioElement element;
  final MixElementSettings settings;
  final int mixId;
  final int subMixIndex;

  const _ChannelStrip({
    required this.element,
    required this.settings,
    required this.mixId,
    required this.subMixIndex,
  });

  void _update(WidgetRef ref, MixElementSettings s) {
    ref.read(mixesNotifierProvider.notifier).updateMix(mixId, (mix) {
      return mix.updateSubMix(subMixIndex, (sub) {
        final list = List<MixElementSettings>.from(sub.elementSettings);
        final i = list.indexWhere((x) => x.elementId == element.id);
        if (i >= 0) {
          list[i] = s;
        } else {
          list.add(s);
        }
        return sub.copyWith(elementSettings: list);
      });
    });

    // Push IAMF changes to OAR when they belong to the currently-active
    // mix. Changes to inactive mixes are Dart-state-only until they
    // become active (app_shell listens to activeMixProvider and bulk-
    // pushes on switch).
    final includedChanged = s.included != settings.included;
    final mixGainChanged = s.mixGain != settings.mixGain;
    final renderingChanged =
        s.headphonesMode != settings.headphonesMode ||
        s.binauralProfile != settings.binauralProfile;
    if (includedChanged || mixGainChanged || renderingChanged) {
      final activeMixIdx = ref.read(activeMixProvider);
      final mixes = ref.read(mixesNotifierProvider);
      final isActive =
          activeMixIdx >= 0 &&
          activeMixIdx < mixes.length &&
          mixes[activeMixIdx].id == mixId &&
          ref.read(activeSubMixProvider) == subMixIndex;
      if (isActive) {
        final engine = ref.read(eclipsaStudioEngineProvider);
        if (includedChanged) {
          engine?.setElementMixExcluded(element.id, !s.included);
        }
        if (mixGainChanged) {
          engine?.setElementMixGain(element.id, s.mixGain);
        }
        if (renderingChanged) {
          // Enum .index matches IAMF spec values (see BinauralProfile
          // and HeadphonesRenderingMode declarations). Channel-binaural
          // elements are coerced to mode 0 (stereo) — the canonical
          // authoring value for pre-rendered L/R content.
          engine?.updateElementRenderingConfig(
            element.id,
            s.effectiveHeadphonesMode(element).index,
            s.binauralProfile.index,
          );
        }
      }
    }
  }

  void _removeFromMix(WidgetRef ref) {
    _update(ref, settings.copyWith(included: false));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Color(element.color);
    final metrics = ref.watch(animatedMetricsProvider);
    final engineOrder = ref.watch(engineOrderProvider);
    final meterIdx = engineOrder.indexOf(element.id);
    final channelLevels =
        meterIdx >= 0 && meterIdx < metrics.sidebarMeters.length
        ? metrics.sidebarMeters[meterIdx]
        : <double>[];
    final channelPeaks =
        meterIdx >= 0 && meterIdx < metrics.sidebarPeakHolds.length
        ? metrics.sidebarPeakHolds[meterIdx]
        : null;
    final channelClips = meterIdx >= 0 && meterIdx < metrics.elementClips.length
        ? metrics.elementClips[meterIdx]
        : null;
    // Channel-based Binaural elements contain pre-rendered L/R content.
    // Lock the mode selector to Stereo (IAMF value 0) — the canonical
    // "already binaural" authoring value. OBR happens to treat every
    // mode as a direct L/R passthrough for these elements (obr_impl.cc:
    // kPassthroughStereo path), so the lock does not change what the
    // user hears — it keeps the bitstream value honest and the UI from
    // offering choices that do nothing. See
    // AudioElement.isChannelBasedBinaural and
    // MixElementSettings.effectiveHeadphonesMode.
    final lockToStereo = element.isChannelBasedBinaural;
    final effectiveMode = settings.effectiveHeadphonesMode(element);
    // Binaural filter profile is only consulted when OAR actually routes
    // this element through the binaural renderer. In stereo-downmix mode
    // the profile is meaningless, so the selector is dimmed and inert.
    final profileInactive = effectiveMode == HeadphonesRenderingMode.stereo;
    // IAMF-profile gating. Head-locked binaural (mode 2) and the
    // binaural_filter_profile field are v2.0.0 additions, absent from the
    // stable profiles. Head-locked is offered only when the profile allows
    // it OR it's already the stored value (so a loaded session still shows
    // it) — never as a new choice below Base-Advanced.
    final iamfProfile = ref.watch(iamfProfileProvider);
    final allowHeadLocked = profileAllowsHeadphonesMode(
      iamfProfile,
      HeadphonesRenderingMode.binauralHeadLocked,
    );
    final showHeadLocked =
        allowHeadLocked ||
        effectiveMode == HeadphonesRenderingMode.binauralHeadLocked;
    final allowBinauralFilter = profileAllowsBinauralFilterProfile(iamfProfile);
    final headLockedNote = allowHeadLocked
        ? ''
        : '\n\nHead-locked binaural requires the Base-Advanced profile '
              'or higher.';

    return Container(
      decoration: BoxDecoration(
        color: T.bgSurface,
        borderRadius: BorderRadius.circular(T.radiusMd),
        border: Border.all(color: T.borderLight),
      ),
      child: Column(
        children: [
          // ── Top: name + type + remove ──
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                    RemoveXButton(onTap: () => _removeFromMix(ref)),
                  ],
                ),
                const SizedBox(height: 4),
                AeTypeBadge(type: element.type, layout: element.layout),
              ],
            ),
          ),
          // ── Solo / Mute ──
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: _SoloMuteRow(element: element),
          ),

          Container(height: 1, color: T.border),

          // ── Middle: Meter + Fader ──
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: MultichannelMeter(
                      levels: channelLevels.isEmpty
                          ? List.filled(
                              math.max(1, _channelCount(element)),
                              0.0,
                            )
                          : channelLevels,
                      peaks: channelPeaks,
                      clipped: channelClips,
                      showLabels: false,
                      onClipClear: () =>
                          ref.read(clipClearEpochProvider.notifier).bump(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 28,
                    child: Tooltip(
                      message:
                          'Mix gain — written into IAMF metadata as\n'
                          "this element's gain inside the active mix.",
                      child: _VerticalFader(
                        value: settings.mixGain,
                        min: -60,
                        max: 12,
                        defaultValue: 0,
                        onChanged: (v) =>
                            _update(ref, settings.copyWith(mixGain: v)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Container(height: 1, color: T.border),

          // ── Bottom: gain value + headphones mode + binaural profile ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Column(
              children: [
                _EditableGainValue(
                  value: settings.mixGain,
                  onChanged: (v) => _update(ref, settings.copyWith(mixGain: v)),
                ),
                const SizedBox(height: 4),
                Tooltip(
                  message: lockToStereo
                      ? 'Locked to Stereo (IAMF mode 0). This is a\n'
                            'channel-based Binaural element (pre-rendered\n'
                            "L/R content). Mode 0 is the canonical\n"
                            '"already binaural" authoring value. OBR\n'
                            'treats every mode as a direct L/R passthrough\n'
                            'for these elements, so the choice has no\n'
                            'effect on playback. Mode 0 is the correct\n'
                            'value for the IAMF bitstream.'
                      : 'IAMF headphones_rendering_mode — how this element\n'
                            'is rendered when the playback layout is\n'
                            'binaural. Ignored for loudspeaker layouts.\n'
                            '\n'
                            '• Stereo — channel-based elements downmix\n'
                            '  to stereo; scene/object elements still\n'
                            '  binauralize (world-locked).\n'
                            '• Head-locked — binauralize; audio follows\n'
                            "  the listener's head rotation.\n"
                            '• World-locked — binauralize; audio stays\n'
                            '  fixed in space as the listener rotates.'
                            '$headLockedNote',
                  child: ConsoleSelector<HeadphonesRenderingMode>(
                    enabled: !lockToStereo,
                    // Display the effective (coerced) value so locked
                    // elements always show "Stereo" even if the stored
                    // MixElementSettings value is stale.
                    value: effectiveMode,
                    // Explicit UI order Stereo → Head-locked → World-locked.
                    // The enum is declared in IAMF spec order
                    // (stereo=0, binauralWorldLocked=1,
                    // binauralHeadLocked=2), so `.index` maps directly to
                    // the spec value for FFI. Head-locked is dropped below
                    // Base-Advanced (kept only if already stored).
                    items: [
                      (HeadphonesRenderingMode.stereo, 'Stereo'),
                      if (showHeadLocked)
                        (
                          HeadphonesRenderingMode.binauralHeadLocked,
                          'Head-locked',
                        ),
                      (
                        HeadphonesRenderingMode.binauralWorldLocked,
                        'World-locked',
                      ),
                    ],
                    onChanged: (v) =>
                        _update(ref, settings.copyWith(headphonesMode: v)),
                  ),
                ),
                const SizedBox(height: 4),
                // Binaural HRIR profile — only applies when the element is
                // spatialized. Dimmed and inert for the stereo-downmix mode,
                // which skips the binaural renderer entirely.
                Tooltip(
                  message: !allowBinauralFilter
                      ? 'IAMF binaural_filter_profile is a v2.0.0 field;\n'
                            'requires the Base-Advanced profile or higher.'
                      : profileInactive
                      ? 'IAMF binaural_filter_profile — HRIR family used\n'
                            'by the binaural renderer. No effect while\n'
                            'headphones mode is Stereo (this element is\n'
                            'downmixed instead of binauralized).'
                      : 'IAMF binaural_filter_profile — HRIR family used\n'
                            'by the binaural renderer.\n'
                            '\n'
                            '• Direct — dry, anechoic; most localized.\n'
                            '• Ambient — balanced room response (default).\n'
                            '• Reverberant — wet, larger perceived space.',
                  child: ConsoleSelector<BinauralProfile>(
                    enabled: !profileInactive && allowBinauralFilter,
                    value: settings.binauralProfile,
                    // Explicit UI order Direct → Ambient → Reverberant.
                    // The enum itself is declared in IAMF spec order
                    // (ambient/direct/reverberant) so `.index` maps
                    // directly to the spec value.
                    items: const [
                      (BinauralProfile.direct, 'Direct'),
                      (BinauralProfile.ambient, 'Ambient'),
                      (BinauralProfile.reverberant, 'Reverberant'),
                    ],
                    onChanged: (v) =>
                        _update(ref, settings.copyWith(binauralProfile: v)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compute strip width: minimum 120, grows for high channel counts so
  /// the dB scale and bars each get enough room.
  static double _stripWidth(AudioElement el) {
    final n = _channelCount(el);
    // 34 = meter internal overhead (_kPadH * 2 + _kDbScaleW)
    // 44 = strip layout overhead (padding 12 + fader 28 + gap 4)
    const overhead = 78.0;
    final barsW = n * 5.0 + (n - 1) * 2.0;
    return math.max(120.0, barsW + overhead);
  }

  static int _channelCount(AudioElement el) {
    final layout = el.layout.toLowerCase();
    if (layout.contains('mono') || layout.contains('object')) return 1;
    if (layout.contains('stereo') || layout.contains('binaural')) return 2;
    if (layout.contains('9.1.6')) return 16;
    if (layout.contains('7.1.5.4')) return 16;
    if (layout.contains('7.1.4')) return 12;
    if (layout.contains('7.1.2')) return 10;
    if (layout.contains('7.1')) return 8;
    if (layout.contains('5.1.4')) return 10;
    if (layout.contains('5.1.2')) return 8;
    if (layout.contains('5.1')) return 6;
    if (layout.contains('3.1.2')) return 6;
    if (layout.contains('4oa')) return 25;
    if (layout.contains('3oa')) return 16;
    if (layout.contains('2oa')) return 9;
    if (layout.contains('1oa')) return 4;
    return 2;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Element Strip
// ─────────────────────────────────────────────────────────────────────────────

class _AddElementStrip extends ConsumerWidget {
  final List<AudioElement> excluded;
  final int mixId;
  final int subMixIndex;

  const _AddElementStrip({
    required this.excluded,
    required this.mixId,
    required this.subMixIndex,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTapDown: (details) {
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        showMenu<int>(
          context: context,
          position: RelativeRect.fromLTRB(
            details.globalPosition.dx,
            details.globalPosition.dy,
            overlay.size.width - details.globalPosition.dx,
            overlay.size.height - details.globalPosition.dy,
          ),
          color: T.bgElevated,
          items: excluded
              .map(
                (el) => PopupMenuItem(
                  value: el.id,
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(el.color),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        el.name,
                        style: TextStyle(
                          fontSize: T.fontHeading,
                          color: T.textValue,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ).then((elementId) {
          if (elementId != null) {
            ref.read(mixesNotifierProvider.notifier).updateMix(mixId, (mix) {
              return mix.updateSubMix(subMixIndex, (sub) {
                final list = List<MixElementSettings>.from(sub.elementSettings);
                final i = list.indexWhere((s) => s.elementId == elementId);
                if (i >= 0) {
                  list[i] = list[i].copyWith(included: true);
                } else {
                  list.add(MixElementSettings(elementId: elementId));
                }
                return sub.copyWith(elementSettings: list);
              });
            });
            ref
                .read(eclipsaStudioEngineProvider)
                ?.setElementMixExcluded(elementId, false);
          }
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(T.radiusMd),
          border: Border.all(color: T.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '+',
                style: TextStyle(fontSize: T.fontTitle, color: T.textTertiary),
              ),
              const SizedBox(height: 4),
              Text(
                'Add\nElement',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: T.fontSmall, color: T.textGhost),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Master Strip
// ─────────────────────────────────────────────────────────────────────────────

class _MasterStrip extends ConsumerWidget {
  final Mix mix;
  final SubMix subMix;
  final int subMixIndex;
  const _MasterStrip({
    required this.mix,
    required this.subMix,
    required this.subMixIndex,
  });

  /// Push the new output mix gain into state, and when this mix
  /// presentation is the active one, forward it to OAR as IAMF group
  /// metadata.
  void _setOutputMixGain(WidgetRef ref, double v) {
    ref
        .read(mixesNotifierProvider.notifier)
        .updateMix(
          mix.id,
          (m) =>
              m.updateSubMix(subMixIndex, (s) => s.copyWith(outputMixGain: v)),
        );

    final activeMixIdx = ref.read(activeMixProvider);
    final mixes = ref.read(mixesNotifierProvider);
    final isActive =
        activeMixIdx >= 0 &&
        activeMixIdx < mixes.length &&
        mixes[activeMixIdx].id == mix.id &&
        ref.read(activeSubMixProvider) == subMixIndex;
    if (isActive) {
      ref.read(eclipsaStudioEngineProvider)?.setOutputMixGain(v);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(animatedMetricsProvider);
    final outputLevels = metrics.meters.length >= 2
        ? metrics.meters.sublist(0, 2)
        : List.filled(2, 0.0);
    final outputPeaks = metrics.meterPeakHolds.length >= 2
        ? metrics.meterPeakHolds.sublist(0, 2)
        : null;
    final outputClips = metrics.outputClips.length >= 2
        ? metrics.outputClips.sublist(0, 2)
        : null;

    return Container(
      width: 90,
      decoration: BoxDecoration(
        color: T.bgSurface,
        border: Border(left: BorderSide(color: T.border)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Text(
              'MASTER',
              style: TextStyle(
                fontSize: T.fontSmall,
                color: T.textMuted,
                letterSpacing: 0.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(height: 1, color: T.border),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: MultichannelMeter(
                      levels: outputLevels,
                      peaks: outputPeaks,
                      clipped: outputClips,
                      onClipClear: () =>
                          ref.read(clipClearEpochProvider.notifier).bump(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 28,
                    child: Tooltip(
                      message:
                          'Output mix gain — written into IAMF metadata\n'
                          'as the master gain for this mix presentation.',
                      child: _VerticalFader(
                        value: subMix.outputMixGain,
                        min: -60,
                        max: 12,
                        defaultValue: 0,
                        onChanged: (v) => _setOutputMixGain(ref, v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(height: 1, color: T.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _EditableGainValue(
              value: subMix.outputMixGain,
              onChanged: (v) => _setOutputMixGain(ref, v),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Vertical Fader
// ─────────────────────────────────────────────────────────────────────────────

class _VerticalFader extends ConsumerStatefulWidget {
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final ValueChanged<double> onChanged;

  const _VerticalFader({
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.onChanged,
  });

  @override
  ConsumerState<_VerticalFader> createState() => _VerticalFaderState();
}

class _VerticalFaderState extends ConsumerState<_VerticalFader> {
  bool _dragging = false;

  double _dbToFraction(double db) =>
      ((db - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);

  double _fractionToDb(double f) => (f * (widget.max - widget.min) + widget.min)
      .clamp(widget.min, widget.max);

  void _handleDrag(Offset localPos, double height) {
    const padTop = 8.0;
    const padBot = 8.0;
    final trackH = height - padTop - padBot;
    if (trackH <= 0) return;
    final frac = 1.0 - ((localPos.dy - padTop) / trackH).clamp(0.0, 1.0);
    final db = (_fractionToDb(frac) * 10).roundToDouble() / 10;
    widget.onChanged(db);
  }

  @override
  Widget build(BuildContext context) {
    // Watch theme + font mode so the painter's shouldRepaint sees them
    // change and redraws when the user flips themes.
    final themeMode = ref.watch(themeModeProvider);
    final fontMode = ref.watch(fontSizeModeProvider);
    return GestureDetector(
      onVerticalDragStart: (d) {
        _dragging = true;
        _handleDrag(d.localPosition, context.size?.height ?? 0);
      },
      onVerticalDragUpdate: (d) {
        if (_dragging) _handleDrag(d.localPosition, context.size?.height ?? 0);
      },
      onVerticalDragEnd: (_) => _dragging = false,
      onDoubleTap: () => widget.onChanged(widget.defaultValue),
      child: CustomPaint(
        painter: _VerticalFaderPainter(
          fraction: _dbToFraction(widget.value),
          zeroFraction: _dbToFraction(0),
          themeMode: themeMode,
          fontMode: fontMode,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _VerticalFaderPainter extends CustomPainter {
  final double fraction;
  final double zeroFraction;
  final AppThemeMode themeMode;
  final FontSizeMode fontMode;

  static const _dbMarks = [12, 6, 0, -6, -12, -24, -48];

  _VerticalFaderPainter({
    required this.fraction,
    required this.zeroFraction,
    required this.themeMode,
    required this.fontMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    const padTop = 8.0;
    const padBot = 8.0;
    const trackW = 4.0;
    final trackH = size.height - padTop - padBot;
    if (trackH <= 0) return;

    final trackX = (size.width - trackW) / 2;
    final trackTop = padTop;
    final trackBot = padTop + trackH;

    // Track background
    paint.color = T.bgDeep;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(trackX, trackTop, trackW, trackH),
        const Radius.circular(2),
      ),
      paint,
    );

    // dB tick marks
    paint
      ..color = T.border
      ..strokeWidth = 0.5;
    for (final db in _dbMarks) {
      final f = ((db - (-60)) / (12 - (-60))).clamp(0.0, 1.0);
      final y = trackBot - f * trackH;
      canvas.drawLine(
        Offset(trackX - 3, y),
        Offset(trackX + trackW + 3, y),
        paint,
      );
    }

    // 0 dB accent line
    final zeroY = trackBot - zeroFraction * trackH;
    paint
      ..color = T.textTertiary
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(trackX - 4, zeroY),
      Offset(trackX + trackW + 4, zeroY),
      paint,
    );

    // Fill below thumb
    final thumbY = trackBot - fraction * trackH;
    if (fraction > 0) {
      final fillRect = Rect.fromLTWH(trackX, thumbY, trackW, trackBot - thumbY);
      paint.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [T.purple.withValues(alpha: 0.4), T.purpleLight],
      ).createShader(fillRect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, const Radius.circular(2)),
        paint,
      );
      paint.shader = null;
    }

    // Thumb
    const thumbH = 10.0;
    const thumbW = 20.0;
    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width / 2, thumbY),
        width: thumbW,
        height: thumbH,
      ),
      const Radius.circular(3),
    );
    paint
      ..color = T.white
      ..style = PaintingStyle.fill;
    canvas.drawRRect(thumbRect, paint);

    // Thumb groove lines
    paint
      ..color = T.bgControls
      ..strokeWidth = 0.8;
    for (var i = -1; i <= 1; i++) {
      final ly = thumbY + i * 2.5;
      canvas.drawLine(
        Offset(size.width / 2 - 5, ly),
        Offset(size.width / 2 + 5, ly),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VerticalFaderPainter old) =>
      old.fraction != fraction ||
      old.zeroFraction != zeroFraction ||
      old.themeMode != themeMode ||
      old.fontMode != fontMode;
}

// ─────────────────────────────────────────────────────────────────────────────
// Editable Gain Value
// ─────────────────────────────────────────────────────────────────────────────

class _EditableGainValue extends ConsumerStatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _EditableGainValue({required this.value, required this.onChanged});

  @override
  ConsumerState<_EditableGainValue> createState() => _EditableGainValueState();
}

class _EditableGainValueState extends ConsumerState<_EditableGainValue> {
  bool _editing = false;

  void _startEdit() => setState(() => _editing = true);
  void _stopEdit() {
    if (_editing) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return SizedBox(
        height: 22,
        child: InlineEditField(
          initialValue: widget.value.toStringAsFixed(1),
          onCommit: (s) {
            final v = double.tryParse(s);
            if (v != null) widget.onChanged(v.clamp(-60, 12));
          },
          onExit: _stopEdit,
          normalize: (s) {
            final v = double.tryParse(s);
            if (v == null) return '';
            return v.clamp(-60, 12).toStringAsFixed(1);
          },
          validate: (s) => s.isNotEmpty,
          onValidationFail: (_) => ref
              .read(importNoticeProvider.notifier)
              .show('Invalid gain value'),
          textAlign: TextAlign.center,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
          ],
          style: T.styleValue,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 4,
            ),
            filled: true,
            fillColor: T.bgDeep,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.radiusSm),
              borderSide: BorderSide(color: T.purple),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.radiusSm),
              borderSide: BorderSide(color: T.purple),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: _startEdit,
      child: Container(
        height: 22,
        decoration: T.decoInset(),
        alignment: Alignment.center,
        child: Text(
          '${widget.value.toStringAsFixed(1)} dB',
          style: T.styleValue,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Layouts Bar
// ─────────────────────────────────────────────────────────────────────────────

/// One layout chip of the LAYOUTS bar, with a tooltip that says what
/// its figures are: the Loudness Report's measurement for this layout,
/// which the export writes into the IAMF file. [child] is the chip's
/// row (label, figures, remove button), built by the bar.
class _LayoutChip extends StatelessWidget {
  final String label;
  final ProgrammeLoudness? loudness;
  final bool measured;
  final Widget child;

  const _LayoutChip({
    required this.label,
    required this.loudness,
    required this.measured,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final l = loudness;
    final message = !measured
        ? '$label is tagged in this mix presentation. Its integrated '
              'loudness and true peak come from the Loudness Report and '
              'are written into the IAMF file on export; nothing has been '
              'measured yet.'
        : l == null
        ? 'The last Loudness Report has no figures for $label in this '
              'mix presentation. Measure again to get them.'
        : l.stale
        ? 'Integrated loudness and true peak for $label from the last '
              'Loudness Report. The session changed since, so they may no '
              'longer match; the export measures again before it writes.'
        : l.writtenToFile
        ? 'Integrated loudness and true peak for $label, measured '
              'offline by the Loudness Report. The export writes them '
              'into the IAMF file.'
        : 'Integrated loudness and true peak for $label, measured for '
              'monitoring only; the layout was not tagged when the '
              'report ran.';
    return Tooltip(
      message: message,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: T.purpleDim,
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: child,
      ),
    );
  }
}

/// A layout's integrated loudness and true peak on its chip: mono,
/// dimmed when stale, an em dash for a layout the last report did not
/// cover.
class _LayoutFigures extends StatelessWidget {
  final ProgrammeLoudness? loudness;
  final bool stale;
  const _LayoutFigures({required this.loudness, required this.stale});

  @override
  Widget build(BuildContext context) {
    final l = loudness;
    final color = stale ? T.textGhost : T.textValueDim;
    final style = TextStyle(
      fontFamily: T.monoFamily,
      fontSize: T.fontSmall,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (l == null) return Text('—', style: style);
    return Text(
      '${formatProgrammeScalar(l.integratedLufs, unit: 'LUFS')} · '
      '${formatProgrammeScalar(l.truePeakDbtp, unit: 'dBTP')}',
      style: style,
    );
  }
}

/// A line of text at the LAYOUTS bar's right end about the loudness
/// pass: its progress while it runs, or why the last one failed. Long
/// text is cut with an ellipsis; the tooltip carries it whole.
class _MeasureNote extends StatelessWidget {
  final String text;
  final String tooltip;
  final Color color;
  final VoidCallback? onTap;
  const _MeasureNote({
    required this.text,
    required this.tooltip,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: T.fontCaption, color: color),
          ),
        ),
      ),
    );
  }
}

class _LayoutsBar extends ConsumerWidget {
  final Mix mix;
  final SubMix subMix;
  final int subMixIndex;
  const _LayoutsBar({
    required this.mix,
    required this.subMix,
    required this.subMixIndex,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The Loudness Report measures each tagged layout separately (ES-615),
    // and this bar is the one place the Mix view lists them, so each
    // chip carries its own integrated loudness and true peak. Null
    // before the first report: the chips show no figures and the bar
    // offers Measure.
    final loudness = ref.watch(programmeLoudnessByLayoutProvider);
    final measure = ref.watch(loudnessMeasureProvider);
    // The runner's own precondition; the button is disabled rather
    // than posting 'Nothing to measure' on the bar.
    final canMeasure = ref.watch(
      elementsProvider.select((es) => es.any((e) => e.wavPath != null)),
    );
    return Container(
      height: 36,
      color: T.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            'LAYOUTS',
            style: TextStyle(
              fontSize: T.fontSmall,
              color: T.textMuted,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          // The chips scroll sideways once they outgrow the bar (six
          // tagged layouts with figures at the default window width),
          // so the buttons at the right end stay in reach.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...subMix.layouts.map(
                    // Fixed-height chip with a centered Row: label and ✕ are
                    // vertically centered as a unit, and every chip sits level
                    // with the mix tabs in the bar above (ES-314).
                    (l) => _LayoutChip(
                      label: l.soundSystem.uiLabel,
                      loudness: loudness?.byLayout[l.soundSystem],
                      measured: loudness != null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l.soundSystem.uiLabel,
                            style: TextStyle(
                              fontSize: T.fontBody,
                              color: T.purpleLight,
                            ),
                          ),
                          if (loudness != null) ...[
                            const SizedBox(width: T.gapSm),
                            _LayoutFigures(
                              loudness: loudness.byLayout[l.soundSystem],
                              stale: loudness.stale,
                            ),
                          ],
                          const SizedBox(width: T.gapPair),
                          // Stereo is mandatory (IAMF requires at least one
                          // stereo layout per mix presentation). Hide the
                          // delete button for stereo and when it's the last
                          // layout.
                          if (subMix.layouts.length > 1 &&
                              l.soundSystem != SoundSystem.stereo)
                            RemoveXButton(
                              // Box no taller than the chip label's line, so
                              // removable chips stay level with the mandatory
                              // stereo chip (which never shows a ✕). Tertiary
                              // over the purpleDim fill — ghost is grid-line
                              // faint there.
                              width: 16,
                              height: 12,
                              color: T.textTertiary,
                              onTap: () {
                                ref
                                    .read(mixesNotifierProvider.notifier)
                                    .updateMix(
                                      mix.id,
                                      (m) => m.updateSubMix(subMixIndex, (s) {
                                        final updated = s.layouts
                                            .where(
                                              (x) =>
                                                  x.soundSystem !=
                                                  l.soundSystem,
                                            )
                                            .toList();
                                        return s.copyWith(layouts: updated);
                                      }),
                                    );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Builder gives the "+" its own context so the menu anchors
                  // to the button's render box (the _TopbarSelector pattern)
                  // instead of the raw tap position with a vertical fudge.
                  Builder(
                    builder: (btnContext) => GestureDetector(
                      onTap: () => _showAddLayoutMenu(btnContext, ref),
                      child: Container(
                        height: 22,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(T.radiusSm),
                          border: Border.all(color: T.border),
                        ),
                        child: Text(
                          '+',
                          style: TextStyle(
                            fontSize: T.fontBody,
                            color: T.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Right end: the Loudness Report button, and to its left the
          // measure pass. While the pass runs, its progress. Otherwise a
          // Measure Loudness button before the first report and a
          // Re-measure Loudness button once the session has changed
          // since it; neither while the figures are current. The pass
          // runs in place, without opening the report. A failed pass
          // leaves its message here until the next pass or a click.
          if (measure.running) ...[
            _MeasureNote(
              text: measure.cancelRequested
                  ? 'Cancelling loudness measurement…'
                  : measure.total > 0
                  ? 'Measuring loudness (${measure.done}/${measure.total})…'
                  : 'Measuring loudness…',
              tooltip: measure.cancelRequested
                  ? 'The pass stops once the layouts it is rendering finish.'
                  : 'Monitoring is silent until the pass ends. Open the '
                        'Loudness Report to cancel.',
              color: T.textSecondary,
            ),
            const SizedBox(width: T.gapSm),
          ] else ...[
            if (measure.error case final error?) ...[
              _MeasureNote(
                text: error,
                tooltip: '$error\n\nClick to dismiss.',
                color: T.errorRed,
                onTap: ref.read(loudnessMeasureProvider.notifier).clearError,
              ),
              const SizedBox(width: T.gapSm),
            ],
            if (loudness == null || loudness.stale) ...[
              Tooltip(
                message: !canMeasure
                    ? 'Nothing to measure yet. Import an element with '
                          'audio first.'
                    : loudness == null
                    ? 'Measure the programme offline, per layout, without '
                          'opening the report. Each layout\'s integrated '
                          'loudness and true peak go on its chip and into '
                          'the IAMF file on export. Monitoring is silent '
                          'while the pass runs.'
                    : 'The session changed since these layouts were '
                          'measured, so the figures on the chips are out '
                          'of date. Measure again to refresh them. '
                          'Monitoring is silent while the pass runs.',
                child: AppButton(
                  label: loudness == null
                      ? 'Measure Loudness'
                      : 'Re-measure Loudness',
                  size: AppButtonSize.compact,
                  onPressed: canMeasure
                      ? ref.read(loudnessMeasureProvider.notifier).run
                      : null,
                ),
              ),
              const SizedBox(width: T.gapSm),
            ],
          ],
          Tooltip(
            message:
                'Measure the programme offline, per layout. The report\'s '
                'figures are what the export writes into the IAMF file.',
            child: AppButton(
              label: 'Loudness Report',
              size: AppButtonSize.compact,
              onPressed: () => LoudnessReportDialog.show(context),
            ),
          ),
        ],
      ),
    );
  }

  /// Add-layout popup, styled and anchored like the topbar mix
  /// presentation switcher (_TopbarSelector._showMenu in topbar.dart):
  /// 32 px fontBody items on an elevated fill with the rounded border
  /// outline, dropped below the "+" button's render box.
  void _showAddLayoutMenu(BuildContext context, WidgetRef ref) {
    final profile = ref.read(iamfProfileProvider);
    final used = subMix.layouts.map((l) => l.soundSystem).toSet();
    // All not-yet-used layouts. Expanded layouts the active profile
    // predates stay listed but disabled+greyed with a "needs <profile>"
    // explainer, rather than silently absent.
    final available = SoundSystem.values
        .where((s) => !used.contains(s))
        .toList();
    if (available.isEmpty) return;

    final button = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + button.size.height + 4,
      overlay.size.width - bottomRight.dx,
      overlay.size.height - bottomRight.dy,
    );

    showMenu<SoundSystem>(
      context: context,
      position: position,
      color: T.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.radiusSm),
        side: BorderSide(color: T.border),
      ),
      items: available.map((s) {
        final allowed = profileAllowsSoundSystem(profile, s);
        final min = minProfileForSoundSystem(s);
        // The layout name alone: the ITU notation beside it read as a
        // second name for the same layout.
        final label = Text(
          s.uiLabel,
          style: TextStyle(
            fontSize: T.fontBody,
            color: allowed ? T.textPrimary : T.textGhost,
          ),
        );
        if (allowed) {
          return PopupMenuItem(value: s, height: 32, child: label);
        }
        return PopupMenuItem<SoundSystem>(
          value: s,
          height: 32,
          enabled: false,
          child: Tooltip(
            message:
                '${s.uiLabel} requires the '
                '${min?.label} profile or higher '
                '(${min?.specVersion.label}).',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                label,
                const SizedBox(width: 8),
                Text(
                  'needs ${min?.label}',
                  style: TextStyle(fontSize: T.fontCaption, color: T.textGhost),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    ).then((sys) {
      if (sys != null) {
        ref
            .read(mixesNotifierProvider.notifier)
            .updateMix(
              mix.id,
              (m) => m.updateSubMix(
                subMixIndex,
                (s) => s.copyWith(
                  layouts: [
                    ...s.layouts,
                    MixLayout(soundSystem: sys),
                  ],
                ),
              ),
            );
      }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared inline widgets
// ─────────────────────────────────────────────────────────────────────────────

class _InlineEdit extends ConsumerStatefulWidget {
  final String value;
  final double width;
  final ValueChanged<String> onChanged;

  const _InlineEdit({
    required this.value,
    required this.width,
    required this.onChanged,
  });

  @override
  ConsumerState<_InlineEdit> createState() => _InlineEditState();
}

class _InlineEditState extends ConsumerState<_InlineEdit> {
  bool _editing = false;

  void _startEdit() => setState(() => _editing = true);
  void _stopEdit() {
    if (_editing) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: T.bgElevated,
      borderRadius: BorderRadius.circular(T.radiusSm),
      border: Border.all(color: _editing ? T.purple : T.borderLight),
    );
    final textStyle = TextStyle(fontSize: T.fontBodyL, color: T.textValue);

    return Container(
      width: widget.width,
      height: 26,
      decoration: decoration,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: _editing
          ? InlineEditField(
              initialValue: widget.value,
              onCommit: widget.onChanged,
              onExit: _stopEdit,
              normalize: (s) => s.trim(),
              validate: (s) => s.isNotEmpty,
              onValidationFail: (_) => ref
                  .read(importNoticeProvider.notifier)
                  .show('Name cannot be empty'),
              style: textStyle,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
              ),
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _startEdit,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.value,
                  style: textStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
    );
  }
}

/// Solo/Mute buttons for the mix view channel strip.
///
/// These are monitoring/preview controls — they help the user audition
/// the content but are NOT written into IAMF metadata. There is only one
/// set of speakers, so mute/solo is inherently global monitoring state
/// that's shared with the elements view. Tooltips make this explicit.
class _SoloMuteRow extends ConsumerWidget {
  final AudioElement element;
  const _SoloMuteRow({required this.element});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: SoloMuteButton(
            label: 'S',
            tooltip: kSoloTooltip,
            active: element.solo,
            activeColor: T.meterYellow,
            onTap: () => _toggle(ref, solo: !element.solo),
            expand: true,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SoloMuteButton(
            label: 'M',
            tooltip: kMuteTooltip,
            active: element.mute,
            activeColor: T.meterRed,
            onTap: () => _toggle(ref, mute: !element.mute),
            expand: true,
          ),
        ),
      ],
    );
  }

  void _toggle(WidgetRef ref, {bool? solo, bool? mute}) {
    final elems = ref.read(elementsProvider);
    final idx = elems.indexWhere((e) => e.id == element.id);
    if (idx < 0) return;
    final updated = elems[idx].copyWith(
      solo: solo ?? elems[idx].solo,
      mute: mute ?? elems[idx].mute,
    );
    final list = List<AudioElement>.from(elems)..[idx] = updated;
    ref.read(elementsProvider.notifier).set(list);

    // Propagate the change to the C++ engine. Elements view routes its
    // toggles through _updateElementById which handles this, but the
    // mix view uses a separate path — without this sync, clicking M/S
    // here would update the UI state but leave the audio graph unchanged.
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine != null) {
      if (solo != null) engine.setElementSolo(element.id, updated.solo);
      if (mute != null) engine.setElementMute(element.id, updated.mute);
    }
  }
}
