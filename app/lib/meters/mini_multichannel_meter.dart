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
import 'meter_colors.dart';

/// Compact multichannel meter for the sidebar element cards.
///
/// Shows one thin vertical bar per channel with hard green/yellow/amber
/// zones, optional peak-hold lines, and clip indicator dots. No labels or
/// dB scale — too small for that.
///
/// [levels]  — linear amplitudes (0..1+), one per channel.
/// [peaks]   — peak-hold values (0..1+), one per channel. Optional.
/// [clipped] — per-channel clip flags. Optional.
/// [onClipClear] — tap handler (typically clears latched clips). Optional.
class MiniMultichannelMeter extends StatelessWidget {
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;
  final VoidCallback? onClipClear;

  const MiniMultichannelMeter({
    super.key,
    required this.levels,
    this.peaks,
    this.clipped,
    this.onClipClear,
  });

  @override
  Widget build(BuildContext context) {
    final meter = RepaintBoundary(
      child: CustomPaint(
        painter: MiniMultichannelMeterPainter(
          levels: levels,
          peaks: peaks,
          clipped: clipped,
          themeMode: T.mode,
        ),
        size: Size.infinite,
      ),
    );
    if (onClipClear == null) return meter;
    return GestureDetector(onTap: onClipClear, child: meter);
  }
}

/// CustomPainter for the compact sidebar multichannel meter.
class MiniMultichannelMeterPainter extends CustomPainter {
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;

  /// Repaint key only — paint() reads T.* at paint time, so a theme
  /// switch must invalidate the previous frame.
  final AppThemeMode themeMode;

  // Layout constants
  static const _kMaxBarW = 6.0;
  static const _kMinBarW = 1.5;
  static const _kGap = 1.0;
  static const _kClipDotR = 1.5;

  // Reused across the whole paint pass instead of allocating per frame.
  final Paint _paint = Paint();

  MiniMultichannelMeterPainter({
    required this.levels,
    this.peaks,
    this.clipped,
    required this.themeMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;

    final paint = _paint
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0;

    // ── Layout ───────────────────────────────────────────────────────────────
    // Reserve top 4px for clip dots.
    const clipDotAreaH = _kClipDotR * 2 + 2.0;
    final barAreaH = size.height - clipDotAreaH;
    if (barAreaH <= 0) return;

    final rawBarW = (size.width - (n - 1) * _kGap) / n;
    final barW = rawBarW.clamp(_kMinBarW, _kMaxBarW);
    final totalW = n * barW + (n - 1) * _kGap;
    final startX = (size.width - totalW) / 2;
    final barTop = clipDotAreaH;
    final barBot = size.height;

    // ── Bars ─────────────────────────────────────────────────────────────────
    for (var i = 0; i < n; i++) {
      final x = startX + i * (barW + _kGap);
      final level = levels[i].clamp(0.0, 2.0);
      final norm = DbUtils.linearToNormalized(level);
      final isClipped = clipped != null && i < clipped!.length
          ? clipped![i]
          : level >= 1.0;

      // Track. The `raised` style runs the track at `bgElevated` over
      // the panel ground, the relation of `#202020` over `#282828`;
      // every other theme keeps the deepest ground.
      //
      // The bar and peak line keep the green / yellow / amber zones
      // and the red clip dot rather than one flat accent such as
      // `#8EAADC`: the zones are a level reading, and a single accent
      // would drop it.
      paint.color = T.chromeStyle == ChromeStyle.raised
          ? T.bgElevated
          : T.bgDeep;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, barTop, barW, barAreaH),
          const Radius.circular(1),
        ),
        paint,
      );

      // Filled portion — green/yellow/amber zones; red is the clip dot only
      paintZonedBar(canvas, paint, x, barW, barTop, barBot, norm);

      // Peak hold line
      if (peaks != null && i < peaks!.length && peaks![i] > 0) {
        final peakNorm = DbUtils.linearToNormalized(peaks![i]);
        if (peakNorm > 0) {
          final py = barBot - barAreaH * peakNorm;
          paint
            ..color = MeterColors.zoneColor(peakNorm).withValues(alpha: 0.85)
            ..strokeWidth = 1.0
            ..style = PaintingStyle.stroke;
          canvas.drawLine(Offset(x, py), Offset(x + barW, py), paint);
          paint.style = PaintingStyle.fill;
        }
      }

      // Clip indicator dot
      if (isClipped) {
        paint.color = T.meterRed;
        paint.style = PaintingStyle.fill;
        canvas.drawCircle(Offset(x + barW / 2, _kClipDotR), _kClipDotR, paint);
      }
    }
  }

  @override
  bool shouldRepaint(MiniMultichannelMeterPainter old) =>
      old.levels != levels ||
      old.peaks != peaks ||
      old.clipped != clipped ||
      old.themeMode != themeMode;
}
