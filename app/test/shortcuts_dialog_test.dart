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

import 'package:eclipsa_studio/widgets/shortcuts_dialog.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the shortcut table's content parity now that it is structured
/// data rendered as keycaps: sections, key sequences (platform
/// variant), alternatives, and the gesture row.
void main() {
  final isMac = Platform.isMacOS;

  setUp(() {
    // The full shortcut list outgrows the default 800x600 test surface
    // (the test font renders taller than production fonts).
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1.0;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });

  Future<void> pumpDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ShortcutsDialog())),
      ),
    );
  }

  testWidgets('sections and rows are all present', (tester) async {
    await pumpDialog(tester);
    for (final section in [
      'FILE',
      'TRANSPORT',
      'MONITORING',
      'TIMELINE',
      'VIEW',
    ]) {
      expect(find.text(section), findsOneWidget);
    }
    for (final description in [
      'New session', 'Open session', 'Save', 'Save as',
      'Close session / file', 'Settings', 'Session settings',
      'Play / pause', 'Toggle loop', 'Toggle DIM (−20 dB monitor cut)',
      'Zoom in', 'Zoom out', 'Reset zoom', 'Clear selection / loop',
      'Seek and clear selection', 'Toggle fullscreen', //
    ]) {
      expect(find.text(description), findsOneWidget, reason: description);
    }
  });

  testWidgets('key sequences render per-key caps for this platform', (
    tester,
  ) async {
    await pumpDialog(tester);
    if (isMac) {
      // Save / Save as / Settings / Session settings etc. share ⌘;
      // Save as and Session settings add ⇧.
      expect(find.text('⌘'), findsNWidgets(8));
      expect(find.text('⇧'), findsNWidgets(2));
      expect(find.text('⌃'), findsOneWidget); // fullscreen ⌃⌘F
    } else {
      expect(find.text('Ctrl'), findsNWidgets(7));
      expect(find.text('Shift'), findsNWidgets(2));
      expect(find.text('F11'), findsOneWidget);
    }
    // Zoom in offers two alternatives joined by 'or'.
    expect(find.text('+'), findsOneWidget);
    expect(find.text('='), findsOneWidget);
    expect(find.text('or'), findsOneWidget);
    // Zoom out shows the '-' key, not a typographic dash.
    expect(find.text('-'), findsOneWidget);
    expect(find.text('–'), findsNothing);
  });

  testWidgets('mouse gesture renders as text, not a keycap', (tester) async {
    await pumpDialog(tester);
    expect(find.text('double-click'), findsOneWidget);
  });

  testWidgets('the View section lists the open workspace tabs', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ShortcutsDialog())),
      ),
    );
    // The landing screen has no tabs.
    expect(find.text('Elements tab'), findsNothing);
    expect(find.text('1'), findsNothing);

    // A key cap in the row of [description].
    Finder capIn(String description, String cap) => find.descendant(
      of: find
          .ancestor(of: find.text(description), matching: find.byType(Row))
          .first,
      matching: find.text(cap),
    );

    container.read(workspaceModeProvider.notifier).enterCreator();
    await tester.pump();
    for (final (i, row) in [
      'Elements tab',
      'Mix tab',
      'Renderer tab',
    ].indexed) {
      expect(capIn(row, isMac ? '⌘' : 'Ctrl'), findsOneWidget, reason: row);
      expect(capIn(row, '${i + 1}'), findsOneWidget, reason: row);
    }

    container.read(workspaceModeProvider.notifier).enterPlayback();
    await tester.pump();
    expect(find.text('Inspector tab'), findsOneWidget);
    expect(find.text('Renderer tab'), findsOneWidget);
    expect(find.text('Elements tab'), findsNothing);
    expect(find.text('3'), findsNothing);
  });
}
