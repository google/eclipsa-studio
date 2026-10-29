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

/// Widgets, styles and the trace chart shared by the two Loudness Report
/// dialogs: [LoudnessReportDialog] for a Creator session and
/// [QcLoudnessReportDialog] for a loaded IAMF file (ES-520). Both grids
/// print the same value columns and both charts plot the same series,
/// so the pieces live here once.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/text_width.dart';
import '../widgets/app_button.dart';
import '../widgets/status_tag.dart';
import 'loudness_measure_runner.dart' show LoudnessMeasureState;

/// Trace series selectable in the chart.
enum ReportChartSeries {
  shortTerm('Short-term', 'LUFS'),
  momentary('Momentary', 'LUFS'),
  psr('PSR', 'dB');

  const ReportChartSeries(this.label, this.unit);
  final String label;
  final String unit;
}

/// Grid header cell style. Shared with the column-width measurement so
/// the rendered text and the measured width cannot drift.
TextStyle reportHeaderStyle() => TextStyle(
  fontSize: T.fontCaption,
  color: T.textMuted,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.5,
);

/// Grid value cell style; [color] is applied at the render site.
TextStyle reportValueStyle({Color? color}) => TextStyle(
  fontFamily: T.monoFamily,
  fontSize: T.fontBody,
  color: color ?? T.textValue,
);

/// Shared by the MAX GR / LIMITED header and value cells so the
/// explanation is discoverable before any row engages.
const kReportGrTooltip =
    'Limiter gain reduction at the points where the exported audio '
    'exceeds −1 dBFS. Report values are measured after the −1 dBFS '
    'limiter; the exported file is not limited.';

/// Trace colour of the row at [index] in a report's result list.
Color reportRowColor(int index) {
  final palette = [
    T.purpleLight,
    T.objCyan,
    T.objGreen,
    T.objAmber,
    T.pink,
    T.meterRed,
    T.textSecondary,
  ];
  return palette[index % palette.length];
}

/// Selection-dot column: a 12 px circle, no text, so it does not scale
/// with the font mode.
const kReportCheckColumn = 30.0;

/// Padding of the grid's header and of each row, the same in both so
/// the columns line up. The right inset keeps the badge inside a
/// selected row's fill, as the dot column does at the left (ES-1028).
const kReportRowPadding = EdgeInsets.fromLTRB(0, 4, T.gapSm, 4);

/// Space above each row, so two selected rows draw as two fills rather
/// than meeting edge to edge (ES-1028).
const kReportRowGap = 2.0;

/// The header's "measured at" time, HH:MM.
String formatReportTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

/// A grid row: [kReportRowGap] above it, then [child] in a
/// [kReportRowPadding] box with rounded corners, filled with
/// `bgSelected` when [selected]. [onTap] toggles the row's selection;
/// a null [onTap] makes the row inert.
class ReportRowShell extends StatelessWidget {
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  const ReportRowShell({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: kReportRowGap),
      child: InkWell(
        borderRadius: BorderRadius.circular(T.radiusSm),
        onTap: onTap,
        child: Container(
          padding: kReportRowPadding,
          decoration: BoxDecoration(
            color: selected ? T.bgSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(T.radiusSm),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A row's 12 px selection dot, which the caller centres in its check
/// column: filled and rimmed in the row's trace [color] when [selected],
/// otherwise an empty circle with a `borderStrong` rim, or a
/// `borderLight` rim when the row is not [selectable].
class ReportSelectDot extends StatelessWidget {
  final bool selected;
  final Color color;
  final bool selectable;
  const ReportSelectDot({
    super.key,
    required this.selected,
    required this.color,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? color : Colors.transparent,
        border: Border.all(
          color: selected
              ? color
              : selectable
              ? T.borderStrong
              : T.borderLight,
        ),
      ),
    );
  }
}

class ReportBanner extends StatelessWidget {
  final String text;
  final Color color;
  const ReportBanner({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: T.fontBody, color: T.textPrimary),
      ),
    );
  }
}

class LayoutTagBadge extends StatelessWidget {
  final bool tagged;

  /// Tooltips for the two states; the creator report's wording by
  /// default.
  final String taggedTooltip;
  final String untaggedTooltip;

  const LayoutTagBadge({
    super.key,
    required this.tagged,
    this.taggedTooltip =
        'This layout is tagged in the mix presentation. Its measured '
        'integrated loudness, digital peak and true peak are written into '
        'the IAMF file on export.',
    this.untaggedTooltip =
        'Monitoring layout only: measured for reference, not part of this '
        'mix presentation, and never written to the IAMF file.',
  });

  /// Rendered width of the wider label at the current font mode, plus
  /// the [StatusTag]'s padding and rim.
  static double width(BuildContext context) =>
      widestTextWidth(context, const ['IAMF', 'MON'], StatusTag.textStyle()) +
      2 * StatusTag.hPad +
      2 * StatusTag.rimWidth;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tagged ? taggedTooltip : untaggedTooltip,
      child: StatusTag(
        tagged ? 'IAMF' : 'MON',
        color: tagged ? T.purpleLight : T.objAmber,
        outlined: true,
      ),
    );
  }
}

