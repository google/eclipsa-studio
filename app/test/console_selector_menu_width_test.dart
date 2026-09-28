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

import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The open menu must never be narrower than the closed control — including
// for a width-less selector stretched by its parent (the ADM import dialog
// pattern), where `widget.width` is null and the trigger's rendered width is
// the only source of truth. Rows may still grow wider for notes/badges.
void main() {
  Widget host({double? width, required double parentWidth}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: parentWidth,
          child: ConsoleSelector<int>(
            width: width,
            value: 1,
            items: const [(1, 'A'), (2, 'B')],
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );

  Future<double> openAndMeasureRow(WidgetTester tester) async {
    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    final row = find.byType(MenuItemButton).first;
    expect(row, findsOneWidget);
    return tester.getSize(row).width;
  }

  testWidgets('width-less selector: menu rows match the stretched trigger', (
    tester,
  ) async {
    await tester.pumpWidget(host(parentWidth: 400));
    final trigger = tester.getSize(find.byType(ConsoleSelector<int>)).width;
    expect(trigger, 400); // Stretched by the parent, not by `width`.
    expect(await openAndMeasureRow(tester), greaterThanOrEqualTo(trigger));
  });

  testWidgets('explicit-width selector keeps its menu at least that wide', (
    tester,
  ) async {
    await tester.pumpWidget(host(width: 180, parentWidth: 400));
    expect(await openAndMeasureRow(tester), greaterThanOrEqualTo(180));
  });
}
