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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state.dart';
import '../playback/iamf_probe.dart';
import '../playback/playback_session.dart';
import '../util/time_format.dart';
import '../workspace/workspace_mode.dart';
import 'chrome_surface.dart';
import 'console_widgets.dart';
import 'eclipsa_studio_lockup.dart';
import 'mix_presentation_label.dart';
import 'topbar_tab.dart';
import 'transport_clock.dart';
import 'transport_controls.dart';
import 'transport_scrub_bar.dart';

class Topbar extends ConsumerWidget {
  const Topbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final activeTab = ref.watch(activeTabProvider);
    final mode = ref.watch(workspaceModeProvider);

    return ChromeSurface(
      slice: ChromeSlice.topbar,
      child: Row(
        children: [
          const SizedBox(width: 20),
          // The same lockup as the landing screen, so the workspace
          // opens on the one the user arrived through. Both modes get
          // it: the mode only filters the tabs below.
          // onChrome: the bar is not a body surface, and chromeInk is
          // the ink gated against its ground.
          const EclipsaStudioLockup(onChrome: true),
          const SizedBox(width: 32),
          // Tabs, filtered per workspace mode.
          for (final id in WorkspaceTabs.allowedIn(mode))
            TopbarTab(
              label: WorkspaceTabs.title(id).toUpperCase(),
              active: activeTab == id,
              onTap: () => ref.read(activeTabProvider.notifier).set(id),
            ),
          // The mix cluster follows the tabs at the lockup-to-tabs gap.
          // Both modes carry a mix-presentation switcher here: Creator
          // binds the session's authored mixes, Playback the open IAMF
          // file's presentations.
          if (mode != WorkspaceMode.none) ...[
            const SizedBox(width: 32),
            const MixPresentationLabel(),
            const SizedBox(width: 8),
          ],
          if (mode == WorkspaceMode.creator) ...[
            const _MixSelector(),
          ] else if (mode == WorkspaceMode.playback) ...[
            const _PlaybackMixSelector(),
          ],
          // This Expanded takes the width between the left group,
          // anchored to the left edge, and the transport group, anchored
          // to the right edge. Neither group moves with the window
          // width, the active tab or the clock's text.
          Expanded(
            // A timeline scrubber beside the transport controls on every
            // tab of both modes (ES-35, ES-988), so the transport area is the
            // same on every tab. The Elements tab's track timeline seeks
            // through the same transportProvider, so the bar and the
            // timeline show and set one playhead position. The bar sits
            // against the transport controls, up to 400 px wide for scrub
            // precision, and narrows with the window.
            child: mode != WorkspaceMode.none
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: const TransportScrubBar(),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // Transport
          const TransportControls(),
          const SizedBox(width: 16),
          // Time display
          const _ClockDisplay(),
          const SizedBox(width: 20),
        ],
      ),
    );
  }
}

/// Digits the samples readout pads each value to: 10 digits hold
/// 9,999,999,999 samples, 57.9 hours at 48 kHz.
const int _kSampleDigits = 10;

/// The longest value the clock shows in each [TimeDisplayMode], which
/// the readout reserves room for: a single-digit hour in time mode, and
/// the padded sample count. A position or duration of ten hours or more
/// widens the clock by one digit per value.
String _clockWidestValue(TimeDisplayMode mode) => switch (mode) {
  TimeDisplayMode.mmss => formatDuration(9 * 3600 + 59 * 60 + 59.999),
  TimeDisplayMode.samples => '9' * _kSampleDigits,
};

/// [TransportClock] bound to the transport and the time-or-samples
/// toggle.
class _ClockDisplay extends ConsumerWidget {
  const _ClockDisplay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track theme AND font size: const-constructed upstream, so a
    // parent rebuild never reaches this widget (const-skip pattern) and
    // the font reads inside TransportClock would stay frozen on a
    // font-mode change.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final transport = ref.watch(transportProvider);
    final mode = ref.watch(timeDisplayProvider);