/// The running pass: a label, a progress bar and Cancel.
class MeasureProgressView extends StatelessWidget {
  final LoudnessMeasureState measure;
  final VoidCallback onCancel;
  const MeasureProgressView({
    super.key,
    required this.measure,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final label = 'Measuring layouts (${measure.done}/${measure.total})…';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: T.fontBodyL, color: T.textSecondary),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: measure.total > 0 ? measure.done / measure.total : null,
                backgroundColor: T.bgControls,
                valueColor: AlwaysStoppedAnimation<Color>(T.purple),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: AppButton(
                label: measure.cancelRequested ? 'Cancelling…' : 'Cancel',
                size: AppButtonSize.compact,
                onPressed: measure.cancelRequested ? null : onCancel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Chart painter ─────────────────────────────────────────────────────

class ReportChartTrace {
  final String label;
  final Color color;
  final Float32List values;
  final double offsetSeconds;
  const ReportChartTrace({
    required this.label,
    required this.color,
    required this.values,
    required this.offsetSeconds,
  });
}

class TraceChartPainter extends CustomPainter {
  final List<ReportChartTrace> traces;

  /// Limiter gain-reduction traces for the GR lane, parallel to
  /// [traces] (same rows, same colors). Non-empty whenever rows are
  /// selected, so the lane is always on and the layout stays stable.
  final List<ReportChartTrace> grTraces;
  final int stepMs;
  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  const TraceChartPainter({
    required this.traces,
    required this.grTraces,
    required this.stepMs,
    required this.fontMode,
    required this.themeMode,
  });

  static const _padLeft = 44.0;
  static const _padBottom = 20.0;
  static const _padTop = 8.0;
  static const _padRight = 8.0;
  static const _grLaneHeight = 28.0;
  // Chart-to-lane gap: the pairing gap token, deliberately.
  static const _grLaneGap = T.gapPair;

  @override
  void paint(Canvas canvas, Size size) {
    final hasGrLane = grTraces.isNotEmpty;
    final plotTop = hasGrLane ? _padTop + _grLaneHeight + _grLaneGap : _padTop;
    final plot = Rect.fromLTRB(
      _padLeft,
      plotTop,
      size.width - _padRight,
      size.height - _padBottom,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = T.bgBase,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    // Value + time ranges across the visible traces.
    var minV = double.infinity, maxV = double.negativeInfinity;
    var maxT = 0.0;
    for (final t in traces) {
      for (final v in t.values) {
        // Silence floor — off the chart. The finite check is defense in
        // depth: a single NaN would poison math.min/max and blank the
        // whole chart (the engine already clamps non-finite entries).
        if (!v.isFinite || v <= -120) continue;
        minV = math.min(minV, v);
        maxV = math.max(maxV, v);
      }
      maxT = math.max(
        maxT,
        t.offsetSeconds + (t.values.length - 1) * stepMs / 1000.0,
      );
    }
    // The GR series has no warmup window, so it is the longest series —
    // fold its extent in so the shared time axis covers it.
    for (final t in grTraces) {
      maxT = math.max(
        maxT,
        t.offsetSeconds + (t.values.length - 1) * stepMs / 1000.0,
      );
    }
    if (!minV.isFinite || maxT <= 0) {
      _drawEmpty(canvas, plot);
      return;
    }
    minV = (minV - 3).floorToDouble();
    maxV = (maxV + 3).ceilToDouble();
    if (maxV - minV < 6) maxV = minV + 6;

    double x(double seconds) => plot.left + seconds / maxT * plot.width;
    double y(double v) => plot.top + (maxV - v) / (maxV - minV) * plot.height;

    // Horizontal grid + dB labels at a step that yields ~4-6 lines.
    final gridPaint = Paint()
      ..color = T.borderLight
      ..strokeWidth = 1;
    final vStep = _niceStep((maxV - minV) / 5);
    for (var v = (minV / vStep).ceil() * vStep; v <= maxV; v += vStep) {
      canvas.drawLine(
        Offset(plot.left, y(v)),
        Offset(plot.right, y(v)),
        gridPaint,
      );
      _label(
        canvas,
        v.toStringAsFixed(0),
        Offset(plot.left - 6, y(v)),
        alignRight: true,
      );
    }

    // Time ticks: adaptive short labels (same convention as the
    // timeline ruler — not formatDuration, deliberately).
    final tStep = _niceTimeStep(maxT / 6);
    for (var t = tStep; t <= maxT; t += tStep) {
      canvas.drawLine(
        Offset(x(t), plot.bottom),
        Offset(x(t), plot.bottom + 4),
        gridPaint,
      );
      _label(
        canvas,
        _fmtSeconds(t),
        Offset(x(t), plot.bottom + 6),
        centerX: true,
        top: true,
      );
    }

    // Traces.
    for (final t in traces) {
      final paint = Paint()
        ..color = t.color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var started = false;
      for (var i = 0; i < t.values.length; i++) {
        final v = t.values[i];
        if (!v.isFinite || v <= -120) {
          started = false;
          continue;
        }
        final px = x(t.offsetSeconds + i * stepMs / 1000.0);
        final py = y(v.clamp(minV, maxV).toDouble());
        if (!started) {
          path.moveTo(px, py);
          started = true;
        } else {
          path.lineTo(px, py);
        }
      }
      canvas.drawPath(path, paint);
    }

    if (hasGrLane) _drawGrLane(canvas, plot, x);

    // Legend: top-left inside the plot.
    var ly = plot.top + 4;
    for (final t in traces) {
      canvas.drawLine(
        Offset(plot.left + 8, ly + 5),
        Offset(plot.left + 24, ly + 5),
        Paint()
          ..color = t.color
          ..strokeWidth = 2,
      );
      _label(canvas, t.label, Offset(plot.left + 30, ly + 5));
      ly += 14;
    }

    // Frame.
    canvas.drawRect(
      plot,
      Paint()
        ..color = T.border
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawEmpty(Canvas canvas, Rect plot) {
    _label(canvas, 'No trace selected', plot.center, centerX: true);
  }

  /// Limiter gain-reduction lane above the main plot, mastering
  /// convention: 0 dB at the lane top, reduction growing downward.
  /// Shares the main plot's time axis via [x].
  void _drawGrLane(Canvas canvas, Rect plot, double Function(double) x) {
    final lane = Rect.fromLTRB(
      plot.left,
      _padTop,
      plot.right,
      _padTop + _grLaneHeight,
    );
    canvas.drawRect(lane, Paint()..color = T.bgControls.withValues(alpha: 0.5));

    // Lane scale: at least 3 dB so light limiting doesn't look
    // dramatic, otherwise the observed max rounded up to a whole dB.
    var observedMax = 0.0;
    for (final t in grTraces) {
      for (final v in t.values) {
        if (v.isFinite && v > observedMax) observedMax = v;
      }
    }
    final grMax = math.max(3.0, observedMax.ceilToDouble());
    double y(double gr) =>
        lane.top + gr.clamp(0.0, grMax) / grMax * lane.height;

    for (final t in grTraces) {
      if (t.values.isEmpty) continue;
      final line = Path();
      final fill = Path()..moveTo(x(t.offsetSeconds), lane.top);
      var px = 0.0;
      for (var i = 0; i < t.values.length; i++) {
        px = x(t.offsetSeconds + i * stepMs / 1000.0);
        final v = t.values[i];
        final py = y(v.isFinite ? v : 0.0);
        if (i == 0) {
          line.moveTo(px, py);
        } else {
          line.lineTo(px, py);
        }
        fill.lineTo(px, py);
      }
      fill
        ..lineTo(px, lane.top)
        ..close();
      canvas.drawPath(fill, Paint()..color = t.color.withValues(alpha: 0.35));
      canvas.drawPath(
        line,
        Paint()
          ..color = t.color
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    // 0 dB reference along the lane top, frame, and gutter labels.
    canvas.drawLine(
      lane.topLeft,
      lane.topRight,
      Paint()
        ..color = T.borderLight
        ..strokeWidth = 1,
    );
    canvas.drawRect(
      lane,
      Paint()
        ..color = T.border
        ..style = PaintingStyle.stroke,
    );
    _label(canvas, 'GR', Offset(lane.left - 6, lane.top + 5), alignRight: true);
    _label(
      canvas,
      grMax.toStringAsFixed(0),
      Offset(lane.left - 6, lane.bottom - 4),
      alignRight: true,
    );
  }

  void _label(
    Canvas canvas,
    String text,
    Offset at, {
    bool alignRight = false,
    bool centerX = false,
    bool top = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: T.fontMeter,
          color: T.textTertiary,
          fontFamily: T.monoFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (centerX) dx -= tp.width / 2;
    final dy = top ? at.dy : at.dy - tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  static double _niceStep(double raw) {
    for (final s in [1.0, 2.0, 3.0, 6.0, 10.0, 20.0, 30.0]) {
      if (raw <= s) return s;
    }
    return 60.0;
  }

  static double _niceTimeStep(double raw) {
    for (final s in [1.0, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0]) {
      if (raw <= s) return s;
    }
    return 1800.0;
  }

  static String _fmtSeconds(double t) {
    final s = t.round();
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(TraceChartPainter old) =>
      old.traces != traces ||
      old.grTraces != grTraces ||
      old.stepMs != stepMs ||
      old.fontMode != fontMode ||
      old.themeMode != themeMode;
}
