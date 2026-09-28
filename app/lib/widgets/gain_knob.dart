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

import 'dart:math';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'knob_a.dart';
import 'knob_line_painters.dart';

class GainKnob extends StatelessWidget {
  final double gainDb;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double size;

  const GainKnob({
    super.key,
    required this.gainDb,
    required this.onChanged,
    this.min = -60,
    this.max = 12,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    // Which knob is drawn is per-theme, because the themes' knobs
    // differ by how the instrument is built and not only by hue. See
    // [KnobStyle]. Every branch reads T.* here and passes the values
    // down, so a theme change reaches the painter through
    // shouldRepaint without it needing a themeMode field.
    return switch (T.knobStyle) {
      // KnobA brings its own KnobGestures, which is why it is a branch
      // here instead of a painter handed to _painted below: nesting it
      // would leave two recognisers claiming the drag.
      KnobStyle.knobA => KnobA(
        value: gainDb,
        onChanged: onChanged,
        min: min,
        max: max,
        size: size,
      ),
      KnobStyle.brushed => _painted(
        _BrushedKnobPainter(
          gainDb: gainDb,
          min: min,
          max: max,
          trackColor: T.bgDeep,
          activeColor: T.purple,
          bodyColor: T.bgHover,
          pointerColor: T.textMuted,
        ),
      ),
      KnobStyle.bar => _painted(
        BarKnobPainter(
          gainDb: gainDb,
          min: min,
          max: max,
          rimDark: T.chromeRimDark,
          rimLight: T.chromeRimLight,
          pointerColor: T.textSecondary,
          markColor: T.textTertiary,
          discColor: T.bgControls,
          bodyColor: T.borderStrong,
          labelSize: T.fontMeter,
          uiFamily: T.uiFamily,
        ),
      ),
      KnobStyle.outlined => _painted(
        OutlinedKnobPainter(
          gainDb: gainDb,
          min: min,
          max: max,
          trackColor: T.borderStrong,
          activeColor: T.purple,
          pointerColor: T.textPrimary,
          markColor: T.textSecondary,
          ringWidth: T.borderWidth,
        ),
      ),
    };
  }

  Widget _painted(CustomPainter painter) => KnobGestures(
    value: gainDb,
    onChanged: onChanged,
    min: min,
    max: max,
    size: size,
    painter: painter,
  );
}

/// The Dark theme's knob.
///
/// The accent arc is the outermost ring here, while [KnobA] colours the body
/// with the accent and keeps its fill arc inside the rim. No set of colour
/// tokens turns one into the other.
///
/// ## Geometry
///
/// Radii below are fractions of the arc radius, so they scale to any
/// [GainKnob.size]. In a 54x60 box the arc is centred at
/// (28.45, 26.42) with a radius of 18.00.
///
///   1.00        accent arc and its unfilled track, ~0.14 wide
///   0.79        rim ring, `#4C4C4C` neutral, ~0.08 wide
///   0.72        body edge
///   <= 0.72     brushed body, conic sheen brightest toward 285 degrees
///
/// Three tick diamonds sit at r 1.27, at the sweep's min, centre and
/// max. The painter draws the shared 270-degree sweep, so every knob
/// has one range and the same tick positions.
///
/// ## Colours
///
/// On the Dark ground the greys are `#4C4C4C` rim, `#35353A` body and
/// `#3D3D3D` ticks. Hard-coding them would leave the knob unreadable
/// in themes that do not share that ground, so each maps onto the
/// nearest token by role and the knob follows whatever theme selects
/// it. The accent is [T.purple],
/// which is `#AA83F6` in Dark.
class _BrushedKnobPainter extends CustomPainter {
  _BrushedKnobPainter({
    required this.gainDb,
    required this.min,
    required this.max,
    required this.trackColor,
    required this.activeColor,
    required this.bodyColor,
    required this.pointerColor,
  });

