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
import '../models/audio_element_enums.dart';
import '../state.dart';
import '../theme.dart';
import 'ae_type_badge.dart';
import 'app_button.dart';
import 'app_dialog.dart';

/// Outcome of [showElementFormatDialog].
class ElementFormatChoice {
  const ElementFormatChoice(
    this.config, {
    this.applyToRemaining = false,
    this.bumpTo,
  });

  /// The interpretation the user picked.
  final ElementConfig config;

  /// Whether the choice should also apply to the remaining files with the
  /// same channel count in the current batch (the "Apply to N more files"
  /// checkbox).
  final bool applyToRemaining;

  /// The profile the session must switch to for [config] — non-null only
  /// when the dialog ran with `allowProfileBump` and the user picked an
  /// interpretation the caller's profile does not permit. The caller is
  /// responsible for actually applying the switch.
  final IamfProfile? bumpTo;
}

/// Ask the user which element format an ambiguous WAV should open as (ES-152).
///
/// A channel count is ambiguous when [profileAllowedConfigsForChannelCount]
/// returns more than one config for it (e.g. 16 ch → Scene · 3OA or
/// Channel · 9.1.6). Instead of silently guessing, this dialog lists every
/// interpretation — recommended first, per [validConfigsForChannelCount]'s
/// ordering contract — with profile-gated options disabled and explained.
///
/// With [allowProfileBump] (the landing drop, where the file seeds a fresh
/// session), profile-gated options are selectable instead: each names the
/// profile it switches the session to, and the returned
/// [ElementFormatChoice.bumpTo] carries the target. The dialog is then also
/// shown when the only viable interpretation needs a bump, so it doubles as
/// the switch confirmation. In-session callers keep the default (false) —
/// changing the profile under existing elements is not this dialog's call.
///
/// Returns `null` when the user cancels. When at most one interpretation is
/// choosable and choosing it needs no bump, no dialog is shown: the single
/// config (or the plain default, if none is choosable — the import path
/// surfaces that error) is returned directly.
///
/// [remainingSameCount] > 0 shows the "Apply to N more X-channel files"
/// checkbox for batch drops; [confirmLabel] is "Import" for new elements and
/// "Replace" for the drop-onto-existing-element path.
Future<ElementFormatChoice?> showElementFormatDialog(
  BuildContext context, {
  required String fileName,
  required int channels,
  required IamfProfile profile,
  int? sampleRate,
  int remainingSameCount = 0,
  String confirmLabel = 'Import',
  bool allowProfileBump = false,
}) {
  final choosable = _choosableConfigs(profile, channels, allowProfileBump);
  if (choosable.isEmpty) {
    return Future.value(
      ElementFormatChoice(defaultConfigForChannelCount(channels)),
    );
  }
  if (choosable.length == 1 && profileAllowsConfig(profile, choosable.single)) {
    return Future.value(ElementFormatChoice(choosable.single));
  }
  return showAppDialog<ElementFormatChoice>(
    context: context,
    builder: (_) => _ElementFormatDialog(
      fileName: fileName,
      channels: channels,
      profile: profile,
      sampleRate: sampleRate,
      remainingSameCount: remainingSameCount,
      confirmLabel: confirmLabel,
      allowProfileBump: allowProfileBump,
    ),
  );
}

/// Whether [showElementFormatDialog] would present UI for a
/// [channels]-channel file under [profile]. Batch callers use this to
/// count upcoming dialogs (the "Apply to N more files" checkbox) before
/// showing any — keep it in lockstep with the early returns above.
bool elementFormatDialogWouldShow(
  IamfProfile profile,
  int channels, {
  bool allowProfileBump = false,
}) {
  final choosable = _choosableConfigs(profile, channels, allowProfileBump);
  if (choosable.isEmpty) return false;
  return choosable.length > 1 ||
      !profileAllowsConfig(profile, choosable.single);
}

