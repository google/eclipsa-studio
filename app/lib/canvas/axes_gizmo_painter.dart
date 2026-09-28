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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Corner overlay showing 3 labeled axis lines that rotate with the
/// camera.  Takes the upper-left 3x3 of the camera view matrix
/// (column-major, 9 floats) and a display [size].
///
/// Axis convention (user-facing):
///   X (red)   = right   — three.js world (1, 0, 0)
///   Y (green) = front   — three.js world (0, 0, -1)
///   Z (blue)  = up      — three.js world (0, 1, 0)
class AxesGizmo extends StatelessWidget {
  final ValueNotifier<List<double>> cameraRotation;
  final double size;

  const AxesGizmo({super.key, required this.cameraRotation, this.size = 56});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<double>>(
      valueListenable: cameraRotation,
      builder: (_, rotation, _) {
        return CustomPaint(
          size: Size.square(size),
          painter: _AxesGizmoPainter(rotation, size, T.fontMode, T.mode),
        );
      },
    );
  }
}

class _AxesGizmoPainter extends CustomPainter {
  final List<double> _rot;
  final double _size;
  final FontSizeMode _fontMode;
  final AppThemeMode _themeMode;

  _AxesGizmoPainter(this._rot, this._size, this._fontMode, this._themeMode);

  @override
  void paint(Canvas canvas, Size size) {
    if (_rot.length < 9) return;

    final center = Offset(size.width / 2, size.height / 2);
    final axisLen = _size * 0.36;

    // Dark background scrim — always a dark tint regardless of theme
    // so the gizmo stays readable on light scenes too. Opacity varies
    // slightly between themes via [T.gizmoBg].
    canvas.drawCircle(center, _size * 0.46, Paint()..color = T.gizmoBg);

    // Axis directions in three.js world space, with theme-aware colors.
    // (world x, world y, world z, label, color)
    final axes = <(double, double, double, String, Color)>[
      (1.0, 0.0, 0.0, 'X', T.axisX),
      (0.0, 0.0, -1.0, 'Y', T.axisY),
      (0.0, 1.0, 0.0, 'Z', T.axisZ),
    ];

    // Transform each axis and collect for depth-sorting.
    final projected = <(double, double, double, String, Color)>[];
    for (final (wx, wy, wz, label, color) in axes) {
      // Multiply 3x3 view rotation * world axis.
      // Column-major: m[0..2] = col0, m[3..5] = col1, m[6..8] = col2.
      final cx = _rot[0] * wx + _rot[3] * wy + _rot[6] * wz;
      final cy = _rot[1] * wx + _rot[4] * wy + _rot[7] * wz;
      final cz = _rot[2] * wx + _rot[5] * wy + _rot[8] * wz;
      // screen: x right, y up → flip y for Flutter.
      projected.add((cx * axisLen, -cy * axisLen, cz, label, color));
    }

    // Sort back-to-front (largest camera-Z first = furthest).
    projected.sort((a, b) => b.$3.compareTo(a.$3));

    final linePaint = Paint()
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    for (final (sx, sy, _, label, color) in projected) {
      final end = center + Offset(sx, sy);

      // Line
      linePaint.color = color;
      canvas.drawLine(center, end, linePaint);

      // Endpoint dot
      canvas.drawCircle(end, 2.5, Paint()..color = color);

      // Label slightly beyond endpoint.
      final dir = Offset(sx, sy);
      final len = dir.distance;
      final labelOffset = len > 0 ? center + dir * ((len + 9) / len) : end;
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: T.fontCaption,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, labelOffset - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_AxesGizmoPainter old) =>
      !listEquals(old._rot, _rot) ||
      old._fontMode != _fontMode ||
      old._themeMode != _themeMode;
}
