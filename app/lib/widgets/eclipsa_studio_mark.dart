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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';

/// The cube mark — the E and the S projected onto the two front walls
/// of an isometric cube, drawn from its own geometry rather than
/// shipped as an asset.
///
/// The cube is 58 units tall in a 100-unit box (its live area runs
/// 21..79 on both axes), so its edge is 29 units and it is 50.2 wide.
/// Three faces show: the top, the left wall and the right wall. Each
/// face carries a 5×5 grid of circular cells on the 12-unit pitch of
/// a 58-unit square, scaled to fill the face to a 4% margin; the
/// cells are drawn in the plane of their face, so on screen they are
/// ellipses. The left wall draws the E's 16 lit cells in
/// [T.textPrimary], the right wall the S's 17 in [T.pink], and the top
/// face all 25 cells unlit in [kFieldColor], one fixed grey, which is
/// what shows the cube. The lit maps, row by row:
///
/// ```text
/// E        S
/// 11111    11111
/// 10000    10000
/// 11110    11111
/// 10000    00001
/// 11111    11111
/// ```
///
/// The geometry is identical in every theme; only the two inks
/// change, and they are the tokens the wordmark beside it uses for
/// "Eclipsa" and " Studio".
///
/// **Size.** Neighbouring cells on a wall are 0.92 units apart at
/// their nearest, 1.6% of [size]: 0.9 px at [kMarkLarge] and 0.5 px
/// at [kMarkSmall], so at the small size the cells of a letter run
/// together into bars and the mark reads by its silhouette.
/// [EclipsaStudioLockup] sizes it from the type beside it: 31 px in the
/// 44 px top bar and 82 px on the landing screen.
///
/// Drawn on the landing screen and in the top bar, in both workspace
/// modes, and in the debug-only Theme Gallery. `scripts/gen_app_icon.py`
/// generates the platform app icons and the brand masters from the
/// same geometry, and `test/eclipsa_studio_mark_asset_test.dart` checks the
/// two against each other.
///
/// Watches theme + font mode so it tracks a theme switch even when
/// constructed `const` upstream, where no parent rebuild reaches it.
class EclipsaStudioMark extends ConsumerWidget {
  const EclipsaStudioMark({
    super.key,
    this.size = kMarkSmall,
    this.showUnlitCells = true,
    this.onChrome = false,
  });

  /// The default: the lockup's size in the top bar. The Theme Gallery
  /// draws it.
  static const double kMarkSmall = 31;

  /// The source geometry at 1:1 — one box unit per pixel. The Theme
  /// Gallery draws it.
  static const double kMarkLarge = 58;

  /// Outer size in logical pixels: the height of the cube's box.
  final double size;

  /// Whether the top face's 25 unlit cells are drawn. Without them the
  /// two letters stand alone, skewed to their walls.
  final bool showUnlitCells;

  /// Set when the mark sits on the chrome bar rather than a body
  /// surface, which swaps the E to [T.chromeInk].
  ///
  /// [T.textPrimary] is chosen against `bgBase`, and a theme's chrome
  /// bar is its own surface with its own ground, which no body token
  /// is chosen against. `chromeInk` is the ink each theme puts on its
  /// bar, gated against `chromeBg` in contrast.json, and it holds for
  /// every theme: 9.08 (Dark), 8.01 (Light), 6.87 (Classic) and 17.14
  /// (High Contrast).
  ///
  /// The S stays [T.pink], which clears the 3:1 non-text threshold on
  /// every chrome: 4.55 (Dark) / 4.20 (Light) / 5.25 (Classic) / 7.23
  /// (High Contrast).
  final bool onChrome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    // The boundary keeps the mark's picture across the frames its
    // neighbours repaint at 60 Hz during playback (the clock and the
    // scrub bar in the top bar); the painter's 58 ellipses on three
    // transforms are then recorded once per theme or size change.
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: CubeMarkPainter(
          ink: onChrome ? T.chromeInk : T.textPrimary,
          accent: T.pink,
          showUnlitCells: showUnlitCells,
        ),
      ),
    );
  }
}

/// Opacity of the unlit cells, as in the brand masters.
/// The unlit field on the top face: one fixed grey in every theme and
/// on every ground, `#64636A`, which is Dark's text ink at 40% over
/// its body. The brand generator uses the same value.
const Color kFieldColor = Color(0xFF64636A);

/// First edge and extent of the live area — 21 to 79, i.e. 58 units.
const double _liveStart = 21;
const double _liveSpan = 58;

/// The three visible faces of the cube.
enum MarkFace { top, left, right }

/// A face's affine map from face space (a 100-unit square) onto the
/// 100-unit box: `x' = a*x + c*y + e`, `y' = b*x + d*y + f`, the
/// order of an SVG `matrix(a b c d e f)`.
typedef _Affine = ({
  double a,
  double b,
  double c,
  double d,
  double e,
  double f,
});

/// The cube's edge in box units, and its projection: an isometric view,
/// edges at 30° from the horizontal, so a face's x axis runs
/// (cos 30°, ±sin 30°) and its vertical axis stays vertical.
const double _edge = _liveSpan / 2;
const double _cos30 = 0.8660254037844386;
const double _k = _edge / 100;
const double _halfWidth = _edge * _cos30;
const double _midY = _liveStart + _edge;