    final posText = mode == TimeDisplayMode.mmss
        ? formatDuration(transport.seconds)
        : '${transport.samplePosition}'.padLeft(_kSampleDigits);
    final durText = mode == TimeDisplayMode.mmss
        ? formatDuration(transport.durationSeconds)
        : '${transport.durationSamples}'.padLeft(_kSampleDigits);

    return TransportClock(
      position: posText,
      duration: durText,
      widest: _clockWidestValue(mode),
      tooltip: mode == TimeDisplayMode.mmss
          ? 'Click: show samples'
          : 'Click: show time',
      onTap: () => ref.read(timeDisplayProvider.notifier).toggle(),
    );
  }
}

/// The mix presentation switcher, shared by Creator and Playback: a
/// [ConsoleSelector] over the presentation [names] by index. It only
/// switches: presentations are created in the Mix view, and Playback's
/// Inspector tab keeps the full read-only mix detail. With no
/// presentations it shows "No mix presentations", disabled.
class _MixSwitcher extends ConsumerWidget {
  final List<String> names;

  /// Index of the active presentation in [names].
  final int active;

  final ValueChanged<int> onChanged;

  const _MixSwitcher({
    required this.names,
    required this.active,
    required this.onChanged,
  });

  /// The same in every theme: a component's size does not vary by
  /// theme, only how it is drawn and coloured.
  static const double _width = 180;

  static const String _semanticLabel = 'Mix presentation';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ConsoleSelector reads T.* without watching the theme, and the
    // hosts that build this widget are const in the top bar, so no
    // parent rebuild reaches it on a theme or font switch (const-skip
    // pattern).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    if (names.isEmpty) {
      return ConsoleSelector<int>(
        width: _width,
        enabled: false,
        value: -1,
        items: const [(-1, 'No mix presentations')],
        onChanged: (_) {},
        semanticLabel: _semanticLabel,
      );
    }
    return ConsoleSelector<int>(
      width: _width,
      value: active.clamp(0, names.length - 1),
      items: names.indexed.toList(),
      onChanged: onChanged,
      semanticLabel: _semanticLabel,
    );
  }
}

/// [_MixSwitcher] bound to the session's authored mixes.
class _MixSelector extends ConsumerWidget {
  const _MixSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mixes = ref.watch(mixesNotifierProvider);
    final activeMixIdx = ref.watch(activeMixProvider);
    return _MixSwitcher(
      names: [for (final m in mixes) m.name],
      active: activeMixIdx,
      onChanged: (v) {
        // Picking the active mix again changes nothing: resetting its
        // sub-mix would push the first sub-mix's settings and rebuild
        // the renderer mid-playback.
        if (v == ref.read(activeMixProvider)) return;
        ref.read(activeMixProvider.notifier).set(v);
        ref.read(activeSubMixProvider.notifier).set(0);
      },
    );
  }
}

/// Playback (QC) counterpart of [_MixSelector]: switches the active
/// mix presentation of the open IAMF file. Selection is applied live
/// without reopening the stream — `setActiveMix` re-asserts the
/// monitoring target, gates the AEs the presentation excludes, and
/// applies its element + sub-mix output gains (constant defaults; the
/// stream's per-TU gains stay authoritative only for the default
/// presentation, index 0). The Inspector tab keeps the full read-only
/// mix detail.
class _PlaybackMixSelector extends ConsumerWidget {
  const _PlaybackMixSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playbackSessionProvider);
    final mps =
        session?.report.mixPresentations ?? const <IamfMixPresentation>[];
    return _MixSwitcher(
      names: [
        for (var i = 0; i < mps.length; i++)
          (mps[i].name?.isNotEmpty ?? false)
              ? mps[i].name!
              : 'Mix Presentation ${i + 1}',
      ],
      active: session?.activeMixIndex ?? 0,
      onChanged: (v) =>
          ref.read(playbackSessionProvider.notifier).setActiveMix(v),
    );
  }
}
