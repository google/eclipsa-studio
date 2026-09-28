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
import '../theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/dialog_shell.dart';
import 'release_notes.dart';

/// "What's New" dialog. Shown automatically on first launch after an
/// upgrade and on demand from the Help menu.
class WhatsNewDialog extends ConsumerWidget {
  /// Releases to render, newest first. Caller picks the slice:
  /// `releasesSince(notes, lastSeen)` for the post-upgrade trigger,
  /// or the full list (via [showAll]) for the manual menu / landing
  /// triggers. Either path may render multiple releases stacked.
  final List<ReleaseNotes> releases;

  const WhatsNewDialog({super.key, required this.releases});

  static Future<void> show(
    BuildContext context, {
    required List<ReleaseNotes> releases,
  }) {
    return showAppDialog<void>(
      context: context,
      id: WhatsNewDialog,
      builder: (ctx) => WhatsNewDialog(releases: releases),
    );
  }

  /// Convenience: load every release from the bundled JSON and show
  /// the dialog. Used by the landing-screen "What's New" button and
  /// the Eclipsa Studio / Help menu items, both of which want the
  /// full history.
  static Future<void> showAll(BuildContext context) async {
    final notes = await loadReleaseNotes();
    if (!context.mounted) return;
    await show(context, releases: notes);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Track theme + font-size modes so the const-skip pattern doesn't
    // freeze us on stale T.* values across mode switches.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    return DialogShell(
      title: 'Release Notes',
      width: 560,
      maxHeight: 640,
      bodyFit: DialogBodyFit.flexible,
      footerDivider: true,
      actions: [DialogShell.done(context)],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < releases.length; i++) ...[
              _ReleaseSection(release: releases[i]),
              if (i < releases.length - 1)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(height: 1),
                ),
            ],
            // Not const: _NoNotes reads T.* — a const instance would be
            // canonicalized and skip rebuilds on theme/font switches.
            if (releases.isEmpty) _NoNotes(),
          ],
        ),
      ),
    );
  }
}

class _ReleaseSection extends StatelessWidget {
  final ReleaseNotes release;

  const _ReleaseSection({required this.release});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              release.version,
              style: TextStyle(
                color: T.textPrimary,
                fontSize: T.fontHeading,
                fontWeight: FontWeight.w700,
                fontFamily: T.monoFamily,
              ),
            ),
            const SizedBox(width: T.gapSm),
            Text(
              release.dateDisplay,
              style: TextStyle(color: T.textTertiary, fontSize: T.fontSmall),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (release.summary != null && release.isMaintenance)
          Text(
            release.summary!,
            style: TextStyle(
              color: T.textSecondary,
              fontSize: T.fontBody,
              height: 1.45,
            ),
          )
        else
          for (final n in release.notes) _Bullet(text: n),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;

  const _Bullet({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7, right: 10),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: T.purpleLight,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              _parseInline(text),
              style: TextStyle(
                color: T.textPrimary,
                fontSize: T.fontBody,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Parse `**bold**` segments in the bullet text and emit a TextSpan
/// tree. Asterisks themselves are stripped. Anything that isn't
/// `**…**` is rendered as plain text in the parent style.
TextSpan _parseInline(String text) {
  final spans = <TextSpan>[];
  var i = 0;
  while (i < text.length) {
    final start = text.indexOf('**', i);
    if (start < 0) {
      spans.add(TextSpan(text: text.substring(i)));
      break;
    }
    if (start > i) {
      spans.add(TextSpan(text: text.substring(i, start)));
    }
    final end = text.indexOf('**', start + 2);
    if (end < 0) {
      // Unterminated — keep the rest as plain text including the
      // asterisks so we don't silently drop content.
      spans.add(TextSpan(text: text.substring(start)));
      break;
    }
    spans.add(
      TextSpan(
        text: text.substring(start + 2, end),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
    i = end + 2;
  }
  return TextSpan(children: spans);
}

class _NoNotes extends StatelessWidget {
  const _NoNotes();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        'No release notes are available for this build.',
        style: TextStyle(color: T.textTertiary, fontSize: T.fontBody),
      ),
    );
  }
}
