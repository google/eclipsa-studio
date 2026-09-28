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
import 'package:eclipsa_studio/widgets/eclipsa_studio_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contrast.dart';

// The geometry itself is checked by eclipsa_studio_mark_asset_test.dart,
// which compares the painter with the generated master cell for cell.
// What is left to guard here is the widget's contract: that the unlit
// top face can be dropped, that the cube stays inside its box at both
// documented sizes, that every cell is a circle, that the painter
// repaints when a theme switch changes its inks, and that every theme
// names a pair the mark can use.

/// Records the circles a painter draws, in face space, and any
/// rectangles, which the mark must not draw.
class _Recorder implements Canvas {
  final List<({Offset centre, double radius, Color color})> circles = [];
  final List<Rect> rects = [];

  @override
  void drawCircle(Offset c, double r, Paint paint) =>
      circles.add((centre: c, radius: r, color: paint.color));

  @override
  void drawRect(Rect rect, Paint paint) => rects.add(rect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<({Offset centre, double radius, Color color})> paintMark({
  required double size,
  Color ink = const Color(0xFFE0E4EC),
  Color accent = const Color(0xFFE06090),
  bool showUnlitCells = true,
}) {
  final canvas = _Recorder();
  CubeMarkPainter(
    ink: ink,
    accent: accent,
    showUnlitCells: showUnlitCells,
  ).paint(canvas, Size.square(size));
  return canvas.circles;
}

void main() {
  group('mark geometry', () {
    test('showUnlitCells: false drops the top face', () {
      final all = paintMark(size: 58);
      final lit = paintMark(size: 58, showUnlitCells: false);
      // The field is the fixed grey; the letters are the two inks.
      // Paint.color round-trips through floats, so compare packed values.
      bool field(({Offset centre, Color color, double radius}) c) =>
          c.color.toARGB32() == kFieldColor.toARGB32();
      expect(all.where(field).length, 25);
      expect(lit.any(field), isFalse);
      expect(lit.length, all.length - 25);
    });

    test('both documented sizes keep the cube inside its box', () {
      expect(EclipsaStudioMark.kMarkSmall, 31);
      expect(EclipsaStudioMark.kMarkLarge, 58);
      for (final size in [
        EclipsaStudioMark.kMarkSmall,
        EclipsaStudioMark.kMarkLarge,
      ]) {
        for (final face in MarkFace.values) {
          final extent = markCellExtent(face, size);
          for (var row = 0; row < 5; row++) {
            for (var col = 0; col < 5; col++) {
              final c = markCellCentre(face, row, col, size);
              expect(c.dx - extent.width, greaterThanOrEqualTo(0));
              expect(c.dx + extent.width, lessThanOrEqualTo(size));
              expect(c.dy - extent.height, greaterThanOrEqualTo(0));
              expect(c.dy + extent.height, lessThanOrEqualTo(size));
            }
          }
        }
      }
    });
  });

  group('theme binding', () {
    test('every theme names a mark pair, and the accent clears 3:1', () {
      for (final mode in AppThemeMode.values) {
        final t = T.themeFor(mode);
        final ratio = contrastRatio(t.pink, t.bgBase);
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason: '${mode.name} pink on bgBase is $ratio',
        );
        expect(
          contrastRatio(t.textPrimary, t.bgBase),
          greaterThanOrEqualTo(4.5),
          reason: '${mode.name} textPrimary on bgBase',
        );
      }
    });

    test('every cell is a circle, 58 of them', () {
      // One geometry in every theme: no theme draws the cells as
      // anything but circles.
      final r = _Recorder();
      const CubeMarkPainter(
        ink: Color(0xFFFFFFFF),
        accent: Color(0xFFFF7AB8),
      ).paint(r, const Size.square(58));
      expect(r.rects, isEmpty);
      expect(r.circles.length, 58);
    });

    test('the painter repaints when the inks change', () {
      const a = CubeMarkPainter(
        ink: Color(0xFFE0E4EC),
        accent: Color(0xFFE06090),
      );
      expect(a.shouldRepaint(a), isFalse);
      expect(
        a.shouldRepaint(
          const CubeMarkPainter(
            ink: Color(0xFF1A1A2E),
            accent: Color(0xFFE06090),
          ),
        ),
        isTrue,
      );
      expect(
        a.shouldRepaint(
          const CubeMarkPainter(
            ink: Color(0xFFE0E4EC),
            accent: Color(0xFFE06090),
            showUnlitCells: false,
          ),
        ),
        isTrue,
      );
    });
  });
}
