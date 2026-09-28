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

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/eclipsa_studio_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contrast.dart';

// Rasterises the mark through Skia and reads the pixels back. No
// display and no golden file: `flutter test` renders headless, and
// RenderRepaintBoundary.toImage gives the real output rather than a
// list of draw calls. What this guards is the widget's colour
// plumbing — that the inks each theme names, and the chrome ink on
// the bar, are what reaches the canvas — which no call recorder sees.
// The geometry is checked by eclipsa_studio_mark_asset_test.dart.

/// One rasterised mark, addressable by pixel.
class _Raster {
  _Raster(this.pixels, this.width);

  final ByteData pixels;
  final int width;

  /// The pixel at ([x], [y]) as an opaque colour.
  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      255,
      pixels.getUint8(i),
      pixels.getUint8(i + 1),
      pixels.getUint8(i + 2),
    );
  }
}

/// Paints [child] on [background] at 1 device pixel per logical pixel
/// and reads the result back.
Future<_Raster> _rasterise(
  WidgetTester tester,
  Widget child, {
  required Color background,
  required double size,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: Container(
              color: background,
              width: size,
              height: size,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // toImage and toByteData are engine futures. testWidgets runs in a
  // fake-async zone that never completes them, so the await hangs
  // until the 10-minute test timeout unless it happens inside
  // runAsync, which hands control back to the real event loop.
  late final _Raster raster;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    raster = _Raster(data!, image.width);
    image.dispose();
  });
  return raster;
}

void main() {
  const size = EclipsaStudioMark.kMarkLarge;

  /// The pixel holding the centre of the cell at ([row], [col]) on
  /// [face] when the mark is drawn at 58 px. A cell's ellipse is at
  /// least 2 px wide and 2.5 px tall there, so that pixel is fully
  /// covered.
  ({int x, int y}) cell(MarkFace face, int row, int col) {
    final c = markCellCentre(face, row, col, size);
    return (x: c.dx.floor(), y: c.dy.floor());
  }

  // The E's top-left cell and the S's top-right cell.
  final eCell = cell(MarkFace.left, 0, 0);
  final sCell = cell(MarkFace.right, 0, 4);

  // T.setMode mutates a static. Every other suite that touches it puts
  // the default back so the next file does not inherit whichever theme
  // this one finished on.
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('on the chrome bar the E half takes chromeInk', (tester) async {
    // textPrimary is chosen against bgBase, and the chrome bar has a
    // ground of its own. onChrome swaps the ink for the one the theme
    // puts on that bar, chromeInk, which contrast.json gates against
    // chromeBg.
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      final theme = T.themeFor(mode);
      final r = await _rasterise(
        tester,
        const EclipsaStudioMark(size: size, onChrome: true),
        background: theme.chromeBg,
        size: size,
      );
      expect(
        r.at(eCell.x, eCell.y),
        theme.chromeInk,
        reason: '${mode.name} E on chrome',
      );
      expect(
        r.at(sCell.x, sCell.y),
        theme.pink,
        reason: '${mode.name} S on chrome',
      );
      // The body ink would be the bug this guards: nothing gates it
      // against the bar's ground.
      expect(
        contrastRatio(theme.chromeInk, theme.chromeBg),
        greaterThanOrEqualTo(4.5),
        reason: '${mode.name} chrome ink must read on its own bar',
      );
    }
  });

  testWidgets('every theme renders its own pair', (tester) async {
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      final theme = T.themeFor(mode);
      final r = await _rasterise(
        tester,
        const EclipsaStudioMark(size: size),
        background: theme.bgBase,
        size: size,
      );
      expect(
        r.at(eCell.x, eCell.y),
        theme.textPrimary,
        reason: '${mode.name} E',
      );
      expect(r.at(sCell.x, sCell.y), theme.pink, reason: '${mode.name} S');
      // The two halves must not collapse to the same colour, which is
      // what the mark's whole E/S division rests on.
      expect(
        theme.textPrimary,
        isNot(theme.pink),
        reason: '${mode.name} names one colour for both halves',
      );
    }
  });
}
