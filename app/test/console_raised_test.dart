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

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two console controls the Light theme redraws: the switch and
/// the segment chip. Each keeps its size in every theme and changes
/// only its drawing. The affirmative button is `AppButton`'s
/// Light accent pair, tested in app_button_test.dart.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  /// Every [BoxDecoration] under [of], innermost last.
  List<BoxDecoration> decorations(WidgetTester tester, Finder of) => tester
      .widgetList<Container>(
        find.descendant(of: of, matching: find.byType(Container)),
      )
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .toList();

  group('ConsoleToggle', () {
    testWidgets('the Light theme draws a pill with a round knob', (
      tester,
    ) async {
      T.setMode(AppThemeMode.light);
      await pump(tester, ConsoleToggle(value: true, onChanged: (_) {}));
      final boxes = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .toList();
      final track = boxes.first;
      expect(track.color, T.bgControls);
      expect(track.border, isNull, reason: 'the frame draws no rim');
      expect(track.borderRadius, BorderRadius.circular(9), reason: 'a pill');
      final knob = boxes.last;
      expect(knob.shape, BoxShape.circle);
      expect(knob.color, T.chromeTabOn);
      expect(knob.boxShadow, isNull, reason: 'the colour carries the state');
    });

    testWidgets('a caller naming an activeColor still gets it', (tester) async {
      T.setMode(AppThemeMode.light);
      await pump(
        tester,
        ConsoleToggle(value: true, onChanged: (_) {}, activeColor: T.objAmber),
      );
      final boxes = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .toList();
      expect(
        boxes.last.color,
        T.objAmber,
        reason: 'the DIM readout beside it is amber in the status bar',
      );
    });

    testWidgets('the off knob takes chromeTabOff', (tester) async {
      T.setMode(AppThemeMode.light);
      await pump(tester, ConsoleToggle(value: false, onChanged: (_) {}));
      final boxes = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .toList();
      expect(boxes.last.color, T.chromeTabOff);
    });

    testWidgets('every other theme keeps the recessed well', (tester) async {
      for (final mode in [
        AppThemeMode.classic,
        AppThemeMode.highContrast,
        AppThemeMode.dark,
      ]) {
        T.setMode(mode);
        await tester.pumpWidget(const SizedBox());
        await pump(tester, ConsoleToggle(value: true, onChanged: (_) {}));
        final boxes = tester
            .widgetList<Container>(find.byType(Container))
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .toList();
        expect(boxes.first.color, T.bgDeep, reason: mode.name);
        expect(boxes.first.border, isNotNull, reason: mode.name);
        expect(boxes.last.shape, BoxShape.rectangle, reason: mode.name);
      }
    });

    testWidgets('the switch is 36 x 18 in every theme', (tester) async {
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        await tester.pumpWidget(const SizedBox());
        await pump(tester, ConsoleToggle(value: true, onChanged: (_) {}));
        expect(
          tester.getSize(find.byType(Container).first),
          const Size(36, 18),
          reason: mode.name,
        );
      }
    });
  });

  group('ConsoleSegment', () {
    Widget segment() => ConsoleSegment<String>(
      options: const [('a', 'A'), ('b', 'B')],
      value: 'a',
      onChanged: (_) {},
    );

    testWidgets('the Light theme fills the selected chip in the accent', (
      tester,
    ) async {
      T.setMode(AppThemeMode.light);
      await pump(tester, segment());
      final boxes = decorations(tester, find.byType(ConsoleSegment<String>));
      expect(boxes.first.color, isNull, reason: 'no outer well');
      // The selected cell: bgElevated under a border rim.
      expect(boxes.any((d) => d.color == T.bgElevated), isTrue);
      expect(boxes.any((d) => d.color == T.bgControls), isTrue);
      // The accent fill sits in a DecoratedBox inside the rim.
      final fills = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.color == T.chromeTabOn);
      expect(fills, isNotEmpty, reason: 'the selected chip fills chromeTabOn');
      expect(
        tester.widget<Text>(find.text('A')).style!.color,
        T.bgBase,
        reason: 'bgBase on chromeTabOn is 8.09:1; textPrimary is 1.83:1',
      );
      expect(tester.widget<Text>(find.text('B')).style!.color, T.chromeTabOn);
    });

    testWidgets('every other theme keeps one well', (tester) async {
      for (final mode in [AppThemeMode.classic, AppThemeMode.dark]) {
        T.setMode(mode);
        await tester.pumpWidget(const SizedBox());
        await pump(tester, segment());
        final boxes = decorations(tester, find.byType(ConsoleSegment<String>));
        expect(boxes.first.color, T.bgDeep, reason: mode.name);
        expect(boxes.first.border, isNotNull, reason: mode.name);
      }
    });

    testWidgets('the selected chip fills its face, not its glyphs', (
      tester,
    ) async {
      T.setMode(AppThemeMode.light);
      await pump(tester, segment());
      // The chip: the cell less its 1 px margin a side. The fill: that
      // less the rim. A Container that pads or aligns its child hands
      // it loose constraints, and a DecoratedBox under those
      // shrink-wraps to the label -- which is what this catches.
      // The rim box (bgElevated) and the accent fill inside it. Sizing
      // the Container itself would include its 1 px margin.
      Finder boxOf(Color c) => find.descendant(
        of: find.byType(ConsoleSegment<String>),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox && (w.decoration as BoxDecoration).color == c,
        ),
      );
      final rim = tester.getSize(boxOf(T.bgElevated));
      expect(
        tester.getSize(boxOf(T.chromeTabOn)),
        Size(rim.width - 2 * T.borderWidth, rim.height - 2 * T.borderWidth),
        reason: 'the accent fills the face one border inside the rim',
      );
    });

    testWidgets('the control measures the same in every theme', (tester) async {
      final sizes = <AppThemeMode, Size>{};
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        await tester.pumpWidget(const SizedBox());
        await pump(tester, segment());
        final size = tester.getSize(find.byType(ConsoleSegment<String>));
        expect(size.height, 24, reason: mode.name);
        sizes[mode] = size;
      }
      // Hug mode, where nothing external pins the width: a raised cell
      // spends 2 px on its margin and 2 px on its rim and pays for both
      // out of its own padding, and the outer rim stays in the layout
      // as a transparent border.
      for (final entry in sizes.entries) {
        expect(
          entry.value.width,
          sizes[AppThemeMode.classic]!.width,
          reason: '${entry.key.name} must measure as classic does',
        );
      }
    });
  });
}
