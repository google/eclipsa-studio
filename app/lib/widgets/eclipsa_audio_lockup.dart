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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../eclipsa_audio_palette.dart';
import '../state.dart';
import '../theme.dart';
import 'eclipsa_audio_wordmark_data.dart';

/// Which of the two greyscale colourways the logo is drawn in.
///
/// The brand sets the positive lockup for light or white grounds and
/// the reverse lockup for very dark or black ones. The symbol keeps Grey 500 for its tall inner shape in
/// both; the outer shape is Grey 400 in positive and Grey 600 in
/// reverse, and the core and the wordmark are black in positive and
/// white in reverse.
enum EclipsaAudioColorway {
  positive(
    outer: EclipsaAudioPalette.grey400,
    inner: EclipsaAudioPalette.grey500,
    core: EclipsaAudioPalette.black,
  ),
  reverse(
    outer: EclipsaAudioPalette.grey600,
    inner: EclipsaAudioPalette.grey500,
    core: EclipsaAudioPalette.white,
  );

  const EclipsaAudioColorway({
    required this.outer,
    required this.inner,
    required this.core,
  });

  /// The wide outer shape of each half.
  final Color outer;

  /// The tall inner shape of each half.
  final Color inner;

  /// Where the two overlap, and the wordmark.
  final Color core;

  /// The colourway for a logo drawn over [ground]: positive above the
  /// luminance at which black and white contrast equally against a
  /// colour (0.179), reverse below it. Light's `bgBase` is above it
  /// and every other shipped theme's is below.
  static EclipsaAudioColorway forGround(Color ground) =>
      ground.computeLuminance() > 0.179
      ? EclipsaAudioColorway.positive
      : EclipsaAudioColorway.reverse;
}

/// The Eclipsa Audio symbol and lockup, drawn from their geometry.
///
/// Nothing of the logo suite is checked in. The symbol is two mirrored
/// halves, each an outer shape and a tall inner shape with their
/// overlap filled in the core colour, and each shape is two cubic
/// Bézier curves mirrored about the symbol's horizontal axis. The
/// curves were fitted to the brand's horizontal greyscale lockup
/// artwork rendered with the symbol 356 x 324 px: every point of the
/// fitted outlines lies within 1.6 px of the artwork's edge at that
/// size, and the three filled regions match the artwork's to within
/// 1.6% of their pixels. The coordinates below are in those pixels,
/// with the symbol box's top-left corner at the origin; [EclipsaAudioSymbolPainter] scales them to the size it
/// is given.
///
/// The wordmark is Google Sans at weight 400, as glyph outlines in
/// `eclipsa_audio_wordmark_data.dart`, placed where the same artwork
/// has them: cap height 190 px, baseline 265 px below the symbol's
/// top, each glyph's left edge as measured.
abstract final class EclipsaAudioGeometry {
  /// The symbol's box, in artwork pixels.
  static const double boxWidth = 356;
  static const double boxHeight = 324;

  /// The symbol's centre line, and the axis its halves mirror about.
  static const double _centerX = boxWidth / 2;
  static const double _centerY = boxHeight / 2;

  // Left half, upper quadrant. Each shape is one cubic from its
  // topmost point round to its rightmost point on the centre line,
  // plus (for the outer shape) one from its leftmost point up to its
  // topmost; the lower quadrant is the mirror.

  // The tall inner shape: a near-vertical left side and a full right
  // bulge, 96.5 px wide at its widest.
  static const Offset _innerTop = Offset(96.5, 0);
  static const Offset _innerTopToRightC1 = Offset(134.79, 0);
  static const Offset _innerTopToRightC2 = Offset(174, 122.72);
  static const Offset _innerRight = Offset(174, _centerY);
  static const Offset _innerTopToLeftC1 = Offset(52.47, 0);
  static const Offset _innerTopToLeftC2 = Offset(55, 126.83);
  static const Offset _innerLeft = Offset(55, _centerY);

