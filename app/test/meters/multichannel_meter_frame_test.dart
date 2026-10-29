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

// The multichannel meter's rounded frame keeps its corners (ES-931). The
// painter used to fill its whole square rect, which painted over the
// border's rounded corners and, at 1x, half of every straight-edge
// pixel. The meter goldens pin the result at 1x; this test samples the
// corner at 4x, where the arc spans enough pixels to check inside and
// outside it.

import 'dart:math' show sqrt2;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_matrix.dart';

/// Pixels per logical pixel in the capture.
const double _kScale = 4;

/// RGBA bytes of the capture and its width in pixels.
typedef _Raster = (ByteData, int);

Future<_Raster> _capture(WidgetTester tester, AppThemeMode theme) async {
  final subject = await pumpGoldenSubject(
    tester,
    () => MultichannelMeter(levels: List.filled(12, 0.5)),
    size: const Size(200, 160),
    theme: theme,
    font: FontSizeMode.medium,
  );
  final boundary = tester.renderObject(subject) as RenderRepaintBoundary;
  // toImage and toByteData are engine futures that the fake-async zone
  // of testWidgets never completes; runAsync hands them the real loop.
  late final _Raster raster;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _kScale);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    raster = (data!, image.width);
    image.dispose();
  });
  return raster;
}

/// RGBA at physical pixel (x, y).
List<int> _pixel(_Raster raster, int x, int y) {
  final (data, width) = raster;
  final i = (y * width + x) * 4;
  return [for (var c = 0; c < 4; c++) data.getUint8(i + c)];
}

/// Squared RGB distance between a pixel and a colour.
int _distance2(List<int> rgba, Color c) {
  final dr = rgba[0] - (c.r * 255).round();
  final dg = rgba[1] - (c.g * 255).round();
  final db = rgba[2] - (c.b * 255).round();
  return dr * dr + dg * dg + db * db;
}

void main() {
  for (final mode in AppThemeMode.values) {
    testWidgets('the frame keeps its rounded corners, theme ${mode.name}', (
      tester,
    ) async {
      final raster = await _capture(tester, mode);
      final r = T.radiusSm;

      // Top-left corner, outside the rounded rect: nothing is painted.
      final outside = _pixel(raster, 2, 2);
      expect(
        outside[3],
        lessThan(8),
        reason: 'the corner outside the frame is filled: $outside',
      );

      // On the 45° diagonal, around the middle of the border band: at
      // least one of three neighbouring opaque pixels is nearer the
      // border colour than the control ground, so a one-pixel shift in
      // the rasteriser does not flip the result. Without the frame's
      // corners all three are the control ground.
      final onArc = ((r - (r - 0.25) / sqrt2) * _kScale).floor();
      final arc = [
        for (var d = onArc - 1; d <= onArc + 1; d++) _pixel(raster, d, d),
      ];
      expect(
        arc.any(
          (p) =>
              p[3] > 200 &&
              _distance2(p, T.border) < _distance2(p, T.bgControls),
        ),
        isTrue,
        reason: 'the border arc is covered around ($onArc, $onArc): $arc',
      );
    });
  }
}
