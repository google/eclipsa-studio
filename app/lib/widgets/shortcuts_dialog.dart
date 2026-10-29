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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import '../workspace/workspace_mode.dart';
import 'app_dialog.dart';
import 'dialog_shell.dart';
import 'eyebrow_label.dart';

final bool _isMac = Platform.isMacOS;

/// Platform-aware key sequences: glyph caps on macOS, word caps elsewhere.
List<String> _mod(String key) => _isMac ? ['⌘', key] : ['Ctrl', key];
List<String> _shiftMod(String key) =>
    _isMac ? ['⇧', '⌘', key] : ['Shift', 'Ctrl', key];

/// Shows a dialog listing all keyboard shortcuts.
class ShortcutsDialog extends ConsumerWidget {
  const ShortcutsDialog({super.key});

  static void show(BuildContext context) {
    showAppDialog<void>(
      context: context,
      id: ShortcutsDialog,
      builder: (ctx) => const ShortcutsDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track theme + font size so an open dialog restyles live
    // (its route has no rebuilding parent — the const-skip pattern).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    // The tab rows list the open workspace's tabs; the landing screen
    // has none.
    final tabs = WorkspaceTabs.allowedIn(ref.watch(workspaceModeProvider));

    return DialogShell(
      title: 'Keyboard Shortcuts',
      width: 420,
      actions: [DialogShell.done(context)],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Section(
            label: 'File',
            shortcuts: [
              _Shortcut('New session', [_mod('N')]),
              _Shortcut('Open session', [_mod('O')]),
              _Shortcut('Save', [_mod('S')]),
              _Shortcut('Save as', [_shiftMod('S')]),
              _Shortcut('Close session / file', [_mod('W')]),
              _Shortcut('Settings', [_mod(',')]),
              _Shortcut('Session settings', [_shiftMod(',')]),
            ],
          ),
          const SizedBox(height: T.gapSection),
          // Not const: _Section rows read T.* — a const instance would
          // be canonicalized and skip rebuilds on theme/font switches.
          _Section(
            label: 'Transport',
            shortcuts: [
              _Shortcut('Play / pause', [
                ['Space'],
              ]),
              _Shortcut('Toggle loop', [
                ['L'],
              ]),
            ],
          ),
          const SizedBox(height: T.gapSection),
          // Not const (see Transport above).
          _Section(
            label: 'Monitoring',
            shortcuts: [
              _Shortcut('Toggle DIM (−20 dB monitor cut)', [
                ['D'],
              ]),
            ],
          ),
          const SizedBox(height: T.gapSection),
          // Not const (see Transport above).
          _Section(
            label: 'Timeline',
            shortcuts: [
              _Shortcut('Zoom in', [
                ['+'],
                ['='],
              ]),
              _Shortcut('Zoom out', [
                ['-'],
              ]),
              _Shortcut('Reset zoom', [
                ['0'],
              ]),
              _Shortcut('Clear selection / loop', [
                ['Esc'],
              ]),
              _Shortcut.mouse('Seek and clear selection', 'double-click'),
            ],
          ),
          const SizedBox(height: T.gapSection),
          _Section(
            label: 'View',
            shortcuts: [
              for (final (i, id) in tabs.indexed)
                _Shortcut('${WorkspaceTabs.title(id)} tab', [_mod('${i + 1}')]),
              _Shortcut('Toggle fullscreen', [
                _isMac ? ['⌃', '⌘', 'F'] : ['F11'],
              ]),
            ],
          ),
        ],
      ),
    );
  }
}

/// One shortcut row: a description plus either key [alternatives] (each
/// a sequence of keys pressed together, rendered as keycaps) or a mouse
/// [gesture] (rendered as plain text — caps are reserved for keys).
class _Shortcut {
  final String description;
  final List<List<String>> alternatives;
  final String? gesture;

  const _Shortcut(this.description, this.alternatives) : gesture = null;
  const _Shortcut.mouse(this.description, this.gesture)
    : alternatives = const [];
}

class _Section extends StatelessWidget {
  final String label;
  final List<_Shortcut> shortcuts;

  const _Section({required this.label, required this.shortcuts});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EyebrowLabel(label),
        const SizedBox(height: T.gapPair),
        ...shortcuts.map((s) => _ShortcutRow(shortcut: s)),
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final _Shortcut shortcut;

  const _ShortcutRow({required this.shortcut});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(shortcut.description, style: T.styleHeading)),
          const SizedBox(width: 12),
          if (shortcut.gesture != null)
            Text(
              shortcut.gesture!,
              style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
            )
          else
            for (var i = 0; i < shortcut.alternatives.length; i++) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Text(
                    'or',
                    style: TextStyle(
                      fontSize: T.fontCaption,
                      color: T.textTertiary,
                    ),
                  ),
                ),
              for (var k = 0; k < shortcut.alternatives[i].length; k++) ...[
                if (k > 0) const SizedBox(width: 3),
                _KeyCap(shortcut.alternatives[i][k]),
              ],
            ],
        ],
      ),
    );
  }
}

/// A single key rendered as a recessed console-style keycap.
class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minWidth: T.fs(22)),
      height: T.fs(20),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        // bgDeep: recessed in every theme (bgControls is lighter
        // than the dialog surface in high contrast, reading raised).
        color: T.bgDeep,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: T.borderStrong, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: T.fontCaption,
          fontFamily: T.monoFamily,
          color: T.textPrimary,
          height: 1.0,
        ),
      ),
    );
  }
}
