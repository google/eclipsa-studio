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

// Pins the tab shortcuts (ES-1019): Cmd+digit on macOS and Ctrl+digit
// elsewhere select a workspace tab by its top bar position, and both
// View menus list the mode's tabs with those shortcuts.

import 'dart:io';

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/widgets/app_menu_bar.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:eclipsa_studio/workspace/workspace_tab_shortcuts.dart';
import 'package:flutter/foundation.dart';
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

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      landingVisibleProvider.overrideWithValue(true),
      recentSessionsProvider.overrideWith(StubRecentSessions.new),
      recentQcFilesProvider.overrideWith(_StubRecentQcFiles.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('workspaceTabForKey', () {
    LogicalKeyboardKey? target;
    String? selected;

    Future<void> pump(
      WidgetTester tester,
      WorkspaceMode mode, {
      required bool mac,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && event.logicalKey == target) {
                selected = workspaceTabForKey(event, mode, mac: mac);
              }
              return KeyEventResult.handled;
            },
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
    }

    // Presses [key] with [held] down and returns the tab it selects.
    Future<String?> press(
      WidgetTester tester,
      LogicalKeyboardKey key, [
      List<LogicalKeyboardKey> held = const [],
    ]) async {
      target = key;
      selected = null;
      for (final k in held) {
        await tester.sendKeyDownEvent(k);
      }
      await tester.sendKeyEvent(key);
      for (final k in held.reversed) {
        await tester.sendKeyUpEvent(k);
      }
      return selected;
    }

    const cmd = [LogicalKeyboardKey.metaLeft];
    const ctrl = [LogicalKeyboardKey.controlLeft];

    testWidgets('Cmd+1 to Cmd+3 select the Creator tabs left to right', (
      tester,
    ) async {
      await pump(tester, WorkspaceMode.creator, mac: true);
      expect(
        await press(tester, LogicalKeyboardKey.digit1, cmd),
        WorkspaceTabs.elements,
      );
      expect(
        await press(tester, LogicalKeyboardKey.digit2, cmd),
        WorkspaceTabs.mix,
      );
      expect(
        await press(tester, LogicalKeyboardKey.digit3, cmd),
        WorkspaceTabs.renderer,
      );
    });

    testWidgets('Playback has two tabs, so Cmd+3 selects nothing', (
      tester,
    ) async {
      await pump(tester, WorkspaceMode.playback, mac: true);
      expect(
        await press(tester, LogicalKeyboardKey.digit1, cmd),
        WorkspaceTabs.inspector,
      );
      expect(
        await press(tester, LogicalKeyboardKey.digit2, cmd),
        WorkspaceTabs.renderer,
      );
      expect(await press(tester, LogicalKeyboardKey.digit3, cmd), isNull);
    });

    testWidgets('the landing screen has no tabs to select', (tester) async {
      await pump(tester, WorkspaceMode.none, mac: true);
      expect(await press(tester, LogicalKeyboardKey.digit1, cmd), isNull);
    });

    testWidgets('a bare digit or another modifier selects nothing', (
      tester,
    ) async {
      await pump(tester, WorkspaceMode.creator, mac: true);
      // Bare digits go to the shell's _handleKey, which binds 0 to the
      // timeline zoom reset.
      expect(await press(tester, LogicalKeyboardKey.digit1), isNull);
      expect(await press(tester, LogicalKeyboardKey.digit1, ctrl), isNull);
      expect(
        await press(tester, LogicalKeyboardKey.digit1, [
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.shiftLeft,
        ]),
        isNull,
      );
      expect(
        await press(tester, LogicalKeyboardKey.digit1, [
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.altLeft,
        ]),
        isNull,
      );
    });

    testWidgets('off macOS the modifier is Ctrl, not Cmd', (tester) async {
      await pump(tester, WorkspaceMode.creator, mac: false);
      expect(
        await press(tester, LogicalKeyboardKey.digit1, ctrl),
        WorkspaceTabs.elements,
      );
      expect(
        await press(tester, LogicalKeyboardKey.digit3, ctrl),
        WorkspaceTabs.renderer,
      );
      expect(await press(tester, LogicalKeyboardKey.digit1, cmd), isNull);
    });
  });

  testWidgets('the Windows and Linux View menu lists the mode tabs '
      'on Ctrl+1 to Ctrl+3', (tester) async {
    final container = _container();
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

    Future<void> openView() async {
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
    }

    Future<void> closeMenu() async {
      await tester.tapAt(const Offset(400, 400));
      await tester.pumpAndSettle();
    }

    MenuItemButton row(String label) => tester.widget<MenuItemButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(MenuItemButton),
      ),
    );

    void expectShortcut(String label, LogicalKeyboardKey digit) {
      final shortcut = row(label).shortcut! as SingleActivator;
      expect(shortcut.trigger, digit, reason: label);
      expect(shortcut.control, isTrue, reason: label);
      expect(shortcut.meta, isFalse, reason: label);
    }

    await openView();
    for (final label in ['Elements', 'Mix', 'Renderer', 'Inspector']) {
      expect(find.text(label), findsNothing, reason: 'landing: $label');
    }
    await closeMenu();

    container.read(workspaceModeProvider.notifier).enterCreator();
    await tester.pumpAndSettle();
    await openView();
    expectShortcut('Elements', LogicalKeyboardKey.digit1);
    expectShortcut('Mix', LogicalKeyboardKey.digit2);
    expectShortcut('Renderer', LogicalKeyboardKey.digit3);
    expect(find.text('Inspector'), findsNothing);
    await tester.tap(find.text('Mix'));
    await tester.pumpAndSettle();
    expect(container.read(activeTabProvider), WorkspaceTabs.mix);

    container.read(workspaceModeProvider.notifier).enterPlayback();
    await tester.pumpAndSettle();
    await openView();
    expectShortcut('Inspector', LogicalKeyboardKey.digit1);
    expectShortcut('Renderer', LogicalKeyboardKey.digit2);
    expect(find.text('Elements'), findsNothing);
    await closeMenu();
  });

  testWidgets('the macOS View menu lists the mode tabs on Cmd+1 to Cmd+3', (
    tester,
  ) async {
    // As in app_menu_bar_landing_test: PlatformProvidedMenuItem checks
    // defaultTargetPlatform, which is android under flutter_test, and the
    // override must be reset inside the body.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final container = _container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AppMenuBar(child: Scaffold(body: SizedBox.expand())),
          ),
        ),
      );

      List<PlatformMenuItem> tabItems() {
        final bar = tester.widget<PlatformMenuBar>(
          find.byType(PlatformMenuBar),
        );
        final view = bar.menus.whereType<PlatformMenu>().firstWhere(
          (m) => m.label == 'View',
        );
        final group = view.menus.whereType<PlatformMenuItemGroup>().first;
        return group.members.toList();
      }

      container.read(workspaceModeProvider.notifier).enterCreator();
      await tester.pump();
      var items = tabItems();
      expect(items.map((m) => m.label), ['Elements', 'Mix', 'Renderer']);
      for (final (i, item) in items.indexed) {
        final shortcut = item.shortcut! as SingleActivator;
        expect(
          shortcut.trigger,
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
          ][i],
        );
        expect(shortcut.meta, isTrue);
        expect(shortcut.control, isFalse);
      }
      items[2].onSelected!();
      expect(container.read(activeTabProvider), WorkspaceTabs.renderer);

      container.read(workspaceModeProvider.notifier).enterPlayback();
      await tester.pump();
      items = tabItems();
      expect(items.map((m) => m.label), ['Inspector', 'Renderer']);
      items[0].onSelected!();
      expect(container.read(activeTabProvider), WorkspaceTabs.inspector);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, skip: !Platform.isMacOS);
}
