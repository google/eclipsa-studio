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

import '../export/iamf_profile_rules.dart';
import '../state.dart';
import 'console_widgets.dart';
import 'youtube_support_badge.dart';

/// IAMF profile picker that reflects how the *current session* fits each
/// profile (Phase 4 / gap G of ES-156). Profiles whose constraints the current
/// element pool / mixes violate are disabled and annotated with their
/// [profileConflicts] — a terse chip in the menu (e.g. "−2 AE · no 9.1.6")
/// plus the full explanation as a tooltip.
///
/// The currently-selected profile is always kept enabled even when it doesn't
/// fit, so a session authored under a higher profile (or loaded from disk) can
/// still be displayed and switched away from rather than trapping the user.
///
/// A drop-in replacement for the plain `ConsoleSelector<IamfProfile>`; reads
/// the pool/mixes itself so it works from any dialog (it's a [ConsumerWidget]).
class ProfileSelector extends ConsumerWidget {
  const ProfileSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.width,
    this.enabled = true,
  });

  final IamfProfile value;
  final ValueChanged<IamfProfile> onChanged;
  final double? width;

  /// Outer enable flag (e.g. disabled while an export is running). Independent
  /// of the per-profile fit gating below.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elements = ref.watch(elementsProvider);
    final mixes = ref.watch(mixesNotifierProvider);

    final conflicts = <IamfProfile, List<ProfileConflict>>{
      for (final p in IamfProfile.values)
        p: profileConflicts(elements: elements, mixes: mixes, profile: p),
    };

    // Keep the current selection enabled even if it doesn't fit — see class doc.
    bool itemEnabled(IamfProfile p) => p == value || conflicts[p]!.isEmpty;
    // Annotate only the *other* profiles. The current one is the escape hatch,
    // not a warning target — a grey conflict chip on the highlighted current
    // row reads as contradictory, and its conflicts (if any) already surface in
    // the Session Settings constraint panel / export validation panel.
    String note(IamfProfile p) =>
        p == value ? '' : conflicts[p]!.map((c) => c.shortLabel).join(' · ');
    String tip(IamfProfile p) =>
        p == value ? '' : conflicts[p]!.map((c) => c.message).join('\n');

    return ConsoleSelector<IamfProfile>(
      width: width,
      enabled: enabled,
      value: value,
      items: [for (final p in IamfProfile.values) (p, p.label)],
      onChanged: onChanged,
      itemEnabled: itemEnabled,
      itemNote: note,
      itemTooltip: tip,
      itemBadge: (p) =>
          p.supportedByYouTube ? const YouTubeSupportBadge() : null,
    );
  }
}
