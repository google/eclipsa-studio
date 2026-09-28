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

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../theme.dart';
import '../waveform/multi_channel_waveform.dart' show standardChannelLabel;
import 'db_utils.dart';
import 'label_painter_cache.dart';
import 'meter_colors.dart';
import 'meter_scale.dart';

/// Memoized [channelLabels] — evaluated in 60 Hz meter builds; the
/// stable identity lets [MultichannelMeterPainter.shouldRepaint]
/// short-circuit via `identical()` inside `listEquals`.
final Map<int, List<String>> _channelLabelsCache = {};

/// Default channel labels for [n] channels, in the engine's output
/// order (OAR / IAMF — see [standardChannelLabel]), falling back to
/// `Ch N` for unmapped counts. The engine renders meters in OAR
/// channel order, so a film-order table here mislabeled 5 of 6 bars
/// on a 5.1 bus (ES-552). Count-ambiguous layouts (8ch is 7.1 or
/// 5.1.2) get the primary layout's labels — call sites that know the
/// layout should pass explicit labels instead (e.g.
/// `OarLayout.speakerLabels`).
List<String> channelLabels(int n) => _channelLabelsCache.putIfAbsent(
  n,
  () => List.unmodifiable(List.generate(n, (i) => standardChannelLabel(i, n))),
);

/// Whether the meter's channel labels must rotate 90° to stay legible:
/// true when the widest label would overflow the per-bar pitch (bar
/// width + gap) and start colliding with its neighbors — e.g. 9.1.6's
/// four-character `Ltss` over 16 narrow bars. The `- 1` demands a
/// little slack before calling a horizontal fit good: a label within
/// 1 px of the pitch would touch its neighbors, so it rotates too.
bool meterLabelsRotate({
  required double maxLabelWidth,
  required double barPitch,
}) => maxLabelWidth > barPitch - 1;

/// How a meter draws its channel labels under the bars.
enum MeterLabelMode { none, horizontal, rotated }

/// Where a meter's channel labels go: [mode], and [rows] of 1 or 2. With
/// two rows, bars 0, 2, 4 … label in the first row and bars 1, 3, 5 …
/// in the second, so labels in the same row are two bar pitches apart.
typedef MeterLabelLayout = ({MeterLabelMode mode, int rows});

/// Picks the label layout for labels of [widths] (one per bar, in bar
/// order) at [barPitch] (bar width + gap), with [lineHeight] the height
/// of one line of label text.
///
/// In order of preference:
///  1. one horizontal row, when the widest label fits the pitch
///     ([meterLabelsRotate]);
///  2. one rotated row, when the pitch is at least one line of text;
///     below that, rotated columns overprint;
///  3. two staggered horizontal rows, when every two labels that share a
///     row fit side by side in two pitches with 1 px to spare. Only
///     same-row neighbours are checked: 9.1.6's `Ltss` and `Rtss` are
///     the widest labels but sit in different rows;
///  4. two staggered rotated rows, when two pitches are at least one
///     line of text;
///  5. no labels.
///
/// At 9.1.6 in the Renderer view (16 bars on a 9.8 px pitch) this gives
/// one rotated row at the Small font size (a 9.0 px line), two
/// horizontal rows at Medium and two rotated rows at Large (ES-795).
MeterLabelLayout meterLabelLayout({
  required List<double> widths,
  required double lineHeight,
  required double barPitch,
}) {
  if (widths.isEmpty) return (mode: MeterLabelMode.none, rows: 1);
  final maxWidth = widths.reduce(math.max);
  if (!meterLabelsRotate(maxLabelWidth: maxWidth, barPitch: barPitch)) {
    return (mode: MeterLabelMode.horizontal, rows: 1);
  }
  if (barPitch >= lineHeight) return (mode: MeterLabelMode.rotated, rows: 1);
  var staggeredFits = true;
  for (var i = 0; i + 2 < widths.length; i++) {
    if ((widths[i] + widths[i + 2]) / 2 > 2 * barPitch - 1) {
      staggeredFits = false;
      break;
    }
  }
  if (staggeredFits) return (mode: MeterLabelMode.horizontal, rows: 2);
  if (2 * barPitch >= lineHeight) {
    return (mode: MeterLabelMode.rotated, rows: 2);
  }
  return (mode: MeterLabelMode.none, rows: 1);
}

