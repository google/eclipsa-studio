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

import 'dart:ui' show Tristate;

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The shared selector is operable from the keyboard and announced to
// assistive technology (ES-572): Tab reaches the trigger, Enter, Space
// and the arrow keys open the menu with focus on the selected row, the
// arrow keys walk the rows, Enter picks one, Escape closes, and the
// trigger is a button whose value is the selected label. The focus
// ring follows key presses only, and a menu the pointer opens hands
// focus back when it closes.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  const items = [(1, 'Stereo'), (2, 'Binaural'), (3, '5.1')];

  Widget host({
    int value = 2,
    ValueChanged<int>? onChanged,
    bool enabled = true,
    String? semanticLabel,
    bool Function(int)? itemEnabled,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: ConsoleSelector<int>(
          width: 160,
          value: value,
          items: items,
          onChanged: onChanged ?? (_) {},
          enabled: enabled,
          semanticLabel: semanticLabel,
          itemEnabled: itemEnabled,
        ),
      ),
    ),
  );

  Finder trigger() => find.byType(ConsoleSelector<int>);

  bool triggerFocused(WidgetTester tester) => tester
      .widget<FocusableActionDetector>(
        find.descendant(
          of: trigger(),
          matching: find.byType(FocusableActionDetector),
        ),
      )
      .focusNode!
      .hasPrimaryFocus;

  Finder row(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(MenuItemButton),
  );

  bool rowFocused(WidgetTester tester, String label) => Focus.of(
    tester.element(find.descendant(of: row(label), matching: find.text(label))),
  ).hasFocus;

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pumpAndSettle();
  }

  testWidgets('Tab focuses the trigger without opening it', (tester) async {
    await tester.pumpWidget(host());
    expect(triggerFocused(tester), isFalse);
    await key(tester, LogicalKeyboardKey.tab);
    expect(triggerFocused(tester), isTrue);
    expect(find.byType(MenuItemButton), findsNothing);
  });

  // Space opens the menu where nothing above the control takes it: in
  // a dialog. Inside the app shell, Space is the transport key.
  for (final (name, k) in [
    ('Enter', LogicalKeyboardKey.enter),
    ('Space', LogicalKeyboardKey.space),
    ('ArrowDown', LogicalKeyboardKey.arrowDown),
    ('ArrowUp', LogicalKeyboardKey.arrowUp),
  ]) {
    testWidgets('$name opens the menu with focus on the selected row', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await key(tester, LogicalKeyboardKey.tab);
      await key(tester, k);
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      expect(rowFocused(tester, 'Binaural'), isTrue);
    });
  }

  testWidgets('a disabled current value lands focus on the first enabled '
      'row', (tester) async {
    await tester.pumpWidget(host(itemEnabled: (v) => v != 2));
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.enter);
    expect(rowFocused(tester, 'Stereo'), isTrue);
  });

  testWidgets('the arrow keys walk the rows and Enter picks one', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(host(onChanged: (v) => picked = v));
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(rowFocused(tester, '5.1'), isTrue);
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(rowFocused(tester, 'Stereo'), isTrue);
    await key(tester, LogicalKeyboardKey.enter);
    expect(picked, 1);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(triggerFocused(tester), isTrue);
  });

  testWidgets('Enter on the open trigger and Escape both close the menu', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(triggerFocused(tester), isTrue);

    // Opened by the pointer, focus stays on the trigger: Enter there
    // closes the menu again.
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(triggerFocused(tester), isTrue);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNothing);
    // A key closed it, so focus stays for the next one.
    expect(triggerFocused(tester), isTrue);
  });

  testWidgets('a row picked with the pointer hands focus back', (tester) async {
    int? picked;
    await tester.pumpWidget(host(onChanged: (v) => picked = v));
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    await tester.tap(row('5.1'));
    await tester.pumpAndSettle();
    expect(picked, 3);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(triggerFocused(tester), isFalse);
    // The keyboard still reaches the trigger.
    await key(tester, LogicalKeyboardKey.tab);
    expect(triggerFocused(tester), isTrue);
  });

  testWidgets('a pointer-opened menu dismissed outside hands focus back', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(triggerFocused(tester), isFalse);
  });

  testWidgets('a pointer tap that closes the menu hands focus back', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(triggerFocused(tester), isFalse);
  });

  testWidgets('a pointer-opened menu picked from the keyboard keeps focus', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(host(onChanged: (v) => picked = v));
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.enter);
    expect(picked, 3);
    expect(triggerFocused(tester), isTrue);
  });

  testWidgets('ArrowDown on a pointer-opened menu moves focus into it', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    expect(triggerFocused(tester), isTrue);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(rowFocused(tester, 'Binaural'), isTrue);
  });

  BoxDecoration decoration(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.descendant(
                  of: trigger(),
                  matching: find.byType(Container),
                ),
              )
              .decoration
          as BoxDecoration;

  BorderSide rim(WidgetTester tester) =>
      (decoration(tester).border! as Border).top;

  void alwaysShowFocus() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  }

  testWidgets('a space above the control that takes Space keeps it closed', (
    tester,
  ) async {
    // The app shell's focus scope handles Space for the transport
    // before any focused control sees it.
    var spaces = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FocusScope(
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.space) {
              spaces++;
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Scaffold(
            body: Center(
              child: ConsoleSelector<int>(
                width: 160,
                value: 2,
                items: items,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.space);
    expect(spaces, 1);
    expect(find.byType(MenuItemButton), findsNothing);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNWidgets(3));
  });

  testWidgets('disabling a focused trigger clears its ring and focus state', (
    tester,
  ) async {
    alwaysShowFocus();
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host());
    final rest = rim(tester);
    await key(tester, LogicalKeyboardKey.tab);
    expect(rim(tester).color, SelectorChrome.focusColor);
    await tester.pumpWidget(host(enabled: false));
    final data = tester.getSemantics(trigger()).getSemanticsData();
    expect(data.flagsCollection.isFocused, isNot(Tristate.isTrue));
    await tester.pumpWidget(host());
    expect(rim(tester), rest);
    expect(triggerFocused(tester), isFalse);
    handle.dispose();
  });

  testWidgets('the focused trigger draws the focus ring', (tester) async {
    alwaysShowFocus();
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await tester.pumpWidget(host());
      final rest = rim(tester);
      await key(tester, LogicalKeyboardKey.tab);
      final ring = rim(tester);
      expect(
        ring.color,
        SelectorChrome.focusColor,
        reason: '${kThemeMeta[mode]!.label}: focus rim',
      );
      expect(
        ring.color != rest.color || ring.width != rest.width,
        isTrue,
        reason: '${kThemeMeta[mode]!.label}: the ring differs from rest',
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a menu opened with the pointer draws no ring', (tester) async {
    alwaysShowFocus();
    await tester.pumpWidget(host());
    final rest = rim(tester);
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    expect(triggerFocused(tester), isTrue);
    expect(rim(tester), rest, reason: 'open');
    await tester.tap(row('5.1'));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      expect(rim(tester), rest, reason: 'frame $i after the pick');
    }
  });

  testWidgets('a key on a pointer-opened trigger brings the ring back', (
    tester,
  ) async {
    alwaysShowFocus();
    await tester.pumpWidget(host());
    final rest = rim(tester);
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    expect(rim(tester), rest);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(rim(tester).color, SelectorChrome.focusColor);
  });

  testWidgets('Escape on a pointer-opened menu keeps focus and the ring', (
    tester,
  ) async {
    alwaysShowFocus();
    await tester.pumpWidget(host());
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      expect(triggerFocused(tester), isTrue, reason: 'frame $i');
      expect(rim(tester).color, SelectorChrome.focusColor, reason: 'frame $i');
    }
  });

  testWidgets('a modifier key on a pointer-opened menu draws no ring', (
    tester,
  ) async {
    alwaysShowFocus();
    await tester.pumpWidget(host());
    final rest = rim(tester);
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(rim(tester), rest);
  });

  testWidgets('a pointer press elsewhere hides the ring of a focused trigger', (
    tester,
  ) async {
    alwaysShowFocus();
    await tester.pumpWidget(host());
    final rest = rim(tester);
    await key(tester, LogicalKeyboardKey.tab);
    expect(rim(tester).color, SelectorChrome.focusColor);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(triggerFocused(tester), isTrue);
    expect(rim(tester), rest);
  });

  testWidgets('the trigger is a button whose value is the selected label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(semanticLabel: 'Monitoring layout'));
    var node = tester.getSemantics(trigger()).getSemanticsData();
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, Tristate.isTrue);
    // A focusable node carries a focused state, true or false.
    expect(node.flagsCollection.isFocused, Tristate.isFalse);
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    expect(node.label, 'Monitoring layout');
    expect(node.value, 'Binaural');
    // The focused state follows focus itself, not the drawn ring.
    await key(tester, LogicalKeyboardKey.tab);
    node = tester.getSemantics(trigger()).getSemanticsData();
    expect(node.flagsCollection.isFocused, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('a disabled trigger announces as a disabled button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(enabled: false));
    final node = tester.getSemantics(trigger()).getSemanticsData();
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    expect(node.hasAction(SemanticsAction.tap), isFalse);
    expect(node.value, 'Binaural');
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNothing);
    handle.dispose();
  });

  // MenuItemButton leaves the button flag off outside the web; the row
  // announces by its label, its tap action and its selected state.
  testWidgets('the rows are tappable and the current one is selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host());
    await tester.tap(trigger());
    await tester.pumpAndSettle();
    final current = tester.getSemantics(row('Binaural')).getSemanticsData();
    expect(current.hasAction(SemanticsAction.tap), isTrue);
    expect(current.flagsCollection.isSelected, Tristate.isTrue);
    expect(current.label, 'Binaural');
    final other = tester.getSemantics(row('Stereo')).getSemanticsData();
    expect(other.flagsCollection.isSelected, isNot(Tristate.isTrue));
    handle.dispose();
  });
}