/// The interpretations of [channels] the dialog would let the user pick:
/// those [profile] permits, plus — with [allowProfileBump] — those any
/// profile permits.
List<ElementConfig> _choosableConfigs(
  IamfProfile profile,
  int channels,
  bool allowProfileBump,
) => validConfigsForChannelCount(channels)
    .where(
      (c) =>
          profileAllowsConfig(profile, c) ||
          (allowProfileBump && minProfileForConfig(c) != null),
    )
    .toList();

/// One-line explanation of what an interpretation means, keyed by config
/// label. Sentence case; kept deliberately short — the label carries the
/// layout name, this carries the consequence of choosing it.
String _configDescription(ElementConfig c) {
  switch (c.label) {
    case 'Channel · Mono':
      return 'Single-channel bed';
    case 'Object · Mono':
      return 'Positionable mono object';
    case 'Channel · Stereo':
      return 'Standard stereo pair';
    case 'Channel · Binaural':
      return 'Pre-rendered binaural pair, bound to headphones';
    case 'Object · Dual':
      return 'Two independently positionable mono objects';
    case 'Channel · 5.1':
      return '5.1 surround bed';
    case 'Channel · 3.1.2':
      return 'Front-stage bed with a height pair';
    case 'Channel · 7.1':
      return '7.1 surround bed';
    case 'Channel · 5.1.2':
      return '5.1 bed plus a height pair';
    case 'Channel · 5.1.4':
      return '5.1 bed plus four heights';
    case 'Channel · 7.1.2':
      return '7.1 bed plus a height pair';
    case 'Scene · 3OA':
      return 'Third-order ambisonics soundfield';
    case 'Channel · 9.1.6':
      return 'Immersive bed with six heights';
    default:
      return '';
  }
}

class _ElementFormatDialog extends ConsumerStatefulWidget {
  const _ElementFormatDialog({
    required this.fileName,
    required this.channels,
    required this.profile,
    required this.sampleRate,
    required this.remainingSameCount,
    required this.confirmLabel,
    required this.allowProfileBump,
  });

  final String fileName;
  final int channels;
  final IamfProfile profile;
  final int? sampleRate;
  final int remainingSameCount;
  final String confirmLabel;
  final bool allowProfileBump;

  @override
  ConsumerState<_ElementFormatDialog> createState() =>
      _ElementFormatDialogState();
}

class _ElementFormatDialogState extends ConsumerState<_ElementFormatDialog> {
  late final List<ElementConfig> _configs;
  late int _selected;
  bool _applyToRemaining = false;

  @override
  void initState() {
    super.initState();
    _configs = validConfigsForChannelCount(widget.channels);
    // Preselect the first permitted config — index 0 is the recommended
    // default and is permitted under every profile today, but don't rely
    // on that staying true. A bump is never preselected while a
    // non-bumping option exists; with only bumping options (the
    // switch-confirmation case) the first of those is preselected.
    _selected = _configs.indexWhere(_allowed);
    if (_selected < 0) _selected = _configs.indexWhere(_choosable);
    if (_selected < 0) _selected = 0;
  }

  bool _allowed(ElementConfig c) => profileAllowsConfig(widget.profile, c);

  /// Non-null when picking [c] switches the session's profile: bumping
  /// is allowed and [c] is not permitted by the caller's profile.
  IamfProfile? _bumpTo(ElementConfig c) {
    if (!widget.allowProfileBump || _allowed(c)) return null;
    return minProfileForConfig(c);
  }

  bool _choosable(ElementConfig c) => _allowed(c) || _bumpTo(c) != null;

  String _subtitle() {
    final sr = widget.sampleRate;
    final srText = sr == null
        ? ''
        : ' · ${(sr / 1000).toStringAsFixed(sr % 1000 == 0 ? 0 : 1)} kHz';
    // With a single choosable option the dialog exists purely to
    // confirm the profile switch, not to disambiguate.
    final reason = _configs.where(_choosable).length > 1
        ? 'this channel count has more than one interpretation'
        : 'importing needs a higher IAMF profile';
    return '${widget.channels} channels$srText — $reason';
  }

