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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Start of every knob's sweep: 135 degrees clockwise from 3 o'clock,
/// the lower left. Shared by the painters here, the brushed knob in
/// `gain_knob.dart` and `KnobA`, so every knob in the app turns
/// through the same range.
const double kKnobStartAngle = 135 * (pi / 180);

/// Length of every knob's sweep: 270 degrees, leaving the gap at the
/// bottom.
const double kKnobSweepAngle = 270 * (pi / 180);

/// [v], or [floor] if [v] is smaller. The knob painters carry a `max`
/// field that shadows dart:math's `max`, so they floor through this.
double knobAtLeast(double v, double floor) => v > floor ? v : floor;

/// Classic's bar knob and High Contrast's outlined ring. They share the
/// sweep ([kKnobStartAngle], [kKnobSweepAngle]), the value mapping and
/// the 0 dB reference with the brushed knob in `gain_knob.dart` and
/// `KnobA`, so every knob in the app turns through the same 270
/// degrees and marks zero at the same angle. Each is a different
/// composition of the same four parts (a track, an accent arc, a
/// pointer and reference marks), so no set of colour tokens turns one
/// into another. That is why they are [KnobStyle] members rather than
/// palettes.
///
/// `GainKnob` hands each one its colours from `T.*` at build time, so a
/// theme change reaches the painter through [shouldRepaint].
abstract class LineKnobPainter extends CustomPainter {
  LineKnobPainter({
    required this.gainDb,
    required this.min,
    required this.max,
    required this.trackColor,
    required this.activeColor,
    required this.pointerColor,
    required this.markColor,
  });

  final double gainDb;
  final double min;
  final double max;

  /// The untravelled part of the sweep.
  final Color trackColor;

  /// The travelled part of the sweep, and the pointer where the design
  /// draws it in the accent.
  final Color activeColor;
  final Color pointerColor;

  /// The 0 dB and end-of-sweep marks.
  final Color markColor;

  double get frac => ((gainDb - min) / (max - min)).clamp(0.0, 1.0);
  double get zeroFrac => ((0 - min) / (max - min)).clamp(0.0, 1.0);

  double angleAt(double f) => kKnobStartAngle + kKnobSweepAngle * f;

  Offset polar(Offset c, double angle, double r) =>
      c + Offset(cos(angle) * r, sin(angle) * r);

  /// A radial mark from [inner] to [outer] at the angle for [f].
  void mark(
    Canvas canvas,
    Offset c,
    double f,
    double inner,
    double outer,
    Paint paint,
  ) {
    final a = angleAt(f);
    canvas.drawLine(polar(c, a, inner), polar(c, a, outer), paint);
  }

  Paint stroke(Color color, double width, {StrokeCap cap = StrokeCap.butt}) =>
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = cap;

  @override
  bool shouldRepaint(covariant LineKnobPainter old) =>
      gainDb != old.gainDb ||
      min != old.min ||
      max != old.max ||
      trackColor != old.trackColor ||
      activeColor != old.activeColor ||
      pointerColor != old.pointerColor ||
      markColor != old.markColor;
}

/// Classic's knob, a bar knob: the shape of the selector knobs on a
/// Nagra recorder. The dish is the transport buttons' well, round: a
/// [discColor] disc in a 1 px [rimDark] rim over a 1 px [rimLight]
/// edge drawn below it on the plate, the same construction as
/// `recessedWell`, so the knob and the buttons beside it are one
/// object. A [bodyColor] cap sits in the dish 0.14 of the dish radius
/// short of its rim, lit from the top left of the screen and casting
/// a shadow into the dish. A [pointerColor] bar runs across the cap
/// from rim to rim, 0.38 of the cap's radius wide: a block whose two
/// flanks take their shade from the angle between their normal and
/// the same light, so the lit side moves as the knob turns, under a
/// lit top face inset from the flanks. The pointer end is the one
/// with the dimple in the top face. The scale is printed on the plate
/// outside the dish in [markColor]: a 1 px arc along the sweep, 1 px
/// ticks outward from it every [scaleStep] dB, the 0 dB tick longer,
/// and from [labelledFrom] up the dB value beside each tick at
/// [labelSize]. No accent arc: the bar's angle is the value, and the
/// readout beside the knob carries the exact number.
///
/// The base class's four inks are used as: `trackColor` the rim,
/// `activeColor` the lit edge, `pointerColor` the bar, `markColor`
/// the scale.
class BarKnobPainter extends LineKnobPainter {
  BarKnobPainter({
    required super.gainDb,
    required super.min,
    required super.max,
    required Color rimDark,
    required Color rimLight,
    required super.pointerColor,
    required super.markColor,
    required this.discColor,
    required this.bodyColor,
    required this.labelSize,
    required this.uiFamily,
  }) : super(trackColor: rimDark, activeColor: rimLight);

