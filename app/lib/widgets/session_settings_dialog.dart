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

import '../export/iamf_profile_rules.dart'
    show ProfileConflictKind, audioElementChannelCount, profileConflicts;
import '../state.dart';
import '../theme.dart';
import 'app_dialog.dart';
import 'dialog_shell.dart';
import 'profile_selector.dart';

/// Per-session IAMF settings. Kept separate from [SettingsDialog]
/// (which covers app-level preferences like theme, audio device, and
/// monitoring) because these values belong to the session file (.esp)
/// rather than the app's preferences.json.
class SessionSettingsDialog extends ConsumerWidget {
  const SessionSettingsDialog({super.key});

  static void show(BuildContext context) {
    showAppDialog<void>(
      context: context,
      id: SessionSettingsDialog,
      builder: (_) => const SessionSettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track theme + font size: the dialog sits in its own route,
    // so nothing above it rebuilds while it's open — without these
    // watches a theme or font switch would leave it stale until
    // reopened (matches settings_dialog.dart).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final profile = ref.watch(iamfProfileProvider);
    final elements = ref.watch(elementsProvider);
    final mixes = ref.watch(mixesNotifierProvider);

    // Model-derived (not wavInfo) so the readout matches the profile selector
    // and profileConflicts even when an element's WAV is missing/undecoded.
    final totalChannels = elements.fold<int>(
      0,
      (sum, e) => sum + audioElementChannelCount(e),
    );
    final objectCount = elements.where((e) => e.type == 'Object').length;
    final hasObjectElements = objectCount > 0;
    final hasChannelElements = elements.any((e) => e.type == 'Channel');
    final hasSceneElements = elements.any((e) => e.type == 'Scene');
    final typeCount = [
      hasObjectElements,
      hasChannelElements,
      hasSceneElements,
    ].where((b) => b).length;
    final hasMixedTypes = typeCount > 1;

    final elemOverflow = elements.length - profile.maxAudioElements;
    final chanOverflow = totalChannels - profile.maxChannels;
    final objectViolation = hasObjectElements && !profile.allowObjectBased;
    final mixedViolation = hasMixedTypes && !profile.allowMixedTypes;
    // The object mix presentation rules depend on which elements each mix
    // includes, so they come from profileConflicts rather than the counts.
    final objectMixKinds = profile.requiresObjectOnlyMixes
        ? profileConflicts(elements: elements, mixes: mixes, profile: profile)
              .map((c) => c.kind)
              .where(
                (k) =>
                    k == ProfileConflictKind.objectMixedWithOtherTypes ||
                    k == ProfileConflictKind.firstMixNotObjectOnly,
              )
              .toSet()
        : const <ProfileConflictKind>{};
    final hasViolations =
        elemOverflow > 0 ||
        chanOverflow > 0 ||
        objectViolation ||
        mixedViolation ||
        objectMixKinds.isNotEmpty;

    return DialogShell(
      title: 'Session Settings',
      subtitle: 'These values live in the current session (.esp) file.',
      width: 560,
      actions: [DialogShell.done(context)],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Not const: _SessionSectionHeader reads T.* and must
          // refresh with the dialog's rebuild on theme/font change.
          _SessionSectionHeader(label: 'IAMF'),
          const SizedBox(height: 12),
          _SessionRow(
            label: 'IAMF profile',
            description:
                'Determines which IAMF bitstream profile the '
                'exporter targets. Restrictive profiles cap element '
                'and channel counts and restrict which element '
                'types are permitted.',
            control: ProfileSelector(
              width: 180,
              value: profile,
              onChanged: (p) => ref.read(iamfProfileProvider.notifier).set(p),
            ),
          ),
          const SizedBox(height: 16),
          _ProfileConstraintPanel(
            profile: profile,
            elementCount: elements.length,
            totalChannels: totalChannels,
            objectCount: objectCount,
            typeCount: typeCount,
            elemOverflow: elemOverflow,
            chanOverflow: chanOverflow,
            objectViolation: objectViolation,
            mixedViolation: mixedViolation,
            hasMixedTypes: hasMixedTypes,
            objectMixKinds: objectMixKinds,
            hasViolations: hasViolations,
          ),
        ],
      ),
    );
  }
}

// ── Internal layout helpers ───────────────────────────────────────────
// Intentionally duplicated from settings_dialog.dart rather than extracted
// — the shared-widget refactor is out of scope for the settings split.

