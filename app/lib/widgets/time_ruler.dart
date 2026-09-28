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

import 'dart:ui' show Gradient;

import 'package:flutter/material.dart' hide Gradient;

import '../theme.dart';

/// The time ruler's strip: its height and ground per [ChromeStyle], and
/// the ruler painted across it. The Elements view hosts the painter
/// inside its own gesture handling; the Theme Gallery renders this
/// widget with fixed values.
///
/// Every style draws the strip [height] 32 px tall.
///
/// - `recessed`: on `bgSurface`.
/// - `beveled`, `raised` and `outlined`: on the page ground, `bgBase`.
class TimeRulerStrip extends StatelessWidget {
  const TimeRulerStrip({
    super.key,
    required this.durationSeconds,
    required this.playheadSeconds,
    this.zoomLevel = 1,
    this.scrollOffset = 0,
  });

  final double durationSeconds;
  final double playheadSeconds;
  final double zoomLevel;
  final double scrollOffset;

  /// Height of the strip, the same in every theme; a component's size
  /// does not vary by theme, only how it is drawn and coloured.
  static const double height = 32;

  /// Ground of the strip.
  static Color get ground => switch (T.chromeStyle) {
    ChromeStyle.recessed => T.bgSurface,
    ChromeStyle.beveled ||
    ChromeStyle.raised ||
    ChromeStyle.outlined => T.bgBase,
  };

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    color: ground,
    child: CustomPaint(
      painter: TimeRulerPainter(
        durationSeconds: durationSeconds,
        zoomLevel: zoomLevel,
        scrollOffset: scrollOffset,
        playheadSeconds: playheadSeconds,
        fontMode: T.fontMode,
        themeMode: T.mode,
      ),
      size: Size.infinite,
    ),
  );
}

/// Ticks, labels and the playhead's head, painted across the ruler's
/// visible time window. The tick interval comes from the zoom level
/// (about eight labelled ticks in view, four subdivisions each) in every
/// style; the drawing of a tick, a label and the head is the style's:
///
/// Every style draws 2 px `rulerTick` ticks and `rulerLabel` labels at
/// `fontBody`.
///
/// - `recessed` and `outlined`: ticks 12 px labelled and 6 px between;
///   labels 4 px from the top. `recessed` draws a 10 x 8 `playhead`
///   triangle, `outlined` the raised style's pentagon.
/// - `beveled`: 2 px ticks, 13 px labelled and 8 px between; labels 1 px from
///   the top with tracking 0.36; a 13 x 12 pentagon head.
/// - `raised`: 2 px ticks fading to 70% downward, 8 px labelled and 3 px
///   between; labels at the top; a 12 x 12 pentagon head. Labels are `fontBody`.
///
/// The playhead's line is [PlayheadPainter]'s, spanning the tracks.
class TimeRulerPainter extends CustomPainter {
  final double durationSeconds;
  final double zoomLevel;
  final double scrollOffset;
  final double playheadSeconds;
  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  TimeRulerPainter({
    required this.durationSeconds,
    required this.zoomLevel,
    required this.scrollOffset,
    required this.playheadSeconds,
    required this.fontMode,
    required this.themeMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationSeconds <= 0 || zoomLevel <= 0) return;

    final style = T.chromeStyle;
    final textStyle = TextStyle(
      fontSize: T.fontBody,
      color: T.rulerLabel,
      letterSpacing: style == ChromeStyle.beveled ? 0.36 : null,
    );
    final labelTop = switch (style) {
      ChromeStyle.recessed || ChromeStyle.outlined => 4.0,
      ChromeStyle.beveled => 1.0,
      ChromeStyle.raised => 0.0,
    };
    final (majorTick, minorTick) = switch (style) {
      ChromeStyle.recessed || ChromeStyle.outlined => (12.0, 6.0),
      ChromeStyle.beveled => (13.0, 8.0),
      ChromeStyle.raised => (8.0, 3.0),
    };
    // One paint per tick height, built once. Every tick of a height
    // spans the same rows, so a raised tick's fade is one shader shared
    // by all of them.
    final majorPaint = _tickPaint(size.height, majorTick, style);
    final minorPaint = _tickPaint(size.height, minorTick, style);

    // Visible time window based on zoom and scroll
    final visibleDuration = durationSeconds / zoomLevel;
    if (!visibleDuration.isFinite || visibleDuration <= 0) return;

    final startTime = scrollOffset * (durationSeconds - visibleDuration);
    final endTime = startTime + visibleDuration;

    // Choose a nice tick interval based on visible duration
    final interval = _niceInterval(visibleDuration);
    final subInterval = interval / 4;

    // Index-based iteration avoids floating-point drift
    final firstIdx = (startTime / subInterval).floor();
    final lastIdx = ((endTime + interval) / subInterval).ceil();

    for (var i = firstIdx; i <= lastIdx; i++) {
      final t = i * subInterval;
      if (t < 0) continue;
      final x = ((t - startTime) / visibleDuration) * size.width;
      if (x < -20 || x > size.width + 20) continue;

      final isMajor = i % 4 == 0;
      final h = isMajor ? majorTick : minorTick;
      canvas.drawRect(
        Rect.fromLTWH(x - 1, size.height - h, 2, h),
        isMajor ? majorPaint : minorPaint,
      );

      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(text: _formatTime(t), style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, labelTop));
        tp.dispose();
      }
    }

    // Playhead head only; the line is PlayheadPainter's. Culled a pixel
    // beyond the head's own half-width, so each style's head is drawn
    // exactly while any part of it is in the strip.
    final px = ((playheadSeconds - startTime) / visibleDuration) * size.width;
    final margin = playheadHead(0, style).getBounds().width / 2 + 1;
    if (px >= -margin && px <= size.width + margin) {
      canvas.drawPath(playheadHead(px, style), Paint()..color = T.playhead);
    }
  }

  /// The paint for a 2 px tick of height [h] at the bottom of a strip
  /// [height] tall. The raised style's ticks run from `#393834` at the
  /// top to `#2D2C29` at the bottom over the `#101010` ground, a fade
  /// to 70%.
  static Paint _tickPaint(double height, double h, ChromeStyle style) {
    final paint = Paint()..color = T.rulerTick;
    if (style == ChromeStyle.raised) {
      paint.shader = Gradient.linear(Offset(0, height - h), Offset(0, height), [
        T.rulerTick,
        T.rulerTick.withValues(alpha: 0.7),
      ]);
    }
    return paint;
  }

  /// The head at the top of the ruler, centred on [px]: the recessed
  /// style's triangle, or the other styles' pentagon (a rectangle whose
  /// lower corners taper to a point).
  static Path playheadHead(double px, ChromeStyle style) => switch (style) {
    ChromeStyle.recessed =>
      Path()
        ..moveTo(px - 5, 0)
        ..lineTo(px + 5, 0)
        ..lineTo(px, 8)
        ..close(),
    // Beveled: 13.26 wide, the rectangle to 6.84, the point at 12.26.
    ChromeStyle.beveled =>
      Path()
        ..moveTo(px - 6.5, 0)
        ..lineTo(px + 6.5, 0)
        ..lineTo(px + 6.5, 7)
        ..lineTo(px, 12)
        ..lineTo(px - 6.5, 7)
        ..close(),
    // Raised: 12 wide, the rectangle to 6.69, the point at 12.
    // High Contrast takes the same head at its 2 px line width.
    ChromeStyle.raised || ChromeStyle.outlined =>
      Path()
        ..moveTo(px - 6, 0)
        ..lineTo(px + 6, 0)
        ..lineTo(px + 6, 6.7)
        ..lineTo(px, 12)
        ..lineTo(px - 6, 6.7)
        ..close(),
  };

  /// Pick a round interval for the visible time range.
  static double _niceInterval(double visibleSeconds) {
    // Target ~6-10 major ticks visible
    final raw = visibleSeconds / 8;
    const steps = [
      0.1,
      0.25,
      0.5,
      1.0,
      2.0,
      5.0,
      10.0,
      15.0,
      30.0,
      60.0,
      120.0,
      300.0,
      600.0,
    ];
    for (final s in steps) {
      if (s >= raw) return s;
    }
    return 600.0;
  }

  static String _formatTime(double t) {
    final m = (t / 60).floor();
    final s = t % 60;
    final si = s.floor();
    final frac = s - si;
    if (m > 0) {
      final pad = si.toString().padLeft(2, '0');
      if (frac.abs() < 0.001) return '$m:$pad';
      return '$m:$pad.${(frac * 10).round()}';
    }
    if (frac.abs() < 0.001) return '${si}s';
    return '${s.toStringAsFixed(1)}s';
  }

  @override
  bool shouldRepaint(TimeRulerPainter oldDelegate) =>
      oldDelegate.durationSeconds != durationSeconds ||
      oldDelegate.zoomLevel != zoomLevel ||
      oldDelegate.scrollOffset != scrollOffset ||
      oldDelegate.playheadSeconds != playheadSeconds ||
      oldDelegate.fontMode != fontMode ||
      oldDelegate.themeMode != themeMode;
}

