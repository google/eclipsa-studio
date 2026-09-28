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

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../ffi_bridge.dart';
import 'colormap.dart';
import 'native_sh_decoder.dart';
import 'sh_decode_helper.dart';
import 'sh_utils.dart';

/// Mollweide equal-area projection of the ambisonic soundfield.
///
/// Uses colormap LUT for fast bulk coloring and caches the
/// rendered picture to avoid redundant draw calls on throttled
/// frames.
class MollweidePainter extends CustomPainter {
  final List<double> shCoeffs;
  final int order;
  final Colormap colormap;
  final ShDirectivity directivity;
  final EclipsaStudioEngine? engine;
  final int gridW;
  final int gridH;

  /// EMA coefficient shared with the icosahedron decode path so the
  /// two soundfield views smooth identically.
  static const double _smooth = ShDecodeHelper.smoothing;

  /// Previous smoothed energies (reused across frames).
  static Float32List _prevValues = Float32List(0);

  /// Cached native SH decoder for the Mollweide grid.
  /// NOTE: single-instance assumption — only one Mollweide
  /// overlay may exist at a time.
  static NativeShDecoder? _molDecoder;
  static EclipsaStudioEngine? _molEngine;
  static int _molW = -1;
  static int _molH = -1;
  static int _molOrder = -1;
  static ShDirectivity _molDir = ShDirectivity.inPhase;

  /// Timestamp of last decode (for 30 Hz throttle).
  static int _lastDecodeMs = 0;

  // Deliberately off-palette: the projection is drawn on a permanent
  // dark scrim regardless of app theme, so these overlay strokes stay
  // fixed white-alpha rather than tracking T.* tokens.
  static const Color _outlineColor = Color(0x40FFFFFF);
  static const Color _frontMarkerColor = Color(0x80FFFFFF);

  /// Cached rendered picture from previous frame.
  static ui.Picture? _cachedPicture;
  static Size _cachedSize = Size.zero;

  const MollweidePainter({
    required this.shCoeffs,
    required this.order,
    required this.colormap,
    this.directivity = ShDirectivity.inPhase,
    this.engine,
    this.gridW = 96,
    this.gridH = 48,
  });

  /// Build grid directions as (az, el) pairs.
  static List<(double, double)> _gridDirections(int w, int h) {
    final dirs = <(double, double)>[];
    for (var j = 0; j < h; j++) {
      final elDeg = 90.0 - (j + 0.5) / h * 180.0;
      final elRad = elDeg * math.pi / 180;
      for (var i = 0; i < w; i++) {
        final azDeg = (i + 0.5) / w * 360.0 - 180.0;
        final azRad = -azDeg * math.pi / 180;
        dirs.add((azRad, elRad));
      }
    }
    return dirs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (shCoeffs.isEmpty) return;

    // Build / reuse native SH decoder.
    if (_molDecoder == null ||
        _molW != gridW ||
        _molH != gridH ||
        _molOrder != order ||
        _molDir != directivity ||
        _molEngine != engine) {
      _molDecoder?.dispose();
      final eng = engine;
      _molDecoder = eng != null && eng.hasShDecode
          ? NativeShDecoder(
              engine: eng,
              directions: _gridDirections(gridW, gridH),
              order: order,
              directivity: directivity,
            )
          : null;
      _molEngine = engine;
      _molW = gridW;
      _molH = gridH;
      _molOrder = order;
      _molDir = directivity;
    }

    // 30 Hz throttle — reuse cached picture if recent enough.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final shouldDecode = nowMs - _lastDecodeMs >= 33;

    if (!shouldDecode && _cachedPicture != null && _cachedSize == size) {
      canvas.drawPicture(_cachedPicture!);
      return;
    }

    if (shouldDecode) {
      _lastDecodeMs = nowMs;

      // Decode → linear energy per cell.
      final Float32List raw;
      if (_molDecoder != null && _molDecoder!.isValid) {
        raw = _molDecoder!.decode(shCoeffs);
      } else {
        raw = Float32List(gridW * gridH);
      }

      // EMA smoothing (in-place, f32).
      final n = gridW * gridH;
      if (_prevValues.length != n) {
        _prevValues = Float32List(n);
      }
      for (var k = 0; k < n; k++) {
        _prevValues[k] = _smooth * raw[k] + (1 - _smooth) * _prevValues[k];
      }
    }

    // Record into a Picture for caching.
    final recorder = ui.PictureRecorder();
    final rec = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));
    _paintMollweide(rec, size);
    _cachedPicture?.dispose();
    _cachedPicture = recorder.endRecording();
    _cachedSize = size;

    canvas.drawPicture(_cachedPicture!);
  }

  void _paintMollweide(Canvas canvas, Size size) {
    final cellW = size.width / gridW;
    final cellH = size.height / gridH;
    final paint = Paint();

    final ellipseRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.9,
      height: size.height * 0.9,
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(ellipseRect));

    // Use LUT for fast color lookup — no Color.lerp per cell.
    final lut = colormap.lut;
    final floorDb = Colormap.defaultFloorDb;
    final invFloor = 1.0 / -floorDb;
    final ln10inv = 10.0 / math.ln10;

    for (var j = 0; j < gridH; j++) {
      final elNorm = (j + 0.5) / gridH;
      final theta = _mollweideTheta((0.5 - elNorm) * math.pi);
      final cosTheta = math.cos(theta);
      final sinTheta = math.sin(theta);

      for (var i = 0; i < gridW; i++) {
        final azNorm = (i + 0.5) / gridW;
        final lambda = (azNorm - 0.5) * 2 * math.pi;

        final mx = lambda * cosTheta / math.pi;
        final my = sinTheta;

        if (mx * mx + my * my > 1.1) continue;

        final energy = _prevValues[j * gridW + i];
        int argb = 0x00000000;
        if (energy > 0 && energy.isFinite) {
          final db = (ln10inv * math.log(energy)).clamp(floorDb, 0.0);
          if (db > floorDb) {
            final t = ((db - floorDb) * invFloor).clamp(0.0, 1.0);
            argb = lut[(t * 255).round().clamp(0, 255)];
          }
        }
        if (argb == 0x00000000) continue;

        final px = (0.5 + mx * 0.45) * size.width;
        final py = (0.5 - my * 0.45) * size.height;

        paint.color = Color(argb);
        canvas.drawRect(
          Rect.fromLTWH(px - cellW / 2, py - cellH / 2, cellW + 1, cellH + 1),
          paint,
        );
      }
    }

    canvas.restore();

    // Ellipse outline
    paint
      ..color = _outlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    canvas.drawOval(ellipseRect, paint);

    // Front marker
    paint
      ..color = _frontMarkerColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 2, paint);
  }

  static double _mollweideTheta(double phi) {
    if (phi.abs() > math.pi / 2 - 0.001) return phi;
    var theta = phi;
    for (var i = 0; i < 10; i++) {
      final delta =
          -(2 * theta + math.sin(2 * theta) - math.pi * math.sin(phi)) /
          (2 + 2 * math.cos(2 * theta));
      theta += delta;
      if (delta.abs() < 1e-6) break;
    }
    return theta;
  }

  @override
  bool shouldRepaint(MollweidePainter old) =>
      old.order != order ||
      old.colormap != colormap ||
      old.directivity != directivity ||
      old.engine != engine ||
      old.gridW != gridW ||
      old.gridH != gridH ||
      !listEquals(old.shCoeffs, shCoeffs);
}
