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
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/log.dart';
import '../session/app_preferences.dart';
import '../state.dart';
import '../theme.dart';
import '../window_state.dart';
import 'app_button.dart';
import 'app_dialog.dart';

/// Revision of the safety behaviour this notice describes (ES-634). Bump
/// it by hand when the safety behaviour or the notice copy changes: a
/// user who suppressed an older revision sees the notice again on the
/// next launch. Gating on the app version instead would re-prompt on
/// every release, not only when the safety behaviour changes.
const int kSafetyNoticeRevision = 2;

// The copy below is safety-warning text; a change to it must bump
// [kSafetyNoticeRevision]. It keeps its own casing over the Title Case
// convention for dialog titles and buttons. The button acknowledges a
// warning, so it reads "I understand" rather than accepting terms.

const String kSafetyNoticeTitle = 'Listening safety';

const List<String> kSafetyNoticeBody = [
  'Before playback, turn the volume all the way down, then raise it '
      'slowly to a comfortable level. Take regular breaks, especially on '
      'headphones.',
  'Where possible, listen through an audio interface with a volume knob '
      'and a mute button.',
];

const String kSafetyNoticeCheckbox = "Don't show this again";
const String kSafetyNoticeAccept = 'I understand';
const String kSafetyNoticeQuit = 'Quit';

/// Whether the notice is due on this launch: it was never suppressed,
/// or was suppressed for an older [kSafetyNoticeRevision].
bool safetyNoticeDue(Map<String, dynamic> prefs) =>
    prefs[AppPreferences.kSafetyNoticeSuppressedRevision] !=
    kSafetyNoticeRevision;

/// The user's choice: [accepted] false is Quit; [suppress] is the
/// "Don't show this again" checkbox.
typedef SafetyNoticeChoice = ({bool accepted, bool suppress});

/// The launch safety warning (ES-634). Modal: it closes only through its
/// two buttons, never through Esc or a click outside, and the app is
/// not usable until it is accepted.
class SafetyNoticeDialog extends ConsumerStatefulWidget {
  const SafetyNoticeDialog({super.key});

  /// Shows the notice when it is due, records an acceptance, and quits
  /// on Quit. Returns once the app may proceed. Skipped under
  /// `--quit-after-load`, where nobody could press a button.
  ///
  /// Unlike the What's New dialog, which marks itself seen before it
  /// opens, the acceptance is written only when the user accepts;
  /// a record that says someone accepted who never saw the notice
  /// would be worse than showing it twice.
  static Future<void> maybeShow(BuildContext context, WidgetRef ref) async {
    if (ref.read(quitAfterLoadProvider)) return;
    final prefs = await AppPreferences.load();
    if (!safetyNoticeDue(prefs)) return;
    if (!context.mounted) return;
    await SchedulerBinding.instance.endOfFrame;
    if (!context.mounted) return;

    final choice = await showAppDialog<SafetyNoticeChoice>(
      context: context,
      escape: DialogEscape.none,
      builder: (_) => const SafetyNoticeDialog(),
    );
    if (choice == null) {
      // A programmatic pop, not a decision: nothing recorded, the
      // notice returns on the next launch.
      Log.w(LogCat.app, 'Safety notice closed without a choice');
      return;
    }
    if (!choice.accepted) {
      Log.i(LogCat.app, 'Safety notice: Quit');
      await requestWindowClose();
      return;
    }
    await _recordAcceptance(
      prefs,
      build: ref.read(appVersionProvider),
      suppress: choice.suppress,
    );
  }

  /// Writes the suppression choice, and on the first acceptance the
  /// local time and build, to the preferences file, the durable store
  /// (the JSONL log is truncated on every launch). Every acceptance is
  /// also logged at INFO as the in-session trace.
  static Future<void> _recordAcceptance(
    Map<String, dynamic> prefs, {
    required String build,
    required bool suppress,
  }) {
    final now = DateTime.now();
    final first = prefs[AppPreferences.kSafetyNoticeAcceptedAt] == null;
    Log.i(
      LogCat.app,
      'Safety notice accepted${first ? ' (first acceptance)' : ''}: '
      'revision $kSafetyNoticeRevision, build $build, at $now, '
      'suppressed=$suppress',
    );
    return AppPreferences.setAll({
      AppPreferences.kSafetyNoticeSuppressedRevision: suppress
          ? kSafetyNoticeRevision
          : null,
      if (first) ...{
        AppPreferences.kSafetyNoticeAcceptedAt: now.toIso8601String(),
        AppPreferences.kSafetyNoticeAcceptedBuild: build,
      },
    }).then(
      (_) {},
      onError: (Object e) =>
          Log.w(LogCat.app, 'Safety notice acceptance not saved', e),
    );
  }

  @override
  ConsumerState<SafetyNoticeDialog> createState() => _SafetyNoticeDialogState();
}

class _SafetyNoticeDialogState extends ConsumerState<SafetyNoticeDialog> {
  bool _suppress = false;

  void _close(bool accepted) =>
      Navigator.pop(context, (accepted: accepted, suppress: _suppress));

  @override
  Widget build(BuildContext context) {
    // Self-track theme + font size: the dialog sits in its own route,
    // so a parent rebuild never reaches it (the const-skip trap).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    return AlertDialog(
      backgroundColor: T.bgElevated,
      // Scrolls when the window is shorter than the three paragraphs,
      // so the buttons stay reachable on a small display.
      scrollable: true,
      title: Text(kSafetyNoticeTitle, style: T.styleTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < kSafetyNoticeBody.length; i++) ...[
              if (i > 0) const SizedBox(height: T.gapMd),
              Text(kSafetyNoticeBody[i], style: T.styleBodySecondary),
            ],
            const SizedBox(height: T.gapLg),
            _suppressRow(),
          ],
        ),
      ),
      actions: [
        AppButton(
          label: kSafetyNoticeQuit,
          role: AppButtonRole.quiet,
          onPressed: () => _close(false),
        ),
        // The default action: autofocus makes Enter accept.
        AppButton(
          label: kSafetyNoticeAccept,
          role: AppButtonRole.affirmative,
          autofocus: true,
          onPressed: () => _close(true),
        ),
      ],
    );
  }

  Widget _suppressRow() {
    return InkWell(
      onTap: () => setState(() => _suppress = !_suppress),
      borderRadius: BorderRadius.circular(T.radiusMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: _suppress,
                onChanged: (v) => setState(() => _suppress = v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                kSafetyNoticeCheckbox,
                style: TextStyle(fontSize: T.fontSmall, color: T.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
