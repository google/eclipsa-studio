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
import 'package:eclipsa_studio/widgets/statusbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the strip keeps its height and gap in every theme', (
    tester,
  ) async {
    // 28 tall with a gapXl gap in every theme: the concepts draw a 52
    // px bar spacing its items 56 apart, and a component's size does
    // not vary by theme, only how it is drawn and coloured. The strip
    // is not const-constructed, so a rebuild after setMode still has
    // to lay it out in place rather than remount it.
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  StatusbarStrip(
                    children: [
                      Text('48000 Hz', style: statusbarTextStyle()),
                      SizedBox(width: StatusbarStrip.gap),
                      Text('512 smp', style: statusbarTextStyle()),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    double height() => tester.getSize(find.byType(StatusbarStrip)).height;
    double gap() =>
        tester.getTopLeft(find.text('512 smp')).dx -
        tester.getTopRight(find.text('48000 Hz')).dx;

    expect(height(), 28);
    expect(gap(), T.gapXl);

    for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
      T.setMode(mode);
      rebuild(() {});
      await tester.pump();
      expect(height(), 28, reason: mode.name);
      expect(gap(), T.gapXl, reason: mode.name);
    }

    T.setMode(AppThemeMode.highContrast);
    rebuild(() {});
    await tester.pump();
    expect(height(), 28);
    expect(gap(), T.gapXl);
  });

  testWidgets('a value box fits its widest value in every theme and size', (
    tester,
  ) async {
    // "100%" is wider than the constant 28 px the readouts used to get,
    // and the concepts' tracking (0.41 in D, 0.42 and weight 500 in E)
    // widens it further, which wrapped the value onto a second line.
    // The box is measured from the widest value the readout shows, so
    // it has to hold that value at every font-size mode too.
    addTearDown(() => T.setFontMode(FontSizeMode.medium));
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      for (final font in FontSizeMode.values) {
        T.setFontMode(font);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: StatusbarValue(
                  key: ValueKey('${mode.name}/${font.name}'),
                  label: 'Engine',
                  value: '100%',
                  widest: '100%',
                  color: StatusbarStrip.ink,
                  tooltip: 'Audio engine CPU load',
                ),
              ),
            ),
          ),
        );
        final box = tester.renderObject<RenderBox>(find.text('100%'));
        expect(
          box.size.width,
          greaterThanOrEqualTo(box.getMaxIntrinsicWidth(double.infinity)),
          reason: '${mode.name} / ${font.name}',
        );
      }
    }
  });

  testWidgets('the text is fontBody in every style, in the bar\'s ink', (
    tester,
  ) async {
    // Every bar keeps the fontBody the flat one had; 14 px read too
    // large in the app. The Dark theme's #898989 is textMuted; the
    // Light theme's #44413C on its light bar is chromeInk, and so is
    // the ink of the three remade bars.
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      final style = statusbarTextStyle();
      final t = T.themeFor(mode);
      expect(style.fontSize, T.fontBody, reason: mode.name);
      expect(
        style.color,
        t.chromeStyle == ChromeStyle.beveled ? t.textMuted : t.chromeInk,
        reason: mode.name,
      );
      // A state colour wins over the ink in every style.
      expect(statusbarTextStyle(color: t.meterRed).color, t.meterRed);
    }
  });
}