/// The playhead's vertical line, spanning the ruler and every track:
/// 1.5 px in the recessed style, 1 px in the beveled style and 2 px in
/// the raised and outlined styles, in `playhead`.
class PlayheadPainter extends CustomPainter {
  final double durationSeconds;
  final double playheadSeconds;
  final double zoomLevel;
  final double scrollOffset;
  final Color color;
  final ChromeStyle style;

  /// Line width per [style].
  static double widthFor(ChromeStyle style) => switch (style) {
    ChromeStyle.recessed => 1.5,
    ChromeStyle.beveled => 1.0,
    ChromeStyle.raised || ChromeStyle.outlined => 2.0,
  };

  /// High Contrast's playhead is `#FFD60A` over waveforms that can be the
  /// same yellow (`typeChannel` is `#FBBF24`), so its line is drawn
  /// over a casing 2 px wider in `bgDeep`. Null where no casing is
  /// drawn.
  static double? casingFor(ChromeStyle style) =>
      style == ChromeStyle.outlined ? widthFor(style) + 2 : null;

  // Cached paint — safe because the painter is recreated when color or
  // style changes (see shouldRepaint).
  late final _paint = Paint()
    ..color = color
    ..strokeWidth = widthFor(style);

  PlayheadPainter({
    required this.durationSeconds,
    required this.playheadSeconds,
    required this.zoomLevel,
    required this.scrollOffset,
    required this.color,
    required this.style,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationSeconds <= 0 || size.width <= 0) return;
    final visibleDuration = durationSeconds / zoomLevel;
    final startTime = scrollOffset * (durationSeconds - visibleDuration);
    final px = ((playheadSeconds - startTime) / visibleDuration) * size.width;
    if (px < -1 || px > size.width + 1) return;
    final casing = casingFor(style);
    if (casing != null) {
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = T.bgDeep
          ..strokeWidth = casing,
      );
    }
    canvas.drawLine(Offset(px, 0), Offset(px, size.height), _paint);
  }

  @override
  bool shouldRepaint(PlayheadPainter old) =>
      old.playheadSeconds != playheadSeconds ||
      old.durationSeconds != durationSeconds ||
      old.zoomLevel != zoomLevel ||
      old.scrollOffset != scrollOffset ||
      old.color != color ||
      old.style != style;
}
