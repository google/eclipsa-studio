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
import 'package:eclipsa_studio/widgets/gain_knob.dart';
import 'package:eclipsa_studio/widgets/knob_a.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// knobStyle is the first token that selects a *drawing* rather than a
// value, so what needs pinning is that the selection reaches the canvas
// -- a token nothing reads would generate, validate and gate perfectly
// while changing nothing on screen.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<Type> painterFor(WidgetTester tester, AppThemeMode mode) async {
    T.setMode(mode);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GainKnob(gainDb: -16.1, size: 48, onChanged: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
    final knob = paints.firstWhere((p) => p.painter != null);
    return knob.painter.runtimeType;
  }

  testWidgets('the theme picks which knob is drawn', (tester) async {
    final bar = await painterFor(tester, AppThemeMode.classic);
    final brushed = await painterFor(tester, AppThemeMode.dark);
    expect(
      brushed,
      isNot(bar),
      reason:
          'the Dark theme selects KnobStyle.brushed, so it must not paint '
          'the painter Classic draws for KnobStyle.bar',
    );
  });

  testWidgets('every theme draws a different knob', (tester) async {
    // Four themes, four painters: the 2026-09 remake gave Classic and High Contrast one
    // each (BarKnobPainter, OutlinedKnobPainter) beside the Dark theme's
    // brushed painter and the Light theme's KnobA.
    final seen = <Type>{};
    for (final mode in AppThemeMode.values) {
      seen.add(await painterFor(tester, mode));
    }
    expect(seen.length, AppThemeMode.values.length, reason: seen.toString());
  });

  testWidgets('the Light theme reaches KnobA through GainKnob', (tester) async {
    // GainKnob returns the KnobA widget for this style rather than
    // painting it, so the check is that the widget is there and that
    // GainKnob does not also wrap it in a second drag recogniser.
    T.setMode(AppThemeMode.light);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: GainKnob(gainDb: 0, size: 45, onChanged: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KnobA), findsOneWidget);
    expect(find.byType(GestureDetector), findsOneWidget);
  });

  test('every theme names a knob style, one per theme family', () {
    const expected = {
      AppThemeMode.classic: KnobStyle.bar,
      AppThemeMode.highContrast: KnobStyle.outlined,
      AppThemeMode.dark: KnobStyle.brushed,
      AppThemeMode.light: KnobStyle.knobA,
    };
    for (final mode in AppThemeMode.values) {
      expect(
        T.themeFor(mode).knobStyle,
        expected[mode],
        reason: '${mode.name} knobStyle',
      );
    }
  });

  // Every style shares KnobGestures: 0.3 dB per pixel, rounded to 0.1,
  // clamped to the range, and a double-tap back to 0.
  Future<List<double>> dragAndTap(
    WidgetTester tester,
    AppThemeMode mode,
  ) async {
    T.setMode(mode);
    final values = <double>[];
    var gain = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => GainKnob(
                gainDb: gain,
                size: 48,
                onChanged: (v) => setState(() {
                  gain = v;
                  values.add(v);
                }),
              ),
            ),
          ),
        ),
      ),
    );
    final centre = tester.getCenter(find.byType(GainKnob));
    final gesture = await tester.startGesture(centre);
    // 400 px down is 120 dB, past the -60 floor.
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    final atFloor = gain;
    // Back up 10 px: 3 dB, which must move the value at once.
    await gesture.moveBy(const Offset(0, -10));
    await tester.pump();
    final afterReverse = gain;
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    return [atFloor, afterReverse, gain];
  }

  testWidgets('every knob drags, clamps and resets the same way', (
    tester,
  ) async {
    for (final mode in AppThemeMode.values) {
      final [atFloor, afterReverse, afterDoubleTap] = await dragAndTap(
        tester,
        mode,
      );
      expect(atFloor, -60, reason: '${mode.name} clamps at min');
      expect(afterReverse, -57, reason: '${mode.name} reverses at once');
      expect(afterDoubleTap, 0, reason: '${mode.name} double-tap resets');
    }
  });

  testWidgets('the brushed knob renders at the shipped 28px size', (
    tester,
  ) async {
    // Its geometry is fractions of an arc radius derived from the box,
    // and the floors on stroke widths exist so nothing collapses to a
    // hairline at the size elements_view actually uses.
    T.setMode(AppThemeMode.dark);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: GainKnob(gainDb: 0, size: 28, onChanged: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar knob renders at the shipped 28px size', (tester) async {
    // Same reason: the cap's gap, the bar's width, the top face's
    // inset and the dimple are fractions of the dish radius with
    // floors, and the face's corner radius must stay non-negative
    // once the inset is taken off it.
    T.setMode(AppThemeMode.classic);
    for (final db in [-60.0, -16.1, 0.0, 12.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GainKnob(gainDb: db, size: 28, onChanged: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$db dB');
    }
  });
}