  // The outer shape: a rounded left side with a flat top at 54 px,
  // running out to a point on the centre line 4 px short of the
  // symbol's own centre.
  static const Offset _outerLeft = Offset(0, _centerY);
  static const Offset _outerLeftToTopC1 = Offset(0, 123.19);
  static const Offset _outerLeftToTopC2 = Offset(2.15, 54);
  static const Offset _outerTop = Offset(53, 54);
  static const Offset _outerTopToTipC1 = Offset(96.67, 54);
  static const Offset _outerTopToTipC2 = Offset(176.16, 117.65);
  static const Offset _outerTip = Offset(174, _centerY);

  /// Artwork pixels per font unit: the wordmark's 716-unit cap height
  /// stands 190 px tall.
  static const double unitsScale = 190 / kEclipsaAudioCapHeight;

  /// The wordmark's baseline, in artwork pixels below the symbol's top.
  static const double baseline = 265;

  /// The lockup's width in artwork pixels: from the symbol's left edge
  /// to the last glyph's right edge.
  static const double lockupWidth = kEclipsaAudioWordmarkRight * unitsScale;

  /// Width over height of the symbol's box.
  static const double symbolAspect = boxWidth / boxHeight;

  /// Width over height of the lockup.
  static const double lockupAspect = lockupWidth / boxHeight;

  static Offset _mirrorY(Offset p) => Offset(p.dx, boxHeight - p.dy);

  /// The left half of one shape: [top] round the right side to
  /// [right], mirrored down and back, then [left] up to [top].
  static Path _leftHalf({
    required Offset top,
    required Offset toRightC1,
    required Offset toRightC2,
    required Offset right,
    required Offset toLeftC1,
    required Offset toLeftC2,
    required Offset left,
  }) {
    final path = Path()..moveTo(top.dx, top.dy);
    void cubic(Offset c1, Offset c2, Offset p) =>
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
    cubic(toRightC1, toRightC2, right);
    cubic(_mirrorY(toRightC2), _mirrorY(toRightC1), _mirrorY(top));
    cubic(_mirrorY(toLeftC1), _mirrorY(toLeftC2), left);
    cubic(toLeftC2, toLeftC1, top);
    return path..close();
  }

  /// Both halves of a shape: the left half and its mirror about the
  /// symbol's vertical centre line.
  static Path _bothHalves(Path leftHalf) {
    final mirror = Matrix4.diagonal3Values(-1, 1, 1)
      ..setTranslationRaw(2 * _centerX, 0, 0);
    return Path.from(leftHalf)
      ..addPath(leftHalf, Offset.zero, matrix4: mirror.storage);
  }

  static final Path _outerLeftHalf = _leftHalf(
    top: _outerTop,
    toRightC1: _outerTopToTipC1,
    toRightC2: _outerTopToTipC2,
    right: _outerTip,
    toLeftC1: _outerLeftToTopC2,
    toLeftC2: _outerLeftToTopC1,
    left: _outerLeft,
  );

  static final Path _innerLeftHalf = _leftHalf(
    top: _innerTop,
    toRightC1: _innerTopToRightC1,
    toRightC2: _innerTopToRightC2,
    right: _innerRight,
    toLeftC1: _innerTopToLeftC1,
    toLeftC2: _innerTopToLeftC2,
    left: _innerLeft,
  );

  /// The two outer shapes, in artwork pixels.
  static final Path outer = _bothHalves(_outerLeftHalf);

  /// The two inner shapes, in artwork pixels.
  static final Path inner = _bothHalves(_innerLeftHalf);

  /// Where an outer shape and an inner shape overlap, in artwork pixels.
  static final Path core = Path.combine(PathOperation.intersect, outer, inner);

  /// The wordmark's twelve glyphs as one path, in artwork pixels, with
  /// the symbol box's top-left corner at the origin.
  static final Path wordmark = _buildWordmark();

  static Path _buildWordmark() {
    final path = Path()..fillType = PathFillType.nonZero;
    for (final glyph in kEclipsaAudioGlyphs) {
      final x0 = glyph.penX * unitsScale;
      double x(int u) => x0 + u * unitsScale;
      double y(int u) => baseline - u * unitsScale;
      final o = glyph.outline;
      var i = 0;
      while (i < o.length) {
        switch (o[i]) {
          case 0:
            path.moveTo(x(o[i + 1]), y(o[i + 2]));
            i += 3;
          case 1:
            path.lineTo(x(o[i + 1]), y(o[i + 2]));
            i += 3;
          case 2:
            path.quadraticBezierTo(
              x(o[i + 1]),
              y(o[i + 2]),
              x(o[i + 3]),
              y(o[i + 4]),
            );
            i += 5;
          case 3:
            path.close();
            i += 1;
          default:
            throw StateError('bad outline record ${o[i]} in ${glyph.char}');
        }
      }
    }
    return path;
  }
}