/// Vertical multichannel level meter widget.
///
/// Displays per-channel bars with hard green/yellow/amber zones, peak hold
/// lines, clip indicators, channel labels, and a dB scale.
///
/// [levels] — linear amplitudes (0..1+), one per channel.
/// [peaks]  — peak-hold values (0..1+), one per channel. Optional.
/// [clipped] — whether each channel has clipped. Optional.
/// [labels]  — custom channel labels. Defaults to standard names.
/// [onClipClear] — tap handler (typically clears latched clips). Optional.
class MultichannelMeter extends StatelessWidget {
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;
  final List<String>? labels;
  final bool showLabels;
  final VoidCallback? onClipClear;

  const MultichannelMeter({
    super.key,
    required this.levels,
    this.peaks,
    this.clipped,
    this.labels,
    this.showLabels = true,
    this.onClipClear,
  });

  @override
  Widget build(BuildContext context) {
    final meter = RepaintBoundary(
      child: Container(
        decoration: T.decoControl(borderColor: T.border, borderWidth: 0.5),
        child: CustomPaint(
          painter: MultichannelMeterPainter(
            levels: levels,
            peaks: peaks,
            clipped: clipped,
            labels: labels ?? channelLabels(levels.length),
            showLabels: showLabels,
            fontMode: T.fontMode,
            themeMode: T.mode,
          ),
          size: Size.infinite,
        ),
      ),
    );
    if (onClipClear == null) return meter;
    return GestureDetector(onTap: onClipClear, child: meter);
  }
}

/// CustomPainter for the multichannel level meter.
///
/// Suitable for 1–28 channels. Bar widths auto-shrink as channel count rises.
class MultichannelMeterPainter extends CustomPainter {
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;
  final List<String> labels;
  final bool showLabels;

  static const _kPadH = 6.0; // horizontal padding
  static const _kPadV = 6.0; // vertical padding (top)
  static const _kLabelH = 14.0; // height reserved for channel labels
  static const _kMinorTickW = 3.0; // minor scale tick length
  // The dB scale column: labels right-aligned at _kLabelRight, then a
  // minor-tick strip ending at _kTickRight, then a 2 px gap before the
  // first bar. The column is the only place the ticks are drawn, so
  // they never reach into the labels whatever the bar centring.
  static const _kDbScaleW = 25.0; // width of the dB scale column
  static const _kTickRight = _kPadH + _kDbScaleW - 2;
  static const _kLabelRight = _kTickRight - _kMinorTickW - 1;
  static const _kBarGap = 2.0; // gap between bars
  static const _kMaxBarW = 14.0; // max bar width
  static const _kMinBarW = 2.0; // min bar width

  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  // Reused across the whole paint pass instead of allocating per frame.
  final Paint _paint = Paint();

  // Static: a fresh painter is constructed every tick, so instance
  // fields would re-lay-out every label and dB mark at 60 Hz. The
  // caches invalidate on font/theme mode change and re-read T.* then.
  static final _labelPainters = LabelPainterCache(
    () => TextStyle(
      fontSize: T.fontMeter,
      color: T.textTertiary,
      fontFamily: T.monoFamily,
    ),
  );
  static final _dbPainters = LabelPainterCache(
    () => TextStyle(
      fontSize: T.fontMeter,
      color: T.textGhost,
      fontFamily: T.monoFamily,
    ),
  );

  // Which dB labels and minor ticks fit depends only on the bar
  // height and the label height, both constant between resizes and
  // font changes, so a cached layout per (height, label height) serves
  // every frame in between. Several meters of different heights paint
  // each frame, hence a map rather than one entry; it is emptied when
  // a resize drag has filled it.
  static final _layouts = <(double, double), MeterScaleLayout>{};
  static const _kMaxLayouts = 16;

