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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';

/// Glyph for an audio-element type ('Object' / 'Scene' / 'Channel'),
/// shared by [AeTypeBadge], the elements-view format chip and the format
/// pickers.
///
/// Channel is a loudspeaker, a Material icon. Object draws a source on
/// an orbit ([_OrbitGlyphPainter]) and Scene four first-order lobes
/// ([_SceneGlyphPainter]). [color] defaults to [aeTypeColor].
///
/// Watches the theme so a `const` call site still repaints in the new
/// type colour on a theme switch.
class AeTypeGlyph extends ConsumerWidget {
  final String type;
  final double size;
  final Color? color;

  const AeTypeGlyph({
    super.key,
    required this.type,
    required this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    final c = color ?? aeTypeColor(type);
    final t = type.toLowerCase();
    Widget painted(CustomPainter painter) => SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: painter),
    );
    if (t.contains('object')) return painted(_OrbitGlyphPainter(c));
    if (t.contains('scene')) return painted(_SceneGlyphPainter(c));
    return Icon(Icons.speaker, size: size, color: c);
  }
}

/// The object glyph: a source on an orbit around a listener. A ring of
/// outer radius r and stroke r/5, open for 1.5 rad around its
/// upper-right point, a disc of radius r/2.6 centred on the ring's
/// stroke at that point, and a disc of radius r/6 at the centre.
///
/// r is 20/24 of half the box, as for [_SceneGlyphPainter].
class _OrbitGlyphPainter extends CustomPainter {
  final Color color;

  const _OrbitGlyphPainter(this.color);

  /// Angle of the source on the ring: upper right, with y pointing down.
  static const double _sourceAngle = -math.pi / 4;

  /// Half the ring's opening around the source, in radians.
  static const double _gap = 0.75;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 10 / 24;
    final w = r / 5;
    final ringRadius = r - w / 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: ringRadius),
      _sourceAngle + _gap,
      2 * math.pi - 2 * _gap,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = w,
    );
    final fill = Paint()..color = color;
    final source =
        c + Offset(math.cos(_sourceAngle), math.sin(_sourceAngle)) * ringRadius;
    canvas.drawCircle(source, r / 2.6, fill);
    canvas.drawCircle(c, r / 6, fill);
  }

  @override
  bool shouldRepaint(_OrbitGlyphPainter old) => old.color != color;
}

/// The scene glyph: four discs of radius r/2 on the horizontal and
/// vertical axes, each passing through the centre. These are the polar
/// patterns of the first-order X and Y ambisonic components (r = cos θ
/// is a circle through the origin). They are filled with the even-odd
/// rule, so the lens where two adjacent discs overlap stays empty.
///
/// The glyph spans 2r, 20/24 of the box: the extent of a Material
/// icon's glyph in its 24 px box, so it draws at the size of the Channel
/// glyph.
class _SceneGlyphPainter extends CustomPainter {
  final Color color;

  const _SceneGlyphPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final h = size.shortestSide * 5 / 24;
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final d in [
      Offset(0, -h),
      Offset(h, 0),
      Offset(0, h),
      Offset(-h, 0),
    ]) {
      path.addOval(Rect.fromCircle(center: c + d, radius: h));
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SceneGlyphPainter old) => old.color != color;
}

/// One line of an element card's details: a glyph and a label, with no
/// fill or border.
///
/// The Mix strip draws one for the element type; the Renderer card
/// stacks them for the element type, the mix gain and the headphones
/// rendering, and `MixStatusBadge` draws the "Not in mix presentation"
/// line with it. The label draws at `fontBody` in `textSecondary`
/// ([numeric] labels use [valueStyle]); [dim] draws it in
/// `textTertiary`, for the headphones line under the gain line, and
/// [color] replaces either.
///
/// Watches the theme and the font size so a `const` call site still
/// rebuilds with the new colours and sizes.
class ElementDetailRow extends ConsumerWidget {
  /// Size the callers draw [glyph] at, so every line's glyph matches.
  static const double glyphSize = T.iconSm;

  /// Label style of a detail line; [dim] for `textTertiary`.
  static TextStyle labelStyle({bool dim = false}) => TextStyle(
    fontSize: T.fontBody,
    color: dim ? T.textTertiary : T.textSecondary,
  );

  /// Numeric values: [T.monoFamily] at `fontSmall`, one step under the
  /// labels, because the monospace family draws larger than the UI font
  /// at the same size.
  static TextStyle valueStyle({bool dim = false}) => labelStyle(
    dim: dim,
  ).copyWith(fontFamily: T.monoFamily, fontSize: T.fontSmall);

  final Widget glyph;
  final String label;

  /// Draws the label with [valueStyle].
  final bool numeric;
  final bool dim;

  /// Label colour in place of the style's.
  final Color? color;

  const ElementDetailRow({
    super.key,
    required this.glyph,
    required this.label,
    this.numeric = false,
    this.dim = false,
    this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        glyph,
        const SizedBox(width: T.gapPair),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (numeric ? valueStyle(dim: dim) : labelStyle(dim: dim))
                .copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Audio-element type and layout line of the Mix and Renderer cards:
/// "Object · Mono", "Channel · 7.1.4", "Scene · 3OA", with the type
/// glyph in the type colour.
class AeTypeBadge extends StatelessWidget {
  final String type;
  final String layout;

  const AeTypeBadge({super.key, required this.type, required this.layout});

  @override
  Widget build(BuildContext context) {
    return ElementDetailRow(
      glyph: AeTypeGlyph(type: type, size: ElementDetailRow.glyphSize),
      label: '$type · $layout',
    );
  }
}
