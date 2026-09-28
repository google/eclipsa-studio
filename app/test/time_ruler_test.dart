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
import 'package:eclipsa_studio/widgets/time_ruler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the strip re-grounds on a theme switch without a remount', (
    tester,
  ) async {
    // 32 px in every theme: the concepts draw 30, and a component's
    // size does not vary by theme, only how it is drawn and coloured.
    // The ground does vary: bgSurface in the shipped themes, as the
    // Elements view drew it before, bgBase in both concepts.
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  TimeRulerStrip(durationSeconds: 600, playheadSeconds: 60),
                ],
              );
            },
          ),
        ),
      ),
    );
    double height() => tester.getSize(find.byType(TimeRulerStrip)).height;
    expect(height(), 32);
    expect(TimeRulerStrip.ground, T.bgSurface);

    for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
      T.setMode(mode);
      rebuild(() {});
      await tester.pump();
      expect(height(), 32, reason: mode.name);
      expect(TimeRulerStrip.ground, T.bgBase, reason: mode.name);
    }
  });

  test('the playhead head is centred on its x in every style', () {
    // Classic's triangle is 10 x 8; the Dark theme's pentagon 13 x 12;
    // the Light theme's 12 x 12. High Contrast takes E's
    // pentagon at its own 2 px line.
    const expected = {
      ChromeStyle.beveled: Size(13, 12),
      ChromeStyle.raised: Size(12, 12),
      ChromeStyle.recessed: Size(10, 8),
      ChromeStyle.outlined: Size(12, 12),
    };
    for (final style in ChromeStyle.values) {
      final bounds = TimeRulerPainter.playheadHead(100, style).getBounds();
      expect(bounds.size, expected[style], reason: style.name);
      expect(bounds.center.dx, 100, reason: style.name);
      expect(bounds.top, 0, reason: style.name);
    }
  });

  test('the playhead line is 1.5, 1 and 2 px', () {
    expect(PlayheadPainter.widthFor(ChromeStyle.beveled), 1);
    expect(PlayheadPainter.widthFor(ChromeStyle.raised), 2);
    expect(PlayheadPainter.widthFor(ChromeStyle.recessed), 1.5);
    expect(PlayheadPainter.widthFor(ChromeStyle.outlined), 2);
  });

  test('only High Contrast cases its playhead line', () {
    // A yellow line over a yellow waveform needs the 2 px of bgDeep
    // either side; every other style draws the line alone.
    for (final style in ChromeStyle.values) {
      expect(
        PlayheadPainter.casingFor(style),
        style == ChromeStyle.outlined ? 4 : isNull,
        reason: style.name,
      );
    }
  });
}