class _SessionSectionHeader extends StatelessWidget {
  final String label;
  const _SessionSectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: T.fontBodyL,
        color: T.textMuted,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final String label;
  final String description;
  final Widget control;

  const _SessionRow({
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

class _ProfileConstraintPanel extends StatelessWidget {
  final IamfProfile profile;
  final int elementCount;
  final int totalChannels;
  final int objectCount;
  final int typeCount;
  final int elemOverflow;
  final int chanOverflow;
  final bool objectViolation;
  final bool mixedViolation;
  final bool hasMixedTypes;

  /// The object mix presentation conflicts the session has under
  /// [profile]; empty when it has none or the profile has no such rule.
  final Set<ProfileConflictKind> objectMixKinds;
  final bool hasViolations;

  const _ProfileConstraintPanel({
    required this.profile,
    required this.elementCount,
    required this.totalChannels,
    required this.objectCount,
    required this.typeCount,
    required this.elemOverflow,
    required this.chanOverflow,
    required this.objectViolation,
    required this.mixedViolation,
    required this.hasMixedTypes,
    required this.objectMixKinds,
    required this.hasViolations,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: hasViolations
              ? T.meterYellow.withValues(alpha: 0.40)
              : T.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${profile.label} profile constraints',
            style: TextStyle(
              color: T.textSecondary,
              fontSize: T.fontBody,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          _ConstraintRow(
            label: 'Audio elements',
            limit: '${profile.maxAudioElements}',
            current: '$elementCount',
            violation: elemOverflow > 0,
            hint: elemOverflow > 0
                ? 'Remove $elemOverflow element'
                      '${elemOverflow > 1 ? 's' : ''}'
                : null,
          ),
          const SizedBox(height: 4),
          _ConstraintRow(
            label: 'Total channels',
            limit: '${profile.maxChannels}',
            current: '$totalChannels',
            violation: chanOverflow > 0,
            hint: chanOverflow > 0
                ? 'Reduce by $chanOverflow channel'
                      '${chanOverflow > 1 ? 's' : ''}'
                : null,
          ),
          const SizedBox(height: 4),
          _ConstraintRow(
            label: 'Object-based',
            limit: profile.allowObjectBased ? 'Allowed' : 'Not allowed',
            current: objectCount > 0 ? '$objectCount present' : 'None',
            violation: objectViolation,
            hint: objectViolation ? 'Remove object-based elements' : null,
          ),
          const SizedBox(height: 4),
          _ConstraintRow(
            label: 'Mixed types',
            limit: profile.allowMixedTypes ? 'Allowed' : 'Not allowed',
            current: hasMixedTypes ? '$typeCount types present' : 'No',
            violation: mixedViolation,
            hint: mixedViolation ? 'Use a single element type' : null,
          ),
          if (profile.requiresObjectOnlyMixes) ...[
            const SizedBox(height: 4),
            _ConstraintRow(
              label: 'Object mixes',
              limit: 'Object-only, first',
              current: objectMixKinds.isNotEmpty
                  ? 'Not met'
                  : objectCount > 0
                  ? 'Met'
                  : 'No objects',
              violation: objectMixKinds.isNotEmpty,
              hint:
                  objectMixKinds.contains(
                    ProfileConflictKind.objectMixedWithOtherTypes,
                  )
                  ? 'Give object-based elements their own mix presentation'
                  : objectMixKinds.isNotEmpty
                  ? 'Move an object-only mix presentation first'
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _ConstraintRow extends StatelessWidget {
  final String label;
  final String limit;
  final String current;
  final bool violation;
  final String? hint;

  const _ConstraintRow({
    required this.label,
    required this.limit,
    required this.current,
    this.violation = false,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final warnColor = T.meterYellow;
    // The value and its hint take the rest of the row and wrap: the
    // Object mixes hints are wider than the 560 px dialog leaves them.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text(label, style: T.styleBodySecondary)),
        SizedBox(width: 90, child: Text(limit, style: T.styleBody)),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: current,
                  style: TextStyle(
                    color: violation ? warnColor : T.textTertiary,
                  ),
                ),
                if (violation && hint != null)
                  TextSpan(
                    text: '  \u2014 $hint',
                    style: TextStyle(color: warnColor),
                  ),
              ],
            ),
            style: TextStyle(fontSize: T.fontBody),
          ),
        ),
      ],
    );
  }
}