  static MeterScaleLayout _scaleLayout(double barAreaH, double labelH) {
    final key = (barAreaH, labelH);
    final hit = _layouts[key];
    if (hit != null) return hit;
    if (_layouts.length >= _kMaxLayouts) _layouts.clear();
    return _layouts[key] = MeterScaleLayout.fit(
      barAreaH: barAreaH,
      labelH: labelH,
    );
  }

  MultichannelMeterPainter({
    required this.levels,
    this.peaks,
    this.clipped,
    required this.labels,
    this.showLabels = true,
    required this.fontMode,
    required this.themeMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;

    final paint = _paint
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0;

    // ── Layout ──────────────────────────────────────────────────────────────
    final barAreaW = size.width - _kPadH * 2 - _kDbScaleW;
    if (barAreaW <= 0) return;

    final rawBarW = (barAreaW - (n - 1) * _kBarGap) / n;
    final barW = rawBarW.clamp(_kMinBarW, _kMaxBarW);

    // Measure the labels up front and pick where they go
    // ([meterLabelLayout]): one row, horizontal or rotated 90° to read
    // top-down, or two staggered rows when the bars are too dense for
    // one (9.1.6's 16 bars, ES-795). The label strip grows to fit.
    var labelLineH = 0.0;
    final labelPainters = <TextPainter>[];
    if (showLabels) {
      for (var i = 0; i < n; i++) {
        final label = i < labels.length ? labels[i] : '${i + 1}';
        final tp = _labelPainters.painterFor(label, fontMode, themeMode);
        labelPainters.add(tp);
        labelLineH = math.max(labelLineH, tp.height);
      }
    }
    final labelLayout = showLabels
        ? meterLabelLayout(
            widths: [for (final tp in labelPainters) tp.width],
            lineHeight: labelLineH,
            barPitch: barW + _kBarGap,
          )
        : (mode: MeterLabelMode.none, rows: 1);
    var drawLabels = labelLayout.mode != MeterLabelMode.none;
    final rotateLabels = labelLayout.mode == MeterLabelMode.rotated;
    final staggered = labelLayout.rows == 2;
    // Rotated labels run down the screen, so a row is as tall as its
    // widest label; row 1 starts below row 0.
    var row0MaxW = 0.0;
    var row1MaxW = 0.0;
    if (rotateLabels) {
      for (var i = 0; i < labelPainters.length; i++) {
        final w = labelPainters[i].width;
        if (staggered && i.isOdd) {
          row1MaxW = math.max(row1MaxW, w);
        } else {
          row0MaxW = math.max(row0MaxW, w);
        }
      }
    }
    final rotatedRow1Y = row0MaxW + 3;
    // Labels start 3 px under the bars; each strip keeps 2 px spare.
    var labelH = switch ((drawLabels, rotateLabels, staggered)) {
      (false, _, _) => 0.0,
      (true, false, false) => _kLabelH,
      (true, false, true) => 3 + 2 * labelLineH + 2,
      (true, true, false) => row0MaxW + 5,
      (true, true, true) => rotatedRow1Y + row1MaxW + 5,
    };
    var barAreaH = size.height - _kPadV * 2 - labelH;
    // A grown (rotated or two-row) label strip must never blank the
    // meter outright on a short panel that used to render: give the
    // height back to the bars and skip the labels.
    if (barAreaH <= 0 && labelH > 0) {
      drawLabels = false;
      labelH = 0.0;
      barAreaH = size.height - _kPadV * 2;
    }
    if (barAreaH <= 0) return;
    final totalBarsW = n * barW + (n - 1) * _kBarGap;
    final startX = _kPadH + _kDbScaleW + (barAreaW - totalBarsW) / 2;
    final startY = _kPadV;
    final endY = startY + barAreaH;

    // ── Background ───────────────────────────────────────────────────────────
    paint.color = T.bgControls;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    // ── dB scale + grid lines ────────────────────────────────────────────────
    paint
      ..color = T.border
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    double yOf(int db) =>
        startY + barAreaH * (1 - DbUtils.normalizeDb(db.toDouble()));
    final dbLabelH = _dbPainters.painterFor('0', fontMode, themeMode).height;
    final layout = _scaleLayout(barAreaH, dbLabelH);

    // Majors: a grid line across the bars for every one, a label for
    // those the layout found room for.
    for (final db in MeterScale.majorDb) {
      final y = yOf(db);
      canvas.drawLine(
        Offset(startX - 2, y),
        Offset(startX + totalBarsW, y),
        paint,
      );
    }
    for (final db in layout.labels) {
      final tp = _dbPainters.painterFor('$db', fontMode, themeMode);
      tp.paint(
        canvas,
        Offset(_kLabelRight - tp.width, yOf(db) - tp.height / 2),
      );
    }

    // Minors: short ticks at the right edge of the scale column, to
    // the right of the labels and left of the bars; no label, no grid
    // line.
    for (final db in layout.minors) {
      final y = yOf(db);
      canvas.drawLine(
        Offset(_kTickRight - _kMinorTickW, y),
        Offset(_kTickRight, y),
        paint,
      );
    }

    paint.style = PaintingStyle.fill;

    // ── Bars ─────────────────────────────────────────────────────────────────
    for (var i = 0; i < n; i++) {
      final x = startX + i * (barW + _kBarGap);
      final level = levels[i].clamp(0.0, 2.0);
      final norm = DbUtils.linearToNormalized(level);
      final isClipped = clipped != null && i < clipped!.length
          ? clipped![i]
          : level >= 1.0;

      // Track background
      paint.color = T.bgDeep;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, startY, barW, barAreaH),
          const Radius.circular(1),
        ),
        paint,
      );