const Map<MarkFace, _Affine> _faces = {
  MarkFace.top: (
    a: _cos30 * _k,
    b: 0.5 * _k,
    c: _cos30 * _k,
    d: -0.5 * _k,
    e: 50 - _halfWidth,
    f: _midY - 0.5 * _edge,
  ),
  MarkFace.left: (
    a: _cos30 * _k,
    b: 0.5 * _k,
    c: 0,
    d: _k,
    e: 50 - _halfWidth,
    f: _midY - 0.5 * _edge,
  ),
  MarkFace.right: (a: _cos30 * _k, b: -0.5 * _k, c: 0, d: _k, e: 50, f: _midY),
};

/// Lit maps, top row first. `1` is lit. The top face has no letter.
const List<String> _eRows = ['11111', '10000', '11110', '10000', '11111'];
const List<String> _sRows = ['11111', '10000', '11111', '00001', '11111'];

/// The grid fills each face to this margin on every side.
const double _fieldMargin = 0.04;
const double _fieldScale = 100 * (1 - 2 * _fieldMargin) / _liveSpan;

/// Cell centres along each face axis, in face space: the 26/38/50/62/74
/// of a 58-unit square, scaled into the face.
const List<double> _fieldPositions = [
  100 * _fieldMargin + (26 - _liveStart) * _fieldScale,
  100 * _fieldMargin + (38 - _liveStart) * _fieldScale,
  100 * _fieldMargin + (50 - _liveStart) * _fieldScale,
  100 * _fieldMargin + (62 - _liveStart) * _fieldScale,
  100 * _fieldMargin + (74 - _liveStart) * _fieldScale,
];

/// Cell radius in face space: 5 of the 58-unit square, scaled.
const double _fieldRadius = 5 * _fieldScale;

/// Whether [face] draws the cell at ([row], [col]).
bool _drawn(MarkFace face, int row, int col) => switch (face) {
  MarkFace.top => true,
  MarkFace.left => _eRows[row][col] == '1',
  MarkFace.right => _sRows[row][col] == '1',
};

/// The centre of the cell at ([row], [col]) on [face], in the pixels
/// of a mark drawn at [size]. For tests that sample the raster.
Offset markCellCentre(MarkFace face, int row, int col, double size) {
  final m = _faces[face]!;
  final fx = _fieldPositions[col];
  final fy = _fieldPositions[row];
  final scale = size / _liveSpan;
  return Offset(
    (m.a * fx + m.c * fy + m.e - _liveStart) * scale,
    (m.b * fx + m.d * fy + m.f - _liveStart) * scale,
  );
}

/// The cells' extent on [face] in the pixels of a mark drawn at
/// [size]: the largest half-width and half-height of one cell's
/// ellipse. For tests that check the mark stays inside its box.
Size markCellExtent(MarkFace face, double size) {
  final m = _faces[face]!;
  final scale = size / _liveSpan;
  return Size(
    _fieldRadius * math.sqrt(m.a * m.a + m.c * m.c) * scale,
    _fieldRadius * math.sqrt(m.b * m.b + m.d * m.d) * scale,
  );
}

/// The cube's silhouette — the extent of its cells — in the pixels of
/// a mark drawn at [size]. The cells stop short of the box on every
/// side, so a lockup measures its pad and gap from this, not the box.
Rect markSilhouette(double size) {
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final face in MarkFace.values) {
    final extent = markCellExtent(face, size);
    for (var row = 0; row < 5; row++) {
      for (var col = 0; col < 5; col++) {
        if (!_drawn(face, row, col)) continue;
        final c = markCellCentre(face, row, col, size);
        left = math.min(left, c.dx - extent.width);
        top = math.min(top, c.dy - extent.height);
        right = math.max(right, c.dx + extent.width);
        bottom = math.max(bottom, c.dy + extent.height);
      }
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Draws the mark scaled into whatever box it is given.
///
/// Reads no theme state itself: the colours arrive through the
/// constructor so the painter's [shouldRepaint] can compare them,
/// which is what makes a theme switch repaint.
class CubeMarkPainter extends CustomPainter {
  const CubeMarkPainter({
    required this.ink,
    required this.accent,
    this.showUnlitCells = true,
  });

  final Color ink;
  final Color accent;
  final bool showUnlitCells;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _liveSpan;
    final paint = Paint()..isAntiAlias = true;
    // The field first, so the letters sit over it where the top face
    // meets the walls.
    for (final face in MarkFace.values) {
      if (face == MarkFace.top && !showUnlitCells) continue;
      paint.color = switch (face) {
        MarkFace.top => kFieldColor,
        MarkFace.left => ink,
        MarkFace.right => accent,
      };
      final m = _faces[face]!;
      canvas.save();
      // Face space to pixels: the face's affine map, then the box's
      // 21-unit margin off and the scale on. Column-major 4×4.
      canvas.transform(
        Float64List.fromList([
          m.a * scale, m.b * scale, 0, 0, //
          m.c * scale, m.d * scale, 0, 0, //
          0, 0, 1, 0, //
          (m.e - _liveStart) * scale, (m.f - _liveStart) * scale, 0, 1, //
        ]),
      );
      for (var row = 0; row < 5; row++) {
        for (var col = 0; col < 5; col++) {
          if (!_drawn(face, row, col)) continue;
          final centre = Offset(_fieldPositions[col], _fieldPositions[row]);
          canvas.drawCircle(centre, _fieldRadius, paint);
        }
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CubeMarkPainter old) =>
      old.ink != ink ||
      old.accent != accent ||
      old.showUnlitCells != showUnlitCells;
}
