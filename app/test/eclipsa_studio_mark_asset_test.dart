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

import 'dart:io';
import 'dart:typed_data';

import 'package:eclipsa_studio/widgets/eclipsa_studio_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The mark's geometry exists twice: in scripts/gen_app_icon.py, which
// emits the vector masters and every platform icon, and in the Dart
// painter, which draws it on screen. A painter cannot read the Python
// at build time, so the copies are guarded here instead — this parses
// the generated master and fails if the two ever drift apart.
//
// The point of the pipeline is that a logo change is an edit to the
// geometry plus a re-run. This test is what makes the second half of
// that safe: change the script, regenerate, and if the painter was
// not updated to match, this fails.

/// One cell read out of the master SVG, in the 100-unit box: the
/// centre after the face's transform, the radius in face space, the
/// linear part of the transform, and whether the cell is lit.
typedef _Cell = ({
  double cx,
  double cy,
  double r,
  double a,
  double b,
  double c,
  double d,
  bool lit,
});

final _group = RegExp(
  r'<g fill="#([0-9A-Fa-f]{6})"\s+transform="matrix\(([-\d. ]+)\)">(.*?)</g>',
  dotAll: true,
);

/// The generator's field colour, as it appears in the master.
const _fieldHex = '64636A';
final _circle = RegExp(r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"/>');

List<_Cell> _parseMaster(String svg) {
  final cells = <_Cell>[];
  for (final g in _group.allMatches(svg)) {
    final lit = g.group(1)!.toUpperCase() != _fieldHex;
    final m = g
        .group(2)!
        .trim()
        .split(RegExp(r'\s+'))
        .map(double.parse)
        .toList();
    final (a, b, c, d, e, f) = (m[0], m[1], m[2], m[3], m[4], m[5]);
    for (final circle in _circle.allMatches(g.group(3)!)) {
      final fx = double.parse(circle.group(1)!);
      final fy = double.parse(circle.group(2)!);
      cells.add((
        cx: a * fx + c * fy + e,
        cy: b * fx + d * fy + f,
        r: double.parse(circle.group(3)!),
        a: a,
        b: b,
        c: c,
        d: d,
        lit: lit,
      ));
    }
  }
  return cells;
}

/// Records the circles the painter draws, with the transform in force
/// when each one was drawn.
class _Recorder implements Canvas {
  final List<({Offset centre, double radius, Color color, Float64List m})>
  circles = [];
  final List<Float64List> _stack = [];
  Float64List _m = Float64List.fromList([
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1, //
  ]);

  @override
  void save() => _stack.add(_m);

  @override
  void restore() => _m = _stack.removeLast();

  @override
  void transform(Float64List matrix4) => _m = _multiply(_m, matrix4);

  /// Column-major 4x4 product `a * b`, as Canvas.transform composes.
  static Float64List _multiply(Float64List a, Float64List b) {
    final out = Float64List(16);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[k * 4 + row] * b[col * 4 + k];
        }
        out[col * 4 + row] = sum;
      }
    }
    return out;
  }

  @override
  void drawCircle(Offset c, double r, Paint paint) =>
      circles.add((centre: c, radius: r, color: paint.color, m: _m));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  // The test's working directory is app/.
  final master = File('../app/design/brand/eclipsa-studio-mark.svg');

  test('the generated vector master exists', () {
    expect(master.existsSync(), isTrue, reason: 'run ./build.sh gen-icon');
  });

  test('the master and the painter draw the same 58 cells', () {
    final cells = _parseMaster(master.readAsStringSync());
    expect(cells.length, 58);
    expect(cells.where((c) => c.lit).length, 33);

    // Draw at 58, which is the master's own box, so the painter's
    // coordinates are the master's less the 21-unit margin and its
    // transforms are the master's matrices exactly.
    final canvas = _Recorder();
    const CubeMarkPainter(
      ink: Color(0xFFE0E4EC),
      accent: Color(0xFFE06090),
    ).paint(canvas, const Size.square(EclipsaStudioMark.kMarkLarge));

    expect(canvas.circles.length, cells.length);
    final fromPainter = canvas.circles.map((c) {
      final m = c.m;
      return (
        cx: m[0] * c.centre.dx + m[4] * c.centre.dy + m[12] + 21,
        cy: m[1] * c.centre.dx + m[5] * c.centre.dy + m[13] + 21,
        r: c.radius,
        a: m[0],
        b: m[1],
        c: m[4],
        d: m[5],
        lit: c.color.toARGB32() != kFieldColor.toARGB32(),
      );
    }).toList()..sort(_byPosition);
    final fromMaster = [...cells]..sort(_byPosition);

    for (var i = 0; i < fromMaster.length; i++) {
      final p = fromPainter[i];
      final s = fromMaster[i];
      // The master rounds centres and radii to 3 decimals and the
      // matrices to 4.
      final reason =
          'cell $i differs between '
          'app/design/brand/eclipsa-studio-mark.svg and '
          'CubeMarkPainter — regenerate one or fix the other';
      expect(p.lit, s.lit, reason: reason);
      expect(p.cx, closeTo(s.cx, 0.01), reason: reason);
      expect(p.cy, closeTo(s.cy, 0.01), reason: reason);
      expect(p.r, closeTo(s.r, 0.001), reason: reason);
      expect(p.a, closeTo(s.a, 0.0001), reason: reason);
      expect(p.b, closeTo(s.b, 0.0001), reason: reason);
      expect(p.c, closeTo(s.c, 0.0001), reason: reason);
      expect(p.d, closeTo(s.d, 0.0001), reason: reason);
    }
  });

  test('the master uses the same field colour as the painter', () {
    final svg = master.readAsStringSync();
    // The painter's value lives in eclipsa_studio_mark.dart; the master's is
    // written by the generator. Both must name the same grey.
    expect(svg, contains('fill="#$_fieldHex"'));
    expect(svg, isNot(contains('fill-opacity')));

    final canvas = _Recorder();
    const CubeMarkPainter(
      ink: Color(0xFFE0E4EC),
      accent: Color(0xFFE06090),
    ).paint(canvas, const Size.square(EclipsaStudioMark.kMarkLarge));
    // Paint.color round-trips through floats, so compare the packed
    // value rather than the Color.
    final unlit = canvas.circles.where(
      (c) => c.color.toARGB32() == kFieldColor.toARGB32(),
    );
    expect(unlit.length, 25);
    for (final c in canvas.circles) {
      expect(c.color.a, 1.0);
    }
  });
}

int _byPosition(_Cell a, _Cell b) {
  // The master's centres carry rounding of up to 0.005. Distinct cells
  // come no nearer than 0.33 on y (a top-face cell against a wall's
  // top row) and 1.78 on x, so centres within 0.02 are the same cell.
  if ((a.cy - b.cy).abs() > 0.02) return a.cy.compareTo(b.cy);
  if ((a.cx - b.cx).abs() > 0.02) return a.cx.compareTo(b.cx);
  return 0;
}