  final Color discColor;

  /// The cap that sits in the dish and carries the bar.
  final Color bodyColor;

  /// `T.fontMeter`, the size of the scale labels.
  final double labelSize;
  final String uiFamily;

  Color get rimDark => trackColor;
  Color get rimLight => activeColor;

  /// The scale's step in dB. A tick sits at every multiple inside the
  /// knob's range, so the default −60 to +12 dB range carries seven,
  /// from −60 to +12, with 0 dB the long one.
  static const double scaleStep = 12;

  /// The tick positions in dB for this knob's range.
  List<double> get scale => [
    for (
      var db = (this.min / scaleStep).ceil() * scaleStep;
      db <= this.max;
      db += scaleStep
    )
      db,
  ];

  /// Below this size the scale is ticks only; the 28 px track-panel
  /// knob has no room for labels beside its dish.
  static const double labelledFrom = 56;

  /// The light the cap and the bar's flanks are shaded against: the
  /// top left of the screen, whatever the bar's angle.
  static const Offset _light = Offset(-0.7071, -0.7071);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final outer = size.width / 2;
    final labelled = size.width >= labelledFrom;
    // The plate margin outside the dish: room for the arc and the
    // ticks, or for those and a row of labels. The long tick ends on
    // the box's edge.
    final margin = labelled ? labelSize + 7 : 4.0;
    final r = outer - margin;

    // The dish: lit edge first, so only the sliver below shows.
    canvas.drawCircle(c + const Offset(0, 1), r, Paint()..color = rimLight);
    canvas.drawCircle(c, r, Paint()..color = discColor);
    canvas.drawCircle(c, r - 0.5, stroke(rimDark, 1));

