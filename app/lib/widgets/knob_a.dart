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
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License.

import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'knob_line_painters.dart';

/// A ring knob with an accent body, 45x45 by default: a raised accent
/// disc inside a fill arc, a darkened rim that carries the empty track,
/// and three tick diamonds at the ends and centre of the sweep.
///
/// This is the knob the Light theme draws: [GainKnob] delegates to it
/// when `T.knobStyle` is [KnobStyle.knobA], so it is reached through
/// the same control as every other knob rather than being placed by
/// hand.
///
/// ## How it is built
///
/// Radii below are fractions of the half-size, normalised so the tick
/// diamonds, the outermost element, sit inside the box.
///
///   r .87 – .98   three tick diamonds at min, centre and max
///   r .79 – .87   rim, darkened by [T.bgBase] at 32% — the empty track
///   r .66 – .79   the fill arc, swept from min to the value
///   r <= .66      body: shadow stack, accent disc, glare, pointer
///
/// Sweep is 270 degrees from 225 (lower left, 7:30) clockwise to 135
/// (lower right, 4:30), leaving the gap at the bottom: the
/// [kKnobStartAngle] and [kKnobSweepAngle] every knob shares.
///
/// ## Colours
///
/// The rim, fill and body take the accent, [T.purple]: `#7C4DFF` in
/// Classic, `#AA83F6` in Dark, `#C4A0FF` in High Contrast and `#3D66B0`
/// in Light. The glare is derived from the accent. The rim darkener is
/// `bgBase` (`#101010` in Dark) and the ticks are `border` at 32%.
class KnobA extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double size;

  const KnobA({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = -60,
    this.max = 12,
    this.size = 45,
  });

  @override
  Widget build(BuildContext context) {
    final accent = T.purple;
    return KnobGestures(
      value: value,
      onChanged: onChanged,
      min: min,
      max: max,
      size: size,
      // T.* is read here and passed down, so a theme switch changes
      // the constructor arguments and shouldRepaint sees it without
      // the painter needing a themeMode field.
      painter: _KnobAPainter(
        value: value,
        min: min,
        max: max,
        accent: accent,
        rimShade: T.bgBase,
        tick: T.border,
        bodyStroke: T.borderStrong,
        pointer: T.bgDeep,
        shadow: T.bgDeep,
        glareLight: Color.lerp(accent, Colors.white, 0.25)!,
        glareDark: Color.lerp(accent, Colors.black, 0.26)!,
      ),
    );
  }
}

/// A [size] square that paints [painter] and carries the drag and
/// double-tap every knob in the app shares. [KnobA] draws through it,
/// and `GainKnob` wraps each of its painted knobs in it.
///
/// Dragging up raises the value by 0.3 per logical pixel, rounded to
/// 0.1. The accumulator is clamped to [min] and [max], so a drag that
/// overshoots a limit and reverses moves the value at once. A
/// double-tap sets the value to 0.
class KnobGestures extends StatefulWidget {
  const KnobGestures({
    super.key,
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    required this.size,
    required this.painter,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double size;
  final CustomPainter painter;

  @override
  State<KnobGestures> createState() => _KnobGesturesState();
}

class _KnobGesturesState extends State<KnobGestures> {
  double _dragAccum = 0;

  void _onDragStart(DragStartDetails _) {
    _dragAccum = widget.value;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragAccum = (_dragAccum - details.delta.dy * 0.3).clamp(
      widget.min,
      widget.max,
    );
    final rounded = (_dragAccum * 10).round() / 10;
    if (rounded != widget.value) widget.onChanged(rounded);
  }

  void _onDoubleTap() {
    if (widget.value != 0) widget.onChanged(0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onVerticalDragStart: _onDragStart,
    onVerticalDragUpdate: _onDragUpdate,
    onDoubleTap: _onDoubleTap,
    child: SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(painter: widget.painter),
    ),
  );
}

class _KnobAPainter extends CustomPainter {
  final double value;
  final double min;
  final double max;
  final Color accent;
  final Color rimShade;
  final Color tick;
  final Color bodyStroke;
  final Color pointer;
  final Color shadow;
  final Color glareLight;
  final Color glareDark;

  _KnobAPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.accent,
    required this.rimShade,
    required this.tick,
    required this.bodyStroke,
    required this.pointer,
    required this.shadow,
    required this.glareLight,
    required this.glareDark,
  });

  // Fractions of the half-size. Derived from the 45px original with the
  // tick orbit (23.5px) as the normalising radius, so nothing clips.
  static const double _rTick = 0.979;
  static const double _rRim = 0.872;
  static const double _rFill = 0.787;
  static const double _rShadow = 0.660;
  static const double _rBody = 0.617;
  static const double _rGlare = 0.489;
  static const double _rPointerOrbit = 0.468;
  static const double _rPointer = 0.064;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final frac = ((value - min) / (max - min)).clamp(0.0, 1.0);