  final double gainDb;
  final double min;
  final double max;
  final Color trackColor;
  final Color activeColor;
  final Color bodyColor;
  final Color pointerColor;

  // Fractions of the arc radius, from the circle fit.
  static const double _rRim = 0.76;
  static const double _rBody = 0.70;
  static const double _rTick = 1.11;

  /// Rim, ticks and sheen are lightened off [bodyColor] by fixed ratios rather
  /// than tokened. On the Dark ground the rim is 1.4x the body and the ticks
  /// 1.1x, and a token carrying those absolute values would invert on the light
  /// theme, where the body is already near-white.
  static const Color _white = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // The ticks are the outermost element, so the arc radius is set by
    // what leaves room for them rather than by the box.
    final arcR = (size.width / 2) / _rTick;
    final frac = ((gainDb - min) / (max - min)).clamp(0.0, 1.0);
    final arcRect = Rect.fromCircle(center: center, radius: arcR);
    final arcWidth = knobAtLeast(arcR * 0.085, 1.0);

    // Unfilled track, then the accent over it.
    canvas.drawArc(
      arcRect,
      kKnobStartAngle,
      kKnobSweepAngle,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = arcWidth
        ..strokeCap = StrokeCap.round,
    );
    if (frac > 0.001) {
      canvas.drawArc(
        arcRect,
        kKnobStartAngle,
        kKnobSweepAngle * frac,
        false,
        Paint()
          ..color = activeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = arcWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    // Tick diamonds at min, centre and max.
    final tickR = arcR * _rTick;
    final tickHalf = knobAtLeast(arcR * 0.055, 0.8);
    for (final t in const [0.0, 0.5, 1.0]) {
      final a = kKnobStartAngle + kKnobSweepAngle * t;
      final c = center + Offset(cos(a) * tickR, sin(a) * tickR);
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy - tickHalf)
          ..lineTo(c.dx + tickHalf, c.dy)
          ..lineTo(c.dx, c.dy + tickHalf)
          ..lineTo(c.dx - tickHalf, c.dy)
          ..close(),
        Paint()..color = Color.lerp(bodyColor, _white, 0.10)!,
      );
    }

    // Body: a conic sheen brightest toward 285 degrees, drawn as a
    // sweep gradient rather than a flat fill so the body's luminance
    // varies with angle.
    final bodyR = arcR * _rBody;
    final bodyRect = Rect.fromCircle(center: center, radius: bodyR);
    final hi = Color.lerp(bodyColor, _white, 0.22)!;
    final lo = Color.lerp(bodyColor, const Color(0xFF000000), 0.28)!;
    canvas.drawCircle(
      center,
      bodyR,
      Paint()
        ..shader = SweepGradient(
          colors: [lo, bodyColor, hi, bodyColor, lo],
          stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
          transform: GradientRotation(285 * (pi / 180) - pi),
        ).createShader(bodyRect),
    );

    // Rim ring, inside the arc and outside the body.
    canvas.drawCircle(
      center,
      arcR * _rRim,
      Paint()
        ..color = Color.lerp(bodyColor, _white, 0.13)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = knobAtLeast(arcR * 0.075, 0.8),
    );

    // Pointer: pale, from mid-body to the body edge.
    final a = kKnobStartAngle + kKnobSweepAngle * frac;
    canvas.drawLine(
      center + Offset(cos(a) * bodyR * 0.47, sin(a) * bodyR * 0.47),
      center + Offset(cos(a) * bodyR * 1.00, sin(a) * bodyR * 1.00),
      Paint()
        ..color = pointerColor
        ..strokeWidth = knobAtLeast(arcR * 0.06, 1.0)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_BrushedKnobPainter old) =>
      gainDb != old.gainDb ||
      min != old.min ||
      max != old.max ||
      trackColor != old.trackColor ||
      activeColor != old.activeColor ||
      bodyColor != old.bodyColor ||
      pointerColor != old.pointerColor;
}
