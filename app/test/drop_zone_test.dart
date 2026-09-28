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
import 'package:eclipsa_studio/widgets/drop_zone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the area zone follows a theme switch without a remount', (
    tester,
  ) async {
    // The flat well is what the slot drew before the remake: bgDeep in
    // a 1.5 px border at radiusSm, textGhost glyph and text, 80 px tall in
    // every theme, because a component's size does not vary by theme,
    // only how it is drawn and coloured. The Dark theme is a bgElevated
    // band with a purple glyph; the Light theme a bgSurface
    // panel at radius 8 with a chromeTabOn glyph and textTertiary text.
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  SizedBox(
                    width: 600,
                    height: DropZone.areaHeight,
                    child: DropZone(
                      variant: DropZoneVariant.area,
                      icon: Icons.audio_file_outlined,
                      primaryLabel: 'Drop',
                      secondaryLabel: 'WAV',
                      isDragOver: false,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    BoxDecoration deco() =>
        tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration!
            as BoxDecoration;
    Color glyph() =>
        tester.widget<Icon>(find.byIcon(Icons.audio_file_outlined)).color!;
    Color label() => tester.widget<Text>(find.text('Drop')).style!.color!;
    double height() => tester.getSize(find.byType(DropZone)).height;

    // Classic since the 2026-09 remake: the flat well on bgControls
    // with textTertiary glyph and label.
    expect(height(), 80);
    expect(deco().color, T.bgControls);
    expect(deco().borderRadius, BorderRadius.circular(T.radiusSm));
    expect(deco().border, Border.all(color: T.border, width: 1.5));
    expect(glyph(), T.textTertiary);
    expect(label(), T.textTertiary);

    T.setMode(AppThemeMode.dark);
    rebuild(() {});
    await tester.pump(const Duration(milliseconds: 200));
    expect(height(), 80);
    expect(deco().color, T.bgElevated);
    expect(deco().borderRadius, isNull);
    expect(glyph(), T.purple);
    expect(label(), T.textGhost);

    T.setMode(AppThemeMode.light);
    rebuild(() {});
    await tester.pump(const Duration(milliseconds: 200));
    expect(height(), 80);
    expect(deco().color, T.bgSurface);
    expect(deco().borderRadius, BorderRadius.circular(8));
    expect(deco().border, isNull);
    expect(glyph(), T.chromeTabOn);
    expect(label(), T.textTertiary);
  });

  testWidgets('the Dark theme draws its bevel as overlays, not a border', (
    tester,
  ) async {
    // The decoration lerps from the flat one on a theme switch, and a
    // radius cannot lerp against non-uniform sides, so the beveled
    // decoration carries no border at rest and the two lines are
    // Stack overlays; a drag over it swaps them for a uniform ring.
    T.setMode(AppThemeMode.dark);
    Future<void> pumpZone(bool dragOver) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: DropZone.areaHeight,
            child: DropZone(
              variant: DropZoneVariant.area,
              icon: Icons.audio_file_outlined,
              primaryLabel: 'Drop',
              isDragOver: dragOver,
            ),
          ),
        ),
      ),
    );
    BoxDecoration deco() =>
        tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration!
            as BoxDecoration;
    Iterable<Color?> lineColors() => tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.constraints?.maxHeight == 1)
        .map((c) => c.color);

    await pumpZone(false);
    expect(deco().border, isNull);
    expect(deco().borderRadius, isNull);
    expect(lineColors(), [const Color(0x33FFFFFF), const Color(0x94000000)]);

    await pumpZone(true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(deco().border, Border.all(color: T.purple, width: 1));
    expect(deco().color, T.purpleDim);
    expect(lineColors(), isEmpty);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.audio_file_outlined)).color,
      T.purple,
    );
  });

  testWidgets('a drag tints every style with the accent', (tester) async {
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: DropZone.areaHeight,
              child: DropZone(
                variant: DropZoneVariant.area,
                icon: Icons.audio_file_outlined,
                primaryLabel: 'Drop',
                isDragOver: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final deco =
          tester
                  .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                  .decoration!
              as BoxDecoration;
      expect(deco.color, T.purpleDim, reason: mode.name);
      expect(
        tester.widget<Text>(find.text('Drop')).style!.color,
        T.purple,
        reason: mode.name,
      );
    }
  });
}