    _paintTrack(canvas, c, r, frac);
    _paintTicks(canvas, c, r);
    _paintBody(canvas, c, r);
    _paintPointer(canvas, c, r, frac);
  }

  /// Rim and fill are drawn as stroked arcs between the radii above
  /// rather than as a full ellipse clipped over a darkened one; an arc
  /// takes one operation and lets the fill stop at the value.
  void _paintTrack(Canvas canvas, Offset c, double r, double frac) {
    final rimW = (_rRim - _rFill) * r;
    final rimR = (_rRim + _rFill) / 2 * r;
    final rimRect = Rect.fromCircle(center: c, radius: rimR);
    canvas.drawArc(
      rimRect,
      kKnobStartAngle,
      kKnobSweepAngle,
      false,
      Paint()
        ..color = Color.alphaBlend(rimShade.withValues(alpha: 0.32), accent)
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimW,
    );

    if (frac <= 0.001) return;
    final fillW = (_rFill - _rShadow) * r;
    final fillR = (_rFill + _rShadow) / 2 * r;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: fillR),
      kKnobStartAngle,
      kKnobSweepAngle * frac,
      false,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = fillW,
    );
  }

  /// Three 2x2 diamonds at min, centre and max: squares on their
  /// corner, so a rotated rect rather than a dot.
  void _paintTicks(Canvas canvas, Offset c, double r) {
    final paint = Paint()..color = tick.withValues(alpha: 0.32);
    final half = 0.045 * r;
    for (final f in const [0.0, 0.5, 1.0]) {
      final a = kKnobStartAngle + kKnobSweepAngle * f;
      final p = c + Offset(cos(a), sin(a)) * (_rTick * r - half);
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(pi / 4);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: half * 2, height: half * 2),
        paint,
      );
      canvas.restore();
    }
  }

  /// Raised cap: a shadow well, the accent disc with a hairline stroke,
  /// then the glare. Three drop shadows at falling alpha draw the
  /// ramp; five would cost two more blurs a frame.
  ///
  /// The clip keeps the shadows inside a 31x31 body at the 45 px size,
  /// so the dark well around the cap is only about 0.04 of the radius
  /// wide. Drawn
  /// unclipped they blur outward and swallow the fill arc — measured
  /// dark from 0.62 to 0.79 before this clip, against the arc's 0.66
  /// to 0.79.
  void _paintBody(Canvas canvas, Offset c, double r) {
    final wellR = _rShadow * r;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: wellR)));
    canvas.drawCircle(
      c,
      wellR,
      Paint()
        ..color = shadow.withValues(alpha: 0.38)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.02 * r),
    );
    // Offsets, blurs and alphas are fractions of a half-size of 23.5.
    // Drawn at the body radius and behind the body, so only
    // the offset crescent shows, which is what reads as height.
    const ramp = [
      (0.029, 0.059, 0.54),
      (0.117, 0.117, 0.47),
      (0.264, 0.147, 0.28),
    ];
    for (final (dy, blur, alpha) in ramp) {
      canvas.drawCircle(
        c + Offset(0, dy * r),
        _rBody * r,
        Paint()
          ..color = shadow.withValues(alpha: alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur * r),
      );
    }
    canvas.restore();

    final bodyR = _rBody * r;
    canvas.drawCircle(c, bodyR, Paint()..color = accent);
    canvas.drawCircle(
      c,
      bodyR,
      Paint()
        ..color = bodyStroke.withValues(alpha: 0.21)
        ..style = PaintingStyle.stroke
        ..strokeWidth = knobAtLeast(0.024 * r, 0.5),
    );

    // Lit from the lower right: the highlight measures at (+0.48,
    // +0.72) of the body radius off centre, which is what reads as a
    // cap standing above the shadow rather than a flat disc.
    final glareR = _rGlare * r;
    final glareRect = Rect.fromCircle(center: c, radius: glareR);
    canvas.drawCircle(
      c,
      glareR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.48, 0.72),
          radius: 1.1,
          colors: [glareLight, glareDark],
        ).createShader(glareRect)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.04 * r),
    );
  }

  void _paintPointer(Canvas canvas, Offset c, double r, double frac) {
    final a = kKnobStartAngle + kKnobSweepAngle * frac;
    canvas.drawCircle(
      c + Offset(cos(a), sin(a)) * (_rPointerOrbit * r),
      _rPointer * r,
      Paint()..color = pointer.withValues(alpha: 0.64),
    );
  }

  @override
  bool shouldRepaint(_KnobAPainter old) =>
      value != old.value ||
      min != old.min ||
      max != old.max ||
      accent != old.accent ||
      rimShade != old.rimShade ||
      tick != old.tick ||
      bodyStroke != old.bodyStroke ||
      pointer != old.pointer ||
      shadow != old.shadow ||
      glareLight != old.glareLight ||
      glareDark != old.glareDark;
}