    // The scale on the plate: the arc along the sweep, then the ticks
    // outward from it.
    final ink = stroke(markColor, 1);
    final arcR = r + 1.5;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: arcR),
      kKnobStartAngle,
      kKnobSweepAngle,
      false,
      ink,
    );
    for (final db in scale) {
      if (db < this.min || db > this.max) continue;
      final f = (db - this.min) / (this.max - this.min);
      final long = db == 0;
      mark(canvas, c, f, arcR, arcR + (long ? 2.5 : 1.5), ink);
      if (labelled) _label(canvas, c, f, arcR + 2.5 + labelSize * 0.75, db);
    }

    // The body: a cap in the orifice at least 2 px short of its rim,
    // its shadow cast 1.5 px down into the dish (so inside it), lit
    // from the top left by a gradient across it and edged in its own
    // dark shade.
    final bodyR = r - knobAtLeast(r * 0.14, 2.0);
    final bodyHi = Color.lerp(bodyColor, const Color(0xFFFFFFFF), 0.12)!;
    final bodyLo = Color.lerp(bodyColor, const Color(0xFF000000), 0.30)!;
    canvas.drawCircle(
      c + const Offset(0, 1.5),
      bodyR,
      Paint()..color = rimDark.withValues(alpha: 0.8),
    );
    canvas.drawCircle(
      c,
      bodyR,
      Paint()
        ..shader = ui.Gradient.linear(
          c + _light * bodyR,
          c - _light * bodyR,
          [bodyHi, bodyColor, bodyLo],
          const [0.0, 0.5, 1.0],
        ),
    );
    canvas.drawCircle(c, bodyR - 0.5, stroke(bodyLo, 1));

    // The bar, in its own frame: x along the pointer, y across it. It
    // runs across the body from rim to rim; the pointer end is the one
    // with the dimple in the top face. A block with a top: the flanks
    // take their shade from the angle between their normal and a light
    // fixed at the top left of the screen, the top face is lit and
    // inset from the flanks by 0.28 of the half-width, 1 px at the
    // 28 px size.
    final a = angleAt(frac);
    final tip = bodyR - 1;
    final halfW = knobAtLeast(bodyR * 0.19, 2.5);
    final inset = knobAtLeast(halfW * 0.28, 1.0);
    final endR = Radius.circular(halfW * 0.6);
    final block = RRect.fromLTRBR(-tip, -halfW, tip, halfW, endR);
    final face = RRect.fromLTRBR(
      -tip + inset,
      -halfW + inset,
      tip - inset,
      halfW - inset,
      Radius.circular(knobAtLeast(halfW * 0.6 - inset, 0.5)),
    );

    // The flank on the bar's local −y side has the screen normal
    // (sin a, −cos a); its dot product with the light is how lit it
    // is, and the other flank is lit by the negation.
    final lit = sin(a) * _light.dx - cos(a) * _light.dy;
    final hi = Color.lerp(pointerColor, const Color(0xFFFFFFFF), 0.35)!;
    final lo = Color.lerp(pointerColor, const Color(0xFF000000), 0.40)!;
    Color shade(double d) => d >= 0
        ? Color.lerp(pointerColor, hi, d)!
        : Color.lerp(pointerColor, lo, -d)!;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(a);
    canvas.drawRRect(block, Paint()..color = shade(-lit));
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(-tip - 1, -halfW - 1, tip + 1, 0));
    canvas.drawRRect(block, Paint()..color = shade(lit));
    canvas.restore();
    canvas.drawRRect(face, Paint()..color = hi);
    // The dimple: the well's construction at dot size, a lit sliver
    // below a dark hole, set in from the pointer end by the bar's
    // width. Screen "down" in the bar's frame is (sin a, cos a).
    final dimple = knobAtLeast(halfW * 0.32, 1.0);
    final at = Offset(tip - halfW * 1.1, 0);
    canvas.drawCircle(
      at + Offset(sin(a), cos(a)) * 0.5,
      dimple,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.6),
    );
    canvas.drawCircle(at, dimple, Paint()..color = lo);
    canvas.restore();
  }

  void _label(Canvas canvas, Offset c, double f, double radius, double db) {
    final text = db > 0 ? '+${db.round()}' : '${db.round()}';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: uiFamily,
          fontSize: labelSize,
          color: markColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final at = polar(c, angleAt(f), radius);
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(covariant BarKnobPainter old) =>
      super.shouldRepaint(old) ||
      discColor != old.discColor ||
      bodyColor != old.bodyColor ||
      labelSize != old.labelSize ||
      uiFamily != old.uiFamily;
}

/// High Contrast's knob. A ring in [trackColor] at [ringWidth], the accent
/// arc at twice that width just inside it, a pointer bar from the
/// centre to the ring and a 0 dB mark outside it. No fill, no
/// gradient, no rounding on any stroke end.
class OutlinedKnobPainter extends LineKnobPainter {
  OutlinedKnobPainter({
    required super.gainDb,
    required super.min,
    required super.max,
    required super.trackColor,
    required super.activeColor,
    required super.pointerColor,
    required super.markColor,
    required this.ringWidth,
  });

  /// The theme's `borderWidth`.
  final double ringWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final outer = size.width / 2;
    final r = outer - 3 - ringWidth / 2;
    canvas.drawCircle(c, r, stroke(trackColor, ringWidth));
    final arcW = ringWidth * 2;
    final arcR = r - ringWidth / 2 - arcW / 2 - 1;
    if (frac > 0.001) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: arcR),
        kKnobStartAngle,
        kKnobSweepAngle * frac,
        false,
        stroke(activeColor, arcW),
      );
    }
    mark(
      canvas,
      c,
      zeroFrac,
      r + ringWidth / 2 + 1,
      outer,
      stroke(markColor, ringWidth),
    );
    canvas.drawLine(
      c,
      polar(c, angleAt(frac), arcR - arcW / 2 - 1),
      stroke(pointerColor, ringWidth),
    );
  }

  @override
  bool shouldRepaint(covariant OutlinedKnobPainter old) =>
      super.shouldRepaint(old) || ringWidth != old.ringWidth;
}
