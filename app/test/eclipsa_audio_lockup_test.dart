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

import 'package:eclipsa_studio/eclipsa_audio_palette.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/eclipsa_audio_lockup.dart';
import 'package:eclipsa_studio/widgets/eclipsa_audio_wordmark_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The lockup's contract is the brand's geometry: the symbol's
// 356 x 324 box, the wordmark's cap height and position relative to it,
// and the fixed greys of each colourway. The geometry is checked from
// the paths; the colours by rasterising through Skia and reading
// pixels back, as eclipsa_studio_mark_render_test.dart does.

/// One rasterised widget, addressable by pixel.
class _Raster {
  _Raster(this.pixels, this.width);

  final ByteData pixels;
  final int width;

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

Future<_Raster> _rasterise(
  WidgetTester tester,
  Widget child, {
  required Color background,
  required Size size,
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
              width: size.width,
              height: size.height,
              alignment: Alignment.topLeft,
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
  // unless it happens inside runAsync, which hands control back to
  // the real event loop.
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
  tearDown(() => T.setMode(T.defaultMode));

  group('geometry', () {
    test('the symbol fills its 356 x 324 box', () {
      final bounds = EclipsaAudioGeometry.outer.getBounds().expandToInclude(
        EclipsaAudioGeometry.inner.getBounds(),
      );
      expect(bounds.left, closeTo(0, 0.01));
      expect(bounds.top, closeTo(0, 0.01));
      expect(bounds.right, closeTo(EclipsaAudioGeometry.boxWidth, 0.01));
      expect(bounds.bottom, closeTo(EclipsaAudioGeometry.boxHeight, 0.01));
    });

    test('the two halves stop short of the centre line', () {
      // The outer shapes' tips sit 4 px either side of the centre;
      // nothing crosses it, so the halves read as two forms.
      final centre = EclipsaAudioGeometry.boxWidth / 2;
      for (var y = 0.0; y <= EclipsaAudioGeometry.boxHeight; y += 4) {
        expect(
          EclipsaAudioGeometry.outer.contains(Offset(centre, y)),
          isFalse,
          reason: 'outer shape crosses the centre line at y=$y',
        );
        expect(
          EclipsaAudioGeometry.inner.contains(Offset(centre, y)),
          isFalse,
          reason: 'inner shape crosses the centre line at y=$y',
        );
      }
    });

    test('the core is where an outer and an inner shape overlap', () {
      // A point inside both shapes of the left half, and one inside the
      // inner shape alone near its top.
      const both = Offset(120, 162);
      const innerOnly = Offset(96, 20);
      expect(EclipsaAudioGeometry.core.contains(both), isTrue);
      expect(EclipsaAudioGeometry.core.contains(innerOnly), isFalse);
      expect(EclipsaAudioGeometry.inner.contains(innerOnly), isTrue);
    });

    test('the wordmark stands on the baseline at the cap height', () {
      final bounds = EclipsaAudioGeometry.wordmark.getBounds();
      // The E's top is the cap height above the baseline; the p's
      // descender and the i's dot reach past the cap band.
      const cap = kEclipsaAudioCapHeight * EclipsaAudioGeometry.unitsScale;
      expect(cap, closeTo(190, 0.01));
      expect(
        bounds.top,
        lessThanOrEqualTo(EclipsaAudioGeometry.baseline - cap),
      );
      expect(bounds.bottom, greaterThan(EclipsaAudioGeometry.baseline));
      // The E's left edge, 503 px from the symbol's left edge in the
      // brand's lockup.
      expect(bounds.left, closeTo(503, 1.5));
      expect(bounds.right, closeTo(EclipsaAudioGeometry.lockupWidth, 0.01));
    });

    test('every glyph outline is well formed', () {
      for (final glyph in kEclipsaAudioGlyphs) {
        final o = glyph.outline;
        var i = 0;
        var open = false;
        var contours = 0;
        while (i < o.length) {
          switch (o[i]) {
            case 0:
              expect(open, isFalse, reason: '${glyph.char}: move inside');
              open = true;
              i += 3;
            case 1:
              expect(open, isTrue, reason: '${glyph.char}: line outside');
              i += 3;
            case 2:
              expect(open, isTrue, reason: '${glyph.char}: curve outside');
              i += 5;
            case 3:
              expect(open, isTrue, reason: '${glyph.char}: close outside');
              open = false;
              contours++;
              i += 1;
            default:
              fail('${glyph.char}: bad record ${o[i]}');
          }
        }
        expect(open, isFalse, reason: '${glyph.char}: unclosed contour');
        expect(contours, greaterThan(0), reason: '${glyph.char}: empty');
      }
      expect(kEclipsaAudioGlyphs.map((g) => g.char).join(), 'EclipsaAudio');
    });
  });

  group('widgets', () {
    testWidgets('the symbol and the lockup take the artwork\'s aspect', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Column(
              children: [
                EclipsaAudioSymbol(size: 48),
                EclipsaAudioLockup(height: 48),
              ],
            ),
          ),
        ),
      );
      final symbol = tester.getSize(find.byType(EclipsaAudioSymbol));
      expect(symbol.height, 48);
      expect(symbol.width, closeTo(48 * 356 / 324, 1e-9));
      final lockup = tester.getSize(find.byType(EclipsaAudioLockup));
      expect(lockup.height, 48);
      expect(
        lockup.width,
        closeTo(48 * EclipsaAudioGeometry.lockupAspect, 1e-9),
      );
    });

