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
import 'eclipsa_studio_lockup.dart';
import 'topbar_selector.dart';
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
              label: _tabLabel(id),
              active: activeTab == id,
              onTap: () => ref.read(activeTabProvider.notifier).set(id),
            ),
          // Two Spacers flanking the mix cluster centre it in the
          // space between the tab row and the transport controls. Both
          // modes carry a mix-presentation switcher here: Creator binds
          // the session's authored mixes, Playback the open IAMF file's
          // presentations. The scrubber below deliberately
          // lives outside the centre slot.
          const Spacer(),
          if (mode != WorkspaceMode.none) ...[
            const MixPresentationLabel(),
            const SizedBox(width: 8),
          ],
          if (mode == WorkspaceMode.creator) ...[
            const _MixSelector(),
          ] else if (mode == WorkspaceMode.playback) ...[
            const _PlaybackMixSelector(),
          ],
          const Spacer(),
          // A timeline scrubber beside the transport controls wherever
          // the active tab has none of its own: every Playback (QC) tab
          // (ES-35), and the Creator tabs other than Elements, whose track
          // timeline already seeks (ES-783). Flexible (with twice the
          // spacers' share) so it stays wide for scrub precision yet
          // shrinks on narrow windows.
          if (showsScrubBar(mode, activeTab)) ...[
            Flexible(
              flex: 2,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: const TransportScrubBar(),
              ),
            ),
            const SizedBox(width: 16),
          ],
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

/// Whether the topbar carries the [TransportScrubBar] for [mode] and
/// the active [tab]: every Playback tab, and every Creator tab except
/// Elements, which has the track timeline.
bool showsScrubBar(WorkspaceMode mode, String tab) => switch (mode) {
  WorkspaceMode.playback => true,
  WorkspaceMode.creator => tab != WorkspaceTabs.elements,
  WorkspaceMode.none => false,
};

String _tabLabel(String id) => switch (id) {
  WorkspaceTabs.elements => 'ELEMENTS',
  WorkspaceTabs.mix => 'MIX',
  WorkspaceTabs.renderer => 'RENDERER',
  WorkspaceTabs.inspector => 'INSPECTOR',
  _ => id.toUpperCase(),
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
        : '${transport.samplePosition}'.padLeft(10);
    final durText = mode == TimeDisplayMode.mmss
        ? formatDuration(transport.durationSeconds)
        : '${transport.durationSamples}'.padLeft(10);

    return TransportClock(
      position: posText,
      duration: durText,
      tooltip: mode == TimeDisplayMode.mmss
          ? 'Click: show samples'
          : 'Click: show time',
      onTap: () => ref.read(timeDisplayProvider.notifier).toggle(),
    );
  }
}

class _MixSelector extends ConsumerWidget {
  const _MixSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mixes = ref.watch(mixesNotifierProvider);
    final activeMixIdx = ref.watch(activeMixProvider);
    return TopbarSelector(
      items: [for (final m in mixes) m.name],
      activeIndex: mixes.isEmpty ? -1 : activeMixIdx,
      // Creation lives in the Mix view, hence the inert ghost here.
      emptyLabel: 'No mix presentations',
      onSelect: (v) {
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
    return TopbarSelector(
      items: [
        for (var i = 0; i < mps.length; i++)
          (mps[i].name?.isNotEmpty ?? false)
              ? mps[i].name!
              : 'Mix Presentation ${i + 1}',
      ],
      activeIndex: session?.activeMixIndex ?? -1,
      emptyLabel: 'No mix presentations',
      onSelect: (v) =>
          ref.read(playbackSessionProvider.notifier).setActiveMix(v),
    );
  }
}
