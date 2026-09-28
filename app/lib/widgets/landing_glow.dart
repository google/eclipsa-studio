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

/// The glow of Dark's landing page (`CardStyle.floating`, ES-757): a radial glow
/// painted over the ground. The ellipse is centred on the top edge, 0.51 of the
/// width across each side and the full height down, fading from `#2F2F2F`
/// opaque to `#232323` transparent. ES-757 kept Dark's flat ground under the
/// glow, so the ground is the `landingGroundTop` and `landingGroundBottom`
/// tokens (both `bgBase` in Dark) and the glow's two greys stay consts here.
///
/// `LandingGround` paints it over the ground tokens behind the whole
/// window while the landing screen shows. It reads no theme value: the
/// two greys are consts, and the ground under it is the caller's.
class LandingGlow extends StatelessWidget {
  const LandingGlow({super.key});

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _LandingGlowPainter());
}

class _LandingGlowPainter extends CustomPainter {
  const _LandingGlowPainter();

  static const _centre = Color(0xFF2F2F2F);
  static const _edge = Color(0x00232323);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // A unit circle scaled to the ellipse: RadialGradient is circular.
    // Clipped to the box, which the ellipse's upper half overhangs.
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, 0);
    canvas.scale(size.width * 0.51, size.height);
    final unit = Rect.fromCircle(center: Offset.zero, radius: 1);
    canvas.drawRect(
      unit,
      Paint()
        ..shader = const RadialGradient(
          colors: [_centre, _edge],
        ).createShader(unit),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LandingGlowPainter old) => false;
}
