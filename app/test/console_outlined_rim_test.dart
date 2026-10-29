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
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In the `outlined` chrome (High Contrast) the switch's track and the
/// segmented control draw the same rim as the outlined dropdown
/// ([SelectorChrome]): `borderWidth` in `borderStrong`. Dark and Classic
/// keep their 1 px `border` rim; Light draws neither rim.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  BorderSide side(Decoration? d) =>
      ((d! as BoxDecoration).border! as Border).top;

  /// The outlined dropdown's rim in High Contrast.
  BorderSide dropdownRim({bool hover = false, double dim = 1}) {
    T.setMode(AppThemeMode.highContrast);
    return side(SelectorChrome.decoration(hover: hover, dim: dim));
  }

  Finder track() => find
      .descendant(
        of: find.byType(ConsoleToggle),
        matching: find.byType(Container),
      )
      .first;

  Finder well() => find
      .descendant(
        of: find.byType(ConsoleSegment<String>),
        matching: find.byType(Container),
      )
      .first;

  Widget segment() => ConsoleSegment<String>(
    options: const [('a', 'A'), ('b', 'B'), ('c', 'C')],
    value: 'b',
    onChanged: (_) {},
  );

  testWidgets('the High Contrast track rim is the outlined dropdown rim', (
    tester,
  ) async {
    T.setMode(AppThemeMode.highContrast);
    await pump(tester, ConsoleToggle(value: false, onChanged: (_) {}));
    final rim = side(tester.widget<Container>(track()).decoration);
    expect(rim.width, T.borderWidth);
    expect(rim.color, T.borderStrong);
    expect(rim, dropdownRim());
  });

  // controlFg and borderStrong are both white in High Contrast, so the rim
  // does not change colour under the pointer there; this pins that it
  // follows the dropdown's hover rim.
  testWidgets('the High Contrast track rim follows the dropdown rim under '
      'the pointer', (tester) async {
    T.setMode(AppThemeMode.highContrast);
    await pump(tester, ConsoleToggle(value: false, onChanged: (_) {}));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(track()));
    await tester.pump();
    final rim = side(tester.widget<Container>(track()).decoration);
    expect(rim.color, T.controlFg);
    expect(rim, dropdownRim(hover: true));
  });

  testWidgets('the High Contrast segment rim is the outlined dropdown rim', (
    tester,
  ) async {
    T.setMode(AppThemeMode.highContrast);
    await pump(tester, segment());
    final rim = side(tester.widget<Container>(well()).foregroundDecoration);
    expect(rim.width, T.borderWidth);
    expect(rim.color, T.borderStrong);
    expect(rim, dropdownRim());
  });

  testWidgets('a disabled High Contrast segment draws one dimmed rim', (
    tester,
  ) async {
    T.setMode(AppThemeMode.highContrast);
    await pump(
      tester,
      ConsoleSegment<String>(
        options: const [('a', 'A'), ('b', 'B')],
        value: 'a',
        onChanged: (_) {},
        enabled: false,
      ),
    );
    final box = tester.widget<Container>(well());
    // The layout rim under the foreground rim stays transparent, so the
    // dimmed rim is one tone, as on the disabled outlined dropdown.
    expect(side(box.decoration).color.a, 0);
    expect(side(box.foregroundDecoration), dropdownRim(dim: 0.4));
  });

  testWidgets('a High Contrast segment cell keeps its measured width', (
    tester,
  ) async {
    // The 2 px rim is painted over the layout, so a control at
    // uniformWidth gives every cell the same width in High Contrast as in
    // Classic, whose rim is 1 px.
    final cells = <AppThemeMode, List<double>>{};
    for (final mode in [AppThemeMode.classic, AppThemeMode.highContrast]) {
      T.setMode(mode);
      await tester.pumpWidget(const SizedBox());
      await pump(
        tester,
        Builder(
          builder: (context) => ConsoleSegment<String>(
            options: const [('a', 'A'), ('b', 'Wide label'), ('c', 'C')],
            value: 'b',
            onChanged: (_) {},
            width: ConsoleSegment.uniformWidth(context, [
              ['A', 'Wide label', 'C'],
            ]),
          ),
        ),
      );
      cells[mode] = [
        for (final e in tester.elementList(
          find.descendant(
            of: find.byType(ConsoleSegment<String>),
            matching: find.byType(Expanded),
          ),
        ))
          e.size!.width,
      ];
    }
    expect(cells[AppThemeMode.highContrast], cells[AppThemeMode.classic]);
    expect(cells[AppThemeMode.highContrast], hasLength(3));
  });

  for (final mode in [AppThemeMode.dark, AppThemeMode.classic]) {
    testWidgets('${mode.name} keeps the 1 px border rim', (tester) async {
      T.setMode(mode);
      await pump(tester, ConsoleToggle(value: false, onChanged: (_) {}));
      final trackRim = side(tester.widget<Container>(track()).decoration);
      expect(trackRim.width, 1);
      expect(trackRim.color, T.border);
      await pump(tester, segment());
      final wellBox = tester.widget<Container>(well());
      expect(side(wellBox.decoration).width, 1);
      expect(side(wellBox.decoration).color, T.border);
      expect(wellBox.foregroundDecoration, isNull);
    });
  }
}
