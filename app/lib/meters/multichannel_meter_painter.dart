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
/// four-character `Lts` over 16 narrow bars. The `- 1` demands a
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
///     same-row neighbours are checked: 9.1.6's `Lss`, `Rss`, `Lrs`,
///     `Rrs`, `Lts` and `Rts` are the widest labels, and each pair
///     sits in different rows;
///  4. two staggered rotated rows, when two pitches are at least one
///     line of text;
///  5. no labels.
///
/// At 9.1.6 in the Renderer view (16 bars on a 9.8 px pitch) this gives
/// one rotated row at the Small font size (a 9.0 px line) and two
/// horizontal rows at Medium and Large (ES-795, ES-960).
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

/// A channel label under the pointer ([MultichannelMeterPainter.labelAt]):
/// the channel, the rect its label is drawn in, and the top of the label
/// strip, the bottom edge of the bars.
typedef MeterLabelHit = ({int channel, Rect rect, double stripTop});

/// Vertical multichannel level meter widget.
///
/// Displays per-channel bars with hard green/yellow/amber zones, peak hold
/// lines, clip indicators, channel labels, and a dB scale.
///
/// [levels] — linear amplitudes (0..1+), one per channel.
/// [peaks]  — peak-hold values (0..1+), one per channel. Optional.
/// [clipped] — whether each channel has clipped. Optional.
/// [labels]  — custom channel labels. Defaults to standard names.
/// [labelColors] — per-channel label colours. Optional.
/// [onClipClear] — tap handler (typically clears latched clips). Optional.
/// [onLabelHover] — pointer-over-label handler. Optional.
class MultichannelMeter extends StatelessWidget {
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;
  final List<String>? labels;
  final bool showLabels;
  final VoidCallback? onClipClear;

  /// The colour of each channel's label, by channel; a null entry, or a
  /// null list, draws that label in the default colour.
  final List<Color?>? labelColors;

  /// Called as the pointer moves over the meter with the label under it,
  /// in the meter's own coordinates, and with null when it is over no
  /// label or leaves the meter.
  final ValueChanged<MeterLabelHit?>? onLabelHover;

  const MultichannelMeter({
    super.key,
    required this.levels,
    this.peaks,
    this.clipped,
    this.labels,
    this.showLabels = true,
    this.onClipClear,
    this.labelColors,
    this.onLabelHover,
  });

  @override
  Widget build(BuildContext context) {
    final painter = MultichannelMeterPainter(
      levels: levels,
      peaks: peaks,
      clipped: clipped,
      // The painter reads no labels when [showLabels] is false.
      labels: labels ?? (showLabels ? channelLabels(levels.length) : const []),
      labelColors: labelColors,
      showLabels: showLabels,
      fontMode: T.fontMode,
      themeMode: T.mode,
    );
    final paintedBars = CustomPaint(painter: painter, size: Size.infinite);
    final onLabelHover = this.onLabelHover;
    Widget bars = paintedBars;
    if (onLabelHover != null) {
      final meterContext = context;
      bars = Builder(
        builder: (context) => MouseRegion(
          onHover: (event) {
            final box = context.findRenderObject() as RenderBox?;
            final meter = meterContext.findRenderObject() as RenderBox?;
            final hit = box == null || meter == null || !box.hasSize
                ? null
                : painter.labelAt(event.localPosition, box.size);
            if (hit == null) {
              onLabelHover(null);
              return;
            }
            // From the bars' coordinates to the meter's, inside its frame.
            final shift = box!.localToGlobal(Offset.zero, ancestor: meter);
            onLabelHover((
              channel: hit.channel,
              rect: hit.rect.shift(shift),
              stripTop: hit.stripTop + shift.dy,
            ));
          },
          onExit: (_) => onLabelHover(null),
          child: paintedBars,
        ),
      );
    }
    final meter = RepaintBoundary(
      child: Container(
        decoration: T.decoControl(borderColor: T.border, borderWidth: 0.5),
        child: bars,
      ),
    );
    if (onClipClear == null) return meter;
    return GestureDetector(onTap: onClipClear, child: meter);
  }
}

