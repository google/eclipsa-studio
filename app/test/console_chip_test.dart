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
import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:eclipsa_studio/widgets/console_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [ConsoleChip] with a tap is a button, one without is a label at
/// rest, and a disabled one takes no tap. Its content takes the chip's
/// ink: text through the default text style, icons through the icon
/// theme. The face drawings per theme are pinned by option_grid_test.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pump(WidgetTester tester, Widget chip) => tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Center(child: chip)),
      ),
    ),
  );

  testWidgets('a chip with a tap is a button', (tester) async {
    var taps = 0;
    await pump(
      tester,
      ConsoleChip(
        onTap: () => taps++,
        semanticLabel: 'A',
        child: const Text('A'),
      ),
    );
    expect(find.byType(ChromePressable), findsOneWidget);
    await tester.tap(find.text('A'));
    expect(taps, 1);
  });

  testWidgets('a chip without a tap is a label', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, const ConsoleChip(selected: true, child: Text('A')));
    expect(find.byType(ChromePressable), findsNothing);
    // Announced by its text alone, not as a selected choice.
    final data = tester.getSemantics(find.text('A')).getSemanticsData();
    expect(data.flagsCollection.isSelected, isNot(Tristate.isTrue));
    expect(data.flagsCollection.isButton, isFalse);
    semantics.dispose();
    expect(tester.getSize(find.byType(ConsoleChip)).height, ConsoleChip.height);
  });

  testWidgets('a chip takes its content width in a loose width', (
    tester,
  ) async {
    await pump(
      tester,
      const SizedBox(
        width: 400,
        child: Wrap(children: [ConsoleChip(child: Text('A'))]),
      ),
    );
    expect(tester.getSize(find.byType(ConsoleChip)).width, lessThan(100));
  });

  testWidgets('a disabled chip takes no tap and dims its face', (tester) async {
    var taps = 0;
    await pump(
      tester,
      ConsoleChip(
        enabled: false,
        onTap: () => taps++,
        semanticLabel: 'A',
        child: const Text('A'),
      ),
    );
    await tester.tap(find.text('A'), warnIfMissed: false);
    expect(taps, 0);
    final dim = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(ConsoleChip),
        matching: find.byType(Opacity),
      ),
    );
    expect(dim.opacity, 0.4);
  });

  for (final mode in AppThemeMode.values) {
    for (final selected in [false, true]) {
      testWidgets('${mode.name}: content takes the '
          '${selected ? 'selected' : 'plain'} ink', (tester) async {
        T.setMode(mode);
        await pump(
          tester,
          ConsoleChip(
            selected: selected,
            onTap: () {},
            semanticLabel: 'A',
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [Text('A'), Icon(Icons.add)],
            ),
          ),
        );
        final ink = ConsoleChip.ink(selected: selected);
        final text = DefaultTextStyle.of(tester.element(find.text('A')));
        expect(text.style.color, ink);
        expect(
          text.style.fontWeight,
          selected ? FontWeight.w600 : FontWeight.w400,
        );
        expect(IconTheme.of(tester.element(find.byIcon(Icons.add))).color, ink);
      });
    }

    testWidgets('${mode.name}: a selected chip is an accent fill with no '
        'rim under an accentInk label', (tester) async {
      T.setMode(mode);
      await pump(
        tester,
        ConsoleChip(
          selected: true,
          onTap: () {},
          semanticLabel: 'Main',
          child: const Text('Main'),
        ),
      );
      final face = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(ConsoleChip),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((d) => d.decoration as BoxDecoration)
          .single;
      expect(face.color, T.accentFill);
      expect(face.border, isNull);
      final text = DefaultTextStyle.of(tester.element(find.text('Main')));
      expect(text.style.color, T.accentInk);
      expect(text.style.fontWeight, FontWeight.w600);
    });
  }
}
