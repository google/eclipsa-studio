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
import 'package:eclipsa_studio/widgets/status_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every [StatusTag] has one geometry and text style whatever its ink;
/// the fill is the ink at 12%, or `bgControls` for a neutral tag, and
/// an outlined tag adds a rim at 60%.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pump(WidgetTester tester, List<Widget> tags) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: Column(children: tags)),
          ),
        ),
      );

  BoxDecoration decorationOf(WidgetTester tester, String label) =>
      tester
              .widget<Container>(
                find
                    .ancestor(
                      of: find.text(label),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .decoration!
          as BoxDecoration;

  for (final mode in AppThemeMode.values) {
    testWidgets('${mode.name}: one geometry, fills by ink', (tester) async {
      T.setMode(mode);
      await pump(tester, [
        const StatusTag('NEUTRAL'),
        StatusTag('ACCENT', color: T.purpleLight),
        StatusTag('RIM', color: T.objAmber, outlined: true),
        StatusTag('FILL', color: T.textSecondary, fill: T.bgSelected),
      ]);

      for (final label in ['NEUTRAL', 'ACCENT', 'RIM', 'FILL']) {
        final style = tester.widget<Text>(find.text(label)).style!;
        expect(style.fontSize, T.fontCaption, reason: label);
        expect(style.fontWeight, FontWeight.w600, reason: label);
        expect(style.letterSpacing, 0.5, reason: label);
        expect(
          decorationOf(tester, label).borderRadius,
          BorderRadius.circular(T.radiusSm),
          reason: label,
        );
      }

      expect(
        tester.widget<Text>(find.text('NEUTRAL')).style!.color,
        T.textTertiary,
      );
      expect(decorationOf(tester, 'NEUTRAL').color, T.bgControls);
      expect(
        decorationOf(tester, 'ACCENT').color,
        T.purpleLight.withValues(alpha: 0.12),
      );
      expect(decorationOf(tester, 'ACCENT').border, isNull);
      expect(
        decorationOf(tester, 'RIM').border,
        Border.all(color: T.objAmber.withValues(alpha: 0.6)),
      );
      expect(decorationOf(tester, 'RIM').color, isNull);
      expect(decorationOf(tester, 'FILL').color, T.bgSelected);
    });
  }

  testWidgets('an icon draws before the label in the ink', (tester) async {
    const red = Color(0xFFD9534F);
    await pump(tester, [
      const StatusTag('YouTube', color: red, icon: Icons.smart_display),
    ]);
    final icon = tester.widget<Icon>(find.byIcon(Icons.smart_display));
    expect(icon.color, red);
    expect(icon.size, StatusTag.iconSize);
    expect(
      tester.getTopLeft(find.byIcon(Icons.smart_display)).dx,
      lessThan(tester.getTopLeft(find.text('YouTube')).dx),
    );
  });
}
