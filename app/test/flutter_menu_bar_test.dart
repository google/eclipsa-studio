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

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/app_menu_bar.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_env.dart';

class _StubRecentQcFiles extends RecentQcFilesNotifier {
  @override
  List<String> build() => const [];

  @override
  Future<void> refresh() async {}
}

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          landingVisibleProvider.overrideWithValue(true),
          recentSessionsProvider.overrideWith(StubRecentSessions.new),
          recentQcFilesProvider.overrideWith(_StubRecentQcFiles.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(alignment: Alignment.topLeft, child: FlutterMenuBar()),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('the landing File menu has no two separators together', (
    tester,
  ) async {
    // On the landing screen the Save / Close and session groups are
    // empty. Fixed dividers left a rule above and below the gap where
    // they would have been.
    await pumpBar(tester);
    await open(tester, 'File');
    expect(find.text('Settings...'), findsOneWidget);
    // Open (both kinds) | Settings | Exit.
    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('Loudness Report is greyed on the landing screen and '
      'enabled in Creator and Playback', (tester) async {
    final container = ProviderContainer(
      overrides: [
        landingVisibleProvider.overrideWithValue(true),
        recentSessionsProvider.overrideWith(StubRecentSessions.new),
        recentQcFilesProvider.overrideWith(_StubRecentQcFiles.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(alignment: Alignment.topLeft, child: FlutterMenuBar()),
          ),
        ),
      ),
    );

    Future<bool> enabled() async {
      await open(tester, 'View');
      final button = tester.widget<MenuItemButton>(
        find.ancestor(
          of: find.text('Loudness Report...'),
          matching: find.byType(MenuItemButton),
        ),
      );
      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();
      return button.onPressed != null;
    }

    expect(await enabled(), isFalse);
    container.read(workspaceModeProvider.notifier).enterCreator();
    await tester.pumpAndSettle();
    expect(await enabled(), isTrue);
    container.read(workspaceModeProvider.notifier).enterPlayback();
    await tester.pumpAndSettle();
    expect(await enabled(), isTrue);
  });

  testWidgets('the theme commands are in View, not Help', (tester) async {
    await pumpBar(tester);
    await open(tester, 'Help');
    expect(find.text('Next Theme'), findsNothing);
    await tester.tapAt(const Offset(400, 400));
    await tester.pumpAndSettle();
    await open(tester, 'View');
    expect(find.text('Next Theme'), findsOneWidget);
  });

  testWidgets('a bar title is highlighted only while its menu is open', (
    tester,
  ) async {
    // SubmenuButton takes focus back when its menu closes; a highlight
    // on focus stayed on the title after the menu was dismissed.
    await pumpBar(tester);
    Color? ground() {
      final material = tester.widget<Material>(
        find
            .ancestor(of: find.text('Help'), matching: find.byType(Material))
            .first,
      );
      return material.color;
    }

    final idle = ground();
    await open(tester, 'Help');
    expect(ground(), isNot(idle), reason: 'open menu highlights its title');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard Shortcuts'), findsNothing);
    expect(ground(), idle, reason: 'highlight cleared after close');
  });

  testWidgets('menu rows are 28 px tall in every theme', (tester) async {
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await pumpBar(tester);
      await open(tester, 'Help');
      final row = find.ancestor(
        of: find.text('Keyboard Shortcuts'),
        matching: find.byType(MenuItemButton),
      );
      expect(
        tester.getSize(row).height,
        28,
        reason: 'menu row height in ${mode.name}',
      );
      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();
    }
  });
}
