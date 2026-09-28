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

import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import '../theme.dart';
import 'peak_data.dart';
import 'waveform_style.dart';

/// Custom painter that renders a single channel waveform from peak data.
///
/// Optimized for large files: draws one vertical line per pixel using
/// pre-computed peak data. Supports mirrored (bipolar) and absolute modes.
class WaveformPainter extends CustomPainter {
  final ChannelPeaks peaks;
  final WaveformStyle style;
  final int startPeak;
  final int endPeak;

  /// Linear multiplier applied to every peak amplitude (min/max/rms)
  /// before mapping to canvas Y. Used to reflect pre-IAMF gain visually.
  /// 1.0 = identity (raw peaks). Values >1.0 may overflow the widget
  /// bounds — clipping is handled by the parent ClipRect.
  final double amplitudeScale;

  /// Repaint key only — [WaveformStyle]'s unset colors resolve against
  /// the active theme at paint time, so a theme switch must invalidate
  /// the previous frame even when the style object itself is identical
  /// (e.g. the canonicalized `const WaveformStyle()` default).
  final AppThemeMode themeMode;

  WaveformPainter({
    required this.peaks,
    this.style = const WaveformStyle(),
    this.startPeak = 0,
    int? endPeak,
    this.amplitudeScale = 1.0,
    AppThemeMode? themeMode,
  }) : endPeak = endPeak ?? peaks.length,
       themeMode = themeMode ?? T.mode;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (peaks.length == 0) return;

    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;
    final wCeil = w.ceil();

    // Read the clip bounds *before* pushing our own clip (borderRadius),
    // so we see the parent's clip region, not our own narrowed one.
    final clip = canvas.getLocalClipBounds();
    final pxStart = clip.left.floor().clamp(0, wCeil);
    final pxEnd = clip.right.ceil().clamp(0, wCeil);
    if (pxStart >= pxEnd) return;

    if (style.borderRadius > 0) {
      canvas.save();
      canvas.clipRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(style.borderRadius)),
      );
    }

    if (style.backgroundColor != null) {
      canvas.drawRect(rect, Paint()..color = style.backgroundColor!);
    }

    final mid = style.mirrored ? h / 2 : h;
    final visiblePeaks = endPeak - startPeak;
    if (visiblePeaks <= 0) return;

    final wavePath = ui.Path();
    final rmsPath = style.rmsColor != null ? ui.Path() : null;

    if (style.mirrored) {
      _drawMirrored(
        canvas,
        wavePath,
        rmsPath,
        w,
        h,
        mid,
        visiblePeaks,
        pxStart,
        pxEnd,
      );
    } else {
      _drawAbsolute(canvas, wavePath, w, h, visiblePeaks, pxStart, pxEnd);
    }

    final wavePaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = style.antiAlias;

    if (style.waveGradient != null) {
      wavePaint.shader = style.waveGradient!.createShader(rect);
    } else {
      wavePaint.color = style.waveColor.withValues(alpha: style.opacity);
    }

    canvas.drawPath(wavePath, wavePaint);

    if (rmsPath != null && style.rmsColor != null) {
      canvas.drawPath(
        rmsPath,
        Paint()
          ..style = PaintingStyle.fill
          ..color = style.rmsColor!
          ..isAntiAlias = style.antiAlias,
      );
    }

    if (style.mirrored) {
      canvas.drawLine(
        Offset(0, mid),
        Offset(w, mid),
        Paint()
          ..color = style.centerlineColor
          ..strokeWidth = 0.5,
      );
    }

    if (style.borderRadius > 0) canvas.restore();
  }

  void _drawMirrored(
    Canvas canvas,
    ui.Path wavePath,
    ui.Path? rmsPath,
    double w,
    double h,
    double mid,
    int visiblePeaks,
    int pxStart,
    int pxEnd,
  ) {
    wavePath.moveTo(pxStart.toDouble(), mid);
    for (var px = pxStart; px < pxEnd; px++) {
      final peak = _peakForPixel(px, w, visiblePeaks);
      if (peak == null) break;
      final y = mid - (peak.max.abs() * amplitudeScale * mid);
      wavePath.lineTo(px.toDouble(), y);
    }
    wavePath.lineTo(pxEnd.toDouble(), mid);

    for (var px = pxEnd - 1; px >= pxStart; px--) {
      final peak = _peakForPixel(px, w, visiblePeaks);
      if (peak == null) continue;
      final y = mid + (peak.min.abs() * amplitudeScale * mid);
      wavePath.lineTo(px.toDouble(), y);
    }
    wavePath.close();

    if (rmsPath != null) {
      rmsPath.moveTo(pxStart.toDouble(), mid);
      for (var px = pxStart; px < pxEnd; px++) {
        final peak = _peakForPixel(px, w, visiblePeaks);
        if (peak == null) break;
        rmsPath.lineTo(px.toDouble(), mid - peak.rms * amplitudeScale * mid);
      }
      rmsPath.lineTo(pxEnd.toDouble(), mid);
      for (var px = pxEnd - 1; px >= pxStart; px--) {
        final peak = _peakForPixel(px, w, visiblePeaks);
        if (peak == null) continue;
        rmsPath.lineTo(px.toDouble(), mid + peak.rms * amplitudeScale * mid);
      }
      rmsPath.close();
    }
  }

  void _drawAbsolute(
    Canvas canvas,
    ui.Path path,
    double w,
    double h,
    int visiblePeaks,
    int pxStart,
    int pxEnd,
  ) {
    path.moveTo(pxStart.toDouble(), h);
    for (var px = pxStart; px < pxEnd; px++) {
      final peak = _peakForPixel(px, w, visiblePeaks);
      if (peak == null) break;
      final y = h - (peak.amplitude * amplitudeScale * h);
      path.lineTo(px.toDouble(), y);
    }
    path.lineTo(pxEnd.toDouble(), h);
    path.close();
  }

  /// Returns the merged min/max across all peak buckets that map to [px].
  /// When zoomed out, multiple buckets fall on one pixel — scanning the
  /// full range ensures transients (clicks, impulses) are never skipped.
  Peak? _peakForPixel(int px, double w, int visiblePeaks) {
    final lo = startPeak + (px * visiblePeaks / w).floor();
    if (lo >= endPeak) return null;
    final hi = startPeak + ((px + 1) * visiblePeaks / w).floor();
    final end = hi.clamp(lo + 1, endPeak);
    if (end - lo == 1) {
      return peaks[lo.clamp(0, peaks.length - 1)];
    }
    return peaks.rangeMinMax(
      lo.clamp(0, peaks.length),
      end.clamp(0, peaks.length),
    );
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.startPeak != startPeak ||
        oldDelegate.endPeak != endPeak ||
        oldDelegate.style != style ||
        oldDelegate.amplitudeScale != amplitudeScale ||
        oldDelegate.themeMode != themeMode;
  }
}