/// CustomPainter for the multichannel level meter.
///
/// Suitable for 1–28 channels. Bar widths auto-shrink as channel count rises.
///
/// Paints no background. The `decoControl` frame around it in
/// [MultichannelMeter] paints `bgControls` inside its rounded border; a
/// square fill here paints over the border's rounded corners.
class MultichannelMeterPainter extends CustomPainter {
  final List<double> levels;
  final List<double>? peaks;
  final List<bool>? clipped;
  final List<String> labels;
  final bool showLabels;

  /// The colour of each channel's label, by channel; a null entry, or a
  /// null list, draws that label in [T.textTertiary].
  final List<Color?>? labelColors;

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
  // One cache per colour passed in [labelColors]: the solo and mute
  // colours of the themes in use, so a handful of entries; emptied if a
  // caller passes more colours than that.
  static final _tintedLabelPainters = <Color, LabelPainterCache>{};
  static const _kMaxTintedCaches = 8;
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
    this.labelColors,
    this.showLabels = true,
    required this.fontMode,
    required this.themeMode,
  });

  /// The layout [paint] draws in a meter of [size]; null when the bars
  /// do not fit.
  _MeterLayout? _layout(Size size) {
    final n = levels.length;
    if (n == 0) return null;
    final barAreaW = size.width - _kPadH * 2 - _kDbScaleW;
    if (barAreaW <= 0) return null;

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
        final tp = _labelPainters.painterFor(
          _labelText(i),
          fontMode,
          themeMode,
        );
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
    if (barAreaH <= 0) return null;
    final totalBarsW = n * barW + (n - 1) * _kBarGap;
    final startX = _kPadH + _kDbScaleW + (barAreaW - totalBarsW) / 2;
    final startY = _kPadV;
    final endY = startY + barAreaH;
    return _MeterLayout(
      barW: barW,
      startX: startX,
      totalBarsW: totalBarsW,
      startY: startY,
      endY: endY,
      barAreaH: barAreaH,
      labelPainters: labelPainters,
      labelLineH: labelLineH,
      drawLabels: drawLabels,
      rotateLabels: rotateLabels,
      staggered: staggered,
      rotatedRow1Y: rotatedRow1Y,
    );
  }

  String _labelText(int i) => i < labels.length ? labels[i] : '${i + 1}';

  /// The painter for channel [i]'s label: the shared one, or one in its
  /// [labelColors] entry. Both have the same metrics.
  TextPainter _labelPainter(int i) {
    final color = labelColors != null && i < labelColors!.length
        ? labelColors![i]
        : null;
    if (color != null &&
        _tintedLabelPainters.length >= _kMaxTintedCaches &&
        !_tintedLabelPainters.containsKey(color)) {
      for (final cache in _tintedLabelPainters.values) {
        cache.dispose();
      }
      _tintedLabelPainters.clear();
    }
    final cache = color == null
        ? _labelPainters
        : _tintedLabelPainters.putIfAbsent(
            color,
            () => LabelPainterCache(
              () => TextStyle(
                fontSize: T.fontMeter,
                color: color,
                fontFamily: T.monoFamily,
              ),
            ),
          );
    return cache.painterFor(_labelText(i), fontMode, themeMode);
  }

  /// The label under [position] in a meter of [size], in the painter's
  /// coordinates; null when no label is there. A label's hit area spans
  /// its drawn text and its bar's column, grown by 2 px above and below,
  /// except where two staggered rows meet, so the rows never overlap.
  MeterLabelHit? labelAt(Offset position, Size size) {
    final l = _layout(size);
    if (l == null || !l.drawLabels) return null;
    for (var i = 0; i < l.labelPainters.length; i++) {
      final rect = _labelRect(l, i, size);
      final x = l.startX + i * (l.barW + _kBarGap);
      final secondRow = l.staggered && i.isOdd;
      final hit = Rect.fromLTRB(
        math.min(rect.left, x - _kBarGap / 2),
        rect.top - (secondRow ? 0 : 2),
        math.max(rect.right, x + l.barW + _kBarGap / 2),
        rect.bottom + (l.staggered && !secondRow ? 0 : 2),
      );
      if (hit.contains(position)) {
        return (channel: i, rect: rect, stripTop: l.endY);
      }
    }
    return null;
  }

  /// Where channel [i]'s label is drawn: under its bar, horizontal or
  /// rotated 90° to read top-down, in the second row for odd bars when
  /// the labels are staggered.
  Rect _labelRect(_MeterLayout l, int i, Size size) {
    final tp = l.labelPainters[i];
    final x = l.startX + i * (l.barW + _kBarGap);
    final secondRow = l.staggered && i.isOdd;
    if (l.rotateLabels) {
      // After the +90° rotation the text's advance runs down the screen
      // and its height extends left of the rotation point, so the glyph
      // column is tp.height wide and centred on the bar.
      return Rect.fromLTWH(
        x + (l.barW - tp.height) / 2,
        l.endY + 3 + (secondRow ? l.rotatedRow1Y : 0),
        tp.height,
        tp.width,
      );
    }
    // Centered on the bar, but kept inside the meter: a staggered label
    // can be twice the pitch wide, so the last bar's label can run past
    // the right edge. A shift eats into the 1 px that meterLabelLayout
    // left beside the same-row neighbour; at 9.1.6 in the Renderer view
    // no label is shifted.
    final maxX = math.max(0.0, size.width - tp.width);
    final lx = (x + (l.barW - tp.width) / 2).clamp(0.0, maxX);
    return Rect.fromLTWH(
      lx,
      l.endY + 3 + (secondRow ? l.labelLineH : 0),
      tp.width,
      tp.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final l = _layout(size);
    if (l == null) return;
    final n = levels.length;
    final barW = l.barW;
    final startX = l.startX;
    final totalBarsW = l.totalBarsW;
    final startY = l.startY;
    final endY = l.endY;
    final barAreaH = l.barAreaH;

    final paint = _paint
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0;

    // No background: see the class doc.

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

      // Clip indicator: a red rectangle at the top of the bar
      if (isClipped) {
        paint.color = T.meterRed;
        canvas.drawRect(Rect.fromLTWH(x, startY - 1, barW, 3), paint);
      }

      // Channel label ([_labelRect]).
      if (l.drawLabels) {
        final tp = _labelPainter(i);
        final rect = _labelRect(l, i, size);
        if (l.rotateLabels) {
          // Read top-down: rotated +90° about the rect's top-right, the
          // text runs down the screen with its height to the left.
          canvas.save();
          canvas.translate(rect.right, rect.top);
          canvas.rotate(math.pi / 2);
          tp.paint(canvas, Offset.zero);
          canvas.restore();
        } else {
          tp.paint(canvas, rect.topLeft);
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
      !listEquals(old.labelColors, labelColors) ||
      old.showLabels != showLabels ||
      old.fontMode != fontMode ||
      old.themeMode != themeMode;
}

/// What [MultichannelMeterPainter.paint] lays out for one size: the bars,
/// and the labels' painters and placement ([meterLabelLayout]).
final class _MeterLayout {
  const _MeterLayout({
    required this.barW,
    required this.startX,
    required this.totalBarsW,
    required this.startY,
    required this.endY,
    required this.barAreaH,
    required this.labelPainters,
    required this.labelLineH,
    required this.drawLabels,
    required this.rotateLabels,
    required this.staggered,
    required this.rotatedRow1Y,
  });

  final double barW;
  final double startX;
  final double totalBarsW;
  final double startY;
  final double endY;
  final double barAreaH;
  final List<TextPainter> labelPainters;
  final double labelLineH;
  final bool drawLabels;
  final bool rotateLabels;
  final bool staggered;
  final double rotatedRow1Y;
}