/// Paints the symbol into a box of [EclipsaAudioGeometry.symbolAspect].
class EclipsaAudioSymbolPainter extends CustomPainter {
  const EclipsaAudioSymbolPainter({required this.colorway});

  final EclipsaAudioColorway colorway;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.height / EclipsaAudioGeometry.boxHeight);
    paintSymbol(canvas, colorway);
    canvas.restore();
  }

  /// Draws the symbol in artwork pixels at the canvas origin.
  static void paintSymbol(Canvas canvas, EclipsaAudioColorway colorway) {
    canvas.drawPath(
      EclipsaAudioGeometry.outer,
      Paint()..color = colorway.outer,
    );
    canvas.drawPath(
      EclipsaAudioGeometry.inner,
      Paint()..color = colorway.inner,
    );
    canvas.drawPath(EclipsaAudioGeometry.core, Paint()..color = colorway.core);
  }

  @override
  bool shouldRepaint(EclipsaAudioSymbolPainter old) => old.colorway != colorway;
}

/// Paints the horizontal lockup into a box of
/// [EclipsaAudioGeometry.lockupAspect].
class EclipsaAudioLockupPainter extends CustomPainter {
  const EclipsaAudioLockupPainter({required this.colorway});

  final EclipsaAudioColorway colorway;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.height / EclipsaAudioGeometry.boxHeight);
    EclipsaAudioSymbolPainter.paintSymbol(canvas, colorway);
    canvas.drawPath(
      EclipsaAudioGeometry.wordmark,
      Paint()..color = colorway.core,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(EclipsaAudioLockupPainter old) => old.colorway != colorway;
}

/// The Eclipsa Audio symbol without the wordmark, [size] tall.
///
/// The brand uses the symbol alone in device UI. In the app it stands
/// in the Theme Gallery; the landing screen draws the
/// full [EclipsaAudioLockup].
///
/// [colorway] defaults to the one for the theme's `bgBase`. Watches
/// theme mode so it tracks a theme switch even when constructed
/// `const` upstream, where no parent rebuild reaches it.
class EclipsaAudioSymbol extends ConsumerWidget {
  const EclipsaAudioSymbol({super.key, this.size = 24, this.colorway});

  /// The height of the symbol's box in logical pixels. The brand's
  /// on-screen symbol sizes are 20, 24, 40 and 48 dp.
  final double size;

  final EclipsaAudioColorway? colorway;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(size * EclipsaAudioGeometry.symbolAspect, size),
        painter: EclipsaAudioSymbolPainter(
          colorway: colorway ?? EclipsaAudioColorway.forGround(T.bgBase),
        ),
      ),
    );
  }
}

/// The horizontal greyscale Eclipsa Audio lockup, [height] tall, in
/// the spacing the brand's artwork fixes: the wordmark's cap height is 190/324
/// of the symbol's height and its left edge is 503/324 of it from the
/// symbol's left edge.
///
/// Drawn on the landing screen at 32 px, and in the Theme Gallery.
/// [colorway] defaults to the one for the theme's `bgBase`. Watches
/// theme mode so it tracks a theme switch even when constructed
/// `const` upstream, where no parent rebuild reaches it.
class EclipsaAudioLockup extends ConsumerWidget {
  const EclipsaAudioLockup({super.key, this.height = 24, this.colorway});

  /// The height of the symbol's box in logical pixels; the wordmark
  /// is sized from it.
  final double height;

  final EclipsaAudioColorway? colorway;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(height * EclipsaAudioGeometry.lockupAspect, height),
        painter: EclipsaAudioLockupPainter(
          colorway: colorway ?? EclipsaAudioColorway.forGround(T.bgBase),
        ),
      ),
    );
  }
}
