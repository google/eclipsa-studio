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

import '../theme.dart';
import 'db_utils.dart';

/// Audio meter level zones: green / yellow / amber.
///
/// Hard-edged zones on the −60..0 dBFS scale using Eclipsa Studio design
/// tokens from [T]: green below [yellowDb], yellow up to [amberDb], amber
/// from there to 0 dBFS. Red is not a level zone: on a meter,
/// `T.meterRed` marks the engine's sticky clip latch (ES-191).
class MeterColors {
  MeterColors._();

  /// Green→yellow zone boundary.
  static const double yellowDb = -18.0;

  /// Yellow→amber zone boundary.
  static const double amberDb = -6.0;

  /// [yellowDb] on the normalized 0..1 meter scale (0.7 on −60..0).
  static final double yellowNorm = DbUtils.normalizeDb(yellowDb);

  /// [amberDb] on the normalized 0..1 meter scale (0.9 on −60..0).
  static final double amberNorm = DbUtils.normalizeDb(amberDb);

  /// Zone color for a normalized level [norm] ∈ [0, 1].
  ///
  /// T.* is read at call time, so callers stay theme-aware as long as
  /// their painter keys repaints on the theme mode.
  static Color zoneColor(double norm) {
    if (norm > amberNorm) return T.meterAmber;
    if (norm > yellowNorm) return T.meterYellow;
    return T.meterGreen;
  }
}

/// Paints a vertical meter bar filled to [norm] (0..1) as up to three
/// solid zone rects: green to −18 dB, yellow to −6 dB, amber above.
///
/// The bar occupies [x]..[x]+[w] horizontally and [top]..[bottom]
/// vertically, with 0 dBFS at [top]. [paint] is mutated (color, fill).
void paintZonedBar(
  Canvas canvas,
  Paint paint,
  double x,
  double w,
  double top,
  double bottom,
  double norm,
) {
  if (norm <= 0) return;
  final h = bottom - top;
  if (h <= 0) return;

  paint.style = PaintingStyle.fill;
  var from = 0.0;
  final zones = [
    (MeterColors.yellowNorm, T.meterGreen),
    (MeterColors.amberNorm, T.meterYellow),
    (1.0, T.meterAmber),
  ];
  for (final (zoneTop, color) in zones) {
    final to = norm < zoneTop ? norm : zoneTop;
    if (to > from) {
      paint.color = color;
      canvas.drawRect(
        Rect.fromLTRB(x, bottom - h * to, x + w, bottom - h * from),
        paint,
      );
    }
    if (norm <= zoneTop) break;
    from = zoneTop;
  }
}