  @override
  Widget build(BuildContext context) {
    // Self-track theme/font: shown via showDialog, so no parent rebuild
    // reaches it on a theme switch.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text('Choose Element Format', style: T.styleTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.fileName,
              style: T.styleBody,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              _subtitle(),
              style: TextStyle(color: T.textSecondary, fontSize: T.fontSmall),
            ),
            const SizedBox(height: T.gapSection),
            for (var i = 0; i < _configs.length; i++) _optionRow(i),
            // Unmissable restatement of the switch the selected option
            // implies — the row note alone is easy to skim past when the
            // bump option arrived preselected.
            if (_bumpTo(_configs[_selected]) case final IamfProfile bump) ...[
              const SizedBox(height: T.gapPair),
              Text(
                'Importing switches the session\'s IAMF profile from '
                '${widget.profile.label} to ${bump.label}.',
                style: TextStyle(fontSize: T.fontSmall, color: T.objAmber),
              ),
            ],
            if (widget.remainingSameCount > 0) ...[
              const SizedBox(height: T.gapPair),
              _applyToRemainingRow(),
            ],
          ],
        ),
      ),
      actions: [
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          label: widget.confirmLabel,
          role: AppButtonRole.affirmative,
          autofocus: true,
          onPressed: () => Navigator.pop(
            context,
            ElementFormatChoice(
              _configs[_selected],
              applyToRemaining: _applyToRemaining,
              bumpTo: _bumpTo(_configs[_selected]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _optionRow(int i) {
    final cfg = _configs[i];
    final bump = _bumpTo(cfg);
    final enabled = _choosable(cfg);
    final selected = i == _selected;
    final typeColor = aeTypeColor(cfg.type);
    // Index 0 is the recommended default per validConfigsForChannelCount's
    // ordering contract.
    final recommended = i == 0;
    final description = _allowed(cfg)
        ? _configDescription(cfg)
        : bump != null
        ? 'Switches the session to the ${bump.label} profile'
        : 'Needs the ${minProfileForConfig(cfg)?.label ?? '—'} profile';

    return Padding(
      padding: const EdgeInsets.only(bottom: T.gapPair),
      child: InkWell(
        onTap: enabled ? () => setState(() => _selected = i) : null,
        borderRadius: BorderRadius.circular(T.radiusMd),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? T.purple.withValues(alpha: 0.10) : T.bgBase,
            borderRadius: BorderRadius.circular(T.radiusMd),
            border: Border.all(color: selected ? T.purpleLight : T.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
                color: selected
                    ? T.purpleLight
                    : enabled
                    ? T.textTertiary
                    : T.textGhost,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          aeTypeIcon(cfg.type),
                          size: 12,
                          color: enabled
                              ? typeColor
                              : typeColor.withValues(alpha: 0.4),
                        ),
                        const SizedBox(width: T.gapPair),
                        Flexible(
                          child: Text(
                            cfg.label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: T.fontBody,
                              fontWeight: FontWeight.w600,
                              color: enabled ? T.textPrimary : T.textMuted,
                            ),
                          ),
                        ),
                        if (recommended) ...[
                          const SizedBox(width: 8),
                          _mostCommonTag(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: T.fontSmall,
                        color: !enabled
                            ? T.textMuted
                            : bump != null
                            ? T.objAmber
                            : T.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact pill marking the recommended interpretation, based on the
  /// [AeTypeBadge] / [YouTubeSupportBadge] pill style.
  Widget _mostCommonTag() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: T.purple.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(T.radiusSm),
      ),
      child: Text(
        'Most common',
        style: TextStyle(
          fontSize: T.fontCaption,
          color: T.purpleLight,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _applyToRemainingRow() {
    final n = widget.remainingSameCount;
    final label =
        'Apply to $n more ${widget.channels}-channel '
        'file${n == 1 ? '' : 's'} in this drop';
    return InkWell(
      onTap: () => setState(() => _applyToRemaining = !_applyToRemaining),
      borderRadius: BorderRadius.circular(T.radiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: _applyToRemaining,
                onChanged: (v) =>
                    setState(() => _applyToRemaining = v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: T.fontSmall, color: T.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