    test('the colourway follows the ground', () {
      expect(
        EclipsaAudioColorway.forGround(Colors.white),
        EclipsaAudioColorway.positive,
      );
      expect(
        EclipsaAudioColorway.forGround(Colors.black),
        EclipsaAudioColorway.reverse,
      );
      // Light is the one theme whose ground takes the positive
      // colourway; every dark and high-contrast theme takes reverse.
      for (final mode in AppThemeMode.values) {
        final light = kThemeMeta[mode]!.role == AppThemeRole.light;
        expect(
          EclipsaAudioColorway.forGround(T.themeFor(mode).bgBase),
          light ? EclipsaAudioColorway.positive : EclipsaAudioColorway.reverse,
          reason: '${mode.name} has a ${light ? 'light' : 'dark'} ground',
        );
      }
    });

    // A quarter of the artwork's size, so the lockup fits the 800 px
    // test view; the sample points are the artwork's coordinates over
    // four, each well inside its region.
    const quarter = EclipsaAudioGeometry.boxHeight / 4;
    const rasterSize = Size(500, quarter);

    testWidgets('positive draws the brand greys and a black core', (
      tester,
    ) async {
      final raster = await _rasterise(
        tester,
        const EclipsaAudioLockup(
          height: quarter,
          colorway: EclipsaAudioColorway.positive,
        ),
        background: Colors.white,
        size: rasterSize,
      );
      expect(raster.at(30, 40), EclipsaAudioPalette.black); // core
      expect(raster.at(5, 40), EclipsaAudioPalette.grey400); // outer
      expect(raster.at(24, 5), EclipsaAudioPalette.grey500); // inner
      expect(raster.at(59, 40), EclipsaAudioPalette.black); // right core
      // The E's stem, 503..525 artwork px from the symbol's left edge.
      expect(raster.at(128, 50), EclipsaAudioPalette.black);
      expect(raster.at(44, 40), Colors.white); // the gap between halves
    });

    testWidgets('reverse draws a white core and Grey 600 outer shapes', (
      tester,
    ) async {
      final raster = await _rasterise(
        tester,
        const EclipsaAudioLockup(
          height: quarter,
          colorway: EclipsaAudioColorway.reverse,
        ),
        background: Colors.black,
        size: rasterSize,
      );
      expect(raster.at(30, 40), EclipsaAudioPalette.white);
      expect(raster.at(5, 40), EclipsaAudioPalette.grey600);
      expect(raster.at(24, 5), EclipsaAudioPalette.grey500);
      expect(raster.at(128, 50), EclipsaAudioPalette.white);
    });
  });
}