      // Fill — hard-edged green/yellow/amber zones; red is the clip latch
      paintZonedBar(canvas, paint, x, barW, startY, endY, norm);

      // Peak hold line
      if (peaks != null && i < peaks!.length && peaks![i] > 0) {
        final peakNorm = DbUtils.linearToNormalized(peaks![i]);
        if (peakNorm > 0) {
          final py = endY - barAreaH * peakNorm;
          paint.color = MeterColors.zoneColor(peakNorm).withValues(alpha: 0.9);
          paint.strokeWidth = 1.0;
          paint.style = PaintingStyle.stroke;
          canvas.drawLine(Offset(x, py), Offset(x + barW, py), paint);
          paint.style = PaintingStyle.fill;
        }
      }

      // Clip indicator — red rectangle at top, the only red on the meter
      if (isClipped) {
        paint.color = T.meterRed;
        canvas.drawRect(Rect.fromLTWH(x, startY - 1, barW, 3), paint);
      }

      // Channel label — horizontal under the bar or rotated 90°, in
      // the second row for odd bars when the labels are staggered.
      if (drawLabels) {
        final tp = labelPainters[i];
        final secondRow = staggered && i.isOdd;
        if (rotateLabels) {
          // Read top-down: after the +90° rotation the text's advance
          // runs down the screen from the translate point and its
          // height extends left, so offsetting by +height/2 centers
          // the glyph column on the bar.
          canvas.save();
          canvas.translate(
            x + (barW + tp.height) / 2,
            endY + 3 + (secondRow ? rotatedRow1Y : 0),
          );
          canvas.rotate(math.pi / 2);
          tp.paint(canvas, Offset.zero);
          canvas.restore();
        } else {
          // Centered on the bar, but kept inside the meter: a staggered
          // label can be twice the pitch wide, so the last bar's label
          // can run past the right edge. A shift eats into the 1 px that
          // meterLabelLayout left beside the same-row neighbour; at 9.1.6
          // in the Renderer view no label is shifted.
          final maxX = math.max(0.0, size.width - tp.width);
          final lx = (x + (barW - tp.width) / 2).clamp(0.0, maxX);
          tp.paint(canvas, Offset(lx, endY + 3 + (secondRow ? labelLineH : 0)));
        }
      }
    }
  }

  @override
  bool shouldRepaint(MultichannelMeterPainter old) =>
      old.levels != levels ||
      old.peaks != peaks ||
      old.clipped != clipped ||
      !listEquals(old.labels, labels) ||
      old.showLabels != showLabels ||
      old.fontMode != fontMode ||
      old.themeMode != themeMode;
}
