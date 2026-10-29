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

/// Loudness Report window for a loaded IAMF file (ES-520): decodes the
/// file, renders each mix presentation's sub-mix at its declared
/// loudness layouts and at the monitoring layout, and shows the
/// measured values beside the loudness_info the file stores, with the
/// difference in integrated loudness.
///
/// Opens from the same entry points as [LoudnessReportDialog] when the
/// workspace is in Playback. Measurement starts on open when there is no
/// report for the open file; a completed report is kept in
/// [qcLoudnessReportProvider] until the workspace leaves Playback or
/// another file opens. Nothing is written back: the file is read-only.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../export/iamf_measure_isolate.dart';
import '../logging/log.dart';
import '../playback/playback_session.dart';
import '../state.dart';
import '../theme.dart';
import '../util/text_width.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/console_widgets.dart' show ConsoleSegment;
import '../widgets/dialog_shell.dart';
import 'loudness_report_widgets.dart';
import 'programme_loudness.dart' show formatProgrammeScalar;
import 'qc_loudness_measurement.dart';
import 'qc_loudness_report_provider.dart';

/// Measured widths of the grid's numeric and badge columns.
typedef _GridColumns = ({double value, double delta, double badge});

class QcLoudnessReportDialog extends ConsumerStatefulWidget {
  const QcLoudnessReportDialog({super.key});

  static void show(BuildContext context) {
    showAppDialog(
      context: context,
      id: QcLoudnessReportDialog,
      builder: (_) => const QcLoudnessReportDialog(),
    );
  }

  @override
  ConsumerState<QcLoudnessReportDialog> createState() =>
      _QcLoudnessReportDialogState();
}

class _QcLoudnessReportDialogState
    extends ConsumerState<QcLoudnessReportDialog> {
  /// Row keys ([QcLoudnessRow.key]) whose traces are overlaid in the
  /// chart.
  final Set<String> _selectedRows = {};
  ReportChartSeries _series = ReportChartSeries.shortTerm;

  /// Set when the dialog opened without a report while a pass was
  /// already running, so the measure on open did not start. When that
  /// pass stops without a report or an error (a pass discarded when
  /// another file opened, still cancelling), the dialog starts its own.
  /// Cleared by the Cancel button: a pass the user cancels stays
  /// cancelled.
  bool _measureWhenIdle = false;

  @override
  void initState() {
    super.initState();
    Log.i(LogCat.export, 'QC Loudness Report opened');
    // Measure on open unless a report for this file already exists.
    // Post-frame: Riverpod forbids provider mutation during initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final report = ref.read(currentQcLoudnessReportProvider);
      if (report == null) {
        _measureWhenIdle = ref.read(qcLoudnessMeasureProvider).running;
        ref.read(qcLoudnessMeasureProvider.notifier).run();
      } else {
        _selectDefaultRows(report);
      }
    });
  }

  void _selectDefaultRows(QcLoudnessReportData report) {
    if (_selectedRows.isNotEmpty || report.results.isEmpty) return;
    // Default overlay: the first mix presentation's tagged rows.
    final firstMix = report.results.first.row.mixId;
    setState(() {
      _selectedRows.addAll(
        report.results
            .where((r) => r.row.mixId == firstMix && r.row.taggedInFile)
            .map((r) => r.row.key),
      );
    });
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final report = ref.watch(currentQcLoudnessReportProvider);
    final session = ref.watch(playbackSessionProvider);
    final measure = ref.watch(qcLoudnessMeasureProvider);
    final running = measure.running;
    ref.listen(currentQcLoudnessReportProvider, (_, next) {
      if (next != null) _selectDefaultRows(next);
    });
    ref.listen(qcLoudnessMeasureProvider, (prev, next) {
      if (!_measureWhenIdle || prev == null) return;
      if (!prev.running || next.running) return;
      _measureWhenIdle = false;
      if (next.error == null &&
          ref.read(currentQcLoudnessReportProvider) == null) {
        ref.read(qcLoudnessMeasureProvider.notifier).run();
      }
    });

    // Track the window so the report keeps using available space. Wider
    // than the creator report: the grid has the Δ column as well.
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(1260.0, screen.width - 80);
    final height = math.min(760.0, screen.height - 80);

    return DialogShell(
      width: width,
      height: height,
      bodyFit: DialogBodyFit.expand,
      footerDivider: true,
      insetPadding: const EdgeInsets.all(40),
      actions: [DialogShell.done(context)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(report, session?.path, running),
          const SizedBox(height: 12),
          Container(height: 1, color: T.border),
          const SizedBox(height: 12),
          if (measure.error case final error?) ...[
            ReportBanner(text: error, color: T.errorRed),
            const SizedBox(height: 12),
          ],
          if (running)
            Expanded(
              child: MeasureProgressView(
                measure: measure,
                onCancel: () {
                  _measureWhenIdle = false;
                  ref.read(qcLoudnessMeasureProvider.notifier).cancel();
                },
              ),
            )
          else if (report == null)
            Expanded(
              child: Center(
                child: Text(
                  'No measurements yet.',
                  style: TextStyle(fontSize: T.fontHeading, color: T.textGhost),
                ),
              ),
            )
          else ...[
            Expanded(flex: 5, child: _buildGrid(report)),
            const SizedBox(height: 8),
            Text(
              'Measured values are taken from the decoded audio after '
              'this application\'s −1 dBFS limiter; stored values are '
              'the loudness values written in the file. A stored peak above '
              '−1 dBFS reads higher than the measured one.'
              '${_anyGainsMayVary(report) ? ' $_gainsMayVaryNote' : ''}',
              style: TextStyle(fontSize: T.fontCaption, color: T.textTertiary),
            ),
            const SizedBox(height: 12),
            Container(height: 1, color: T.border),
            const SizedBox(height: 12),
            Expanded(flex: 4, child: _buildChart(report)),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(
    QcLoudnessReportData? report,
    String? path,
    bool running,
  ) {
    return Row(
      children: [
        Text('Loudness Report', style: T.styleDialogTitle),
        const SizedBox(width: 12),
        if (path != null)
          Flexible(
            child: Text(
              p.basename(path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
            ),
          ),
        if (report != null && !running) ...[
          const SizedBox(width: 12),
          Text(
            'measured at ${formatReportTime(report.measuredAt)}',
            style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
          ),
        ],
        const Spacer(),
        if (!running)
          AppButton(
            label: 'Measure Again',
            role: report == null
                ? AppButtonRole.affirmative
                : AppButtonRole.standard,
            size: AppButtonSize.compact,
            onPressed: ref.read(qcLoudnessMeasureProvider.notifier).run,
          ),
      ],
    );
  }

  // ── Grid ────────────────────────────────────────────────────────────

  /// Headers of the numeric columns, in grid order. Also the input to
  /// the column-width measurement.
  static const _valueHeaders = [
    'INTEGRATED',
    'TRUE PEAK',
    'PEAK',
    'LRA',
    'MAX GR',
    'LIMITED',
  ];

  /// The widest string each numeric cell prints (see the creator
  /// report's list; the stored line prints the same units).
  static const _widestValues = [
    '-119.9 LUFS',
    '-119.9 dBTP',
    '-119.9 dBFS',
    '-119.9 LU',
    '119.9 dB',
    '100%',
  ];

  static const _deltaHeader = 'Δ LU';

  /// The widest delta the cell prints, with its sign.
  static const _widestDelta = '+119.9';

  static _GridColumns _measureColumns(BuildContext context) {
    final value = math.max(
      widestTextWidth(context, _valueHeaders, reportHeaderStyle()),
      widestTextWidth(context, _widestValues, reportValueStyle()),
    );
    final delta = math.max(
      widestTextWidth(context, const [_deltaHeader], reportHeaderStyle()),
      widestTextWidth(context, const [_widestDelta], reportValueStyle()),
    );
    return (
      value: value + T.gapSm,
      delta: delta + T.gapSm,
      badge: LayoutTagBadge.width(context) + T.gapSm,
    );
  }

  /// Δ above this magnitude is highlighted, as in the export dialog's
  /// read-back panel.
  static const _deltaHighlightLu = 0.5;

  /// The GR cells' tooltip; the shared one speaks of an export.
  static const _grTooltip =
      'Limiter gain reduction: where the decoded audio exceeds −1 dBFS. '
      'Measured values are taken after the limiter; the file is not '
      'changed.';

  static const _deltaTooltip =
      'Stored integrated loudness minus the measured value, in LU.';

  static bool _anyGainsMayVary(QcLoudnessReportData report) =>
      report.results.any((m) => m.row.gainsMayVary);

  static const _gainsMayVaryNote =
      'Rows marked * belong to a sub-mix whose mix gains can change over '
      'time in the file; they are measured with the default gains.';

  static const _taggedTooltip =
      'The file declares loudness for this layout. The stored line shows '
      'the values the encoder wrote into the file.';

  static const _untaggedTooltip =
      'Monitoring layout only: measured for reference. The file declares '
      'no loudness for it.';

  Widget _buildGrid(QcLoudnessReportData report) {
    final cols = _measureColumns(context);
    final resultsByKey = {for (final r in report.results) r.row.key: r};
    final subMixCounts = <int, int>{};
    for (final row in report.rows) {
      subMixCounts[row.mixId] = math.max(
        subMixCounts[row.mixId] ?? 0,
        row.subMixIndex + 1,
      );
    }
    final rows = <Widget>[];
    int? lastMixId;
    int? lastSubIdx;
    for (final row in report.rows) {
      if (row.mixId != lastMixId) {
        lastMixId = row.mixId;
        lastSubIdx = null;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              row.mixLabel,
              style: TextStyle(
                fontSize: T.fontBodyL,
                fontWeight: FontWeight.w600,
                color: T.textPrimary,
              ),
            ),
          ),
        );
      }
      if (subMixCounts[row.mixId]! > 1 && row.subMixIndex != lastSubIdx) {
        lastSubIdx = row.subMixIndex;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
            child: Text(
              'Sub-mix ${row.subMixIndex + 1}',
              style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
            ),
          ),
        );
      }
      rows.add(_buildRow(report, row, resultsByKey[row.key], cols));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _gridHeader(cols),
        const SizedBox(height: 2),
        Container(height: 1, color: T.borderLight),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ],
    );
  }

  Widget _gridHeader(_GridColumns cols) {
    Widget h(String s, {double? width, TextAlign align = TextAlign.right}) {
      // maxLines 1 + softWrap false: a header wider than its measured
      // column clips instead of wrapping, so an over-tight column fails
      // visibly in review and in the width test.
      final t = Text(
        s,
        textAlign: align,
        maxLines: 1,
        softWrap: false,
        style: reportHeaderStyle(),
      );
      return width == null
          ? Expanded(child: t)
          : SizedBox(width: width, child: t);
    }

    return Padding(
      padding: kReportRowPadding,
      child: Row(
        children: [
          const SizedBox(width: kReportCheckColumn),
          h('MIX / LAYOUT', align: TextAlign.left),
          h(_valueHeaders[0], width: cols.value),
          Tooltip(
            message: _deltaTooltip,
            child: h(_deltaHeader, width: cols.delta),
          ),
          for (final label in _valueHeaders.skip(1).take(3))
            h(label, width: cols.value),
          Tooltip(
            message: _grTooltip,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final label in _valueHeaders.skip(4))
                  h(label, width: cols.value),
              ],
            ),
          ),
          h('', width: cols.badge),
        ],
      ),
    );
  }

  /// One row: the measured line, and under it the stored line for a
  /// tagged row. A row that could not be measured prints its reason on
  /// the measured line.
  Widget _buildRow(
    QcLoudnessReportData report,
    QcLoudnessRow row,
    QcMeasuredRow? measured,
    _GridColumns cols,
  ) {
    final key = row.key;
    final selected = _selectedRows.contains(key);
    final color = reportRowColor(
      measured == null ? 0 : report.results.indexOf(measured),
    );
    final selectable = measured?.traces != null;
    final shipped = row.shipped;

    Widget cell(
      String text, {
      required double width,
      Color? color,
      String? tooltip,
    }) {
      final t = Text(
        text,
        textAlign: TextAlign.right,
        maxLines: 1,
        softWrap: false,
        style: reportValueStyle(color: color),
      );
      return SizedBox(
        width: width,
        child: tooltip == null ? t : Tooltip(message: tooltip, child: t),
      );
    }

    Widget value(double? v, String unit, {Color? color}) => cell(
      v == null ? '—' : formatProgrammeScalar(v, unit: unit),
      width: cols.value,
      color: color,
    );

    // ── Measured line ─────────────────────────────────────────────────
    final List<Widget> measuredCells;
    if (measured == null) {
      measuredCells = [
        Expanded(
          child: Tooltip(
            message: row.notMeasurableReason ?? 'Not measured.',
            child: Text(
              row.notMeasurableReason ?? 'Not measured.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: T.fontBody, color: T.textTertiary),
            ),
          ),
        ),
      ];
    } else {
      final scalars = measured.scalars;
      final lra = measured.traces?.loudnessRangeLu;
      final maxGr = measured.traces?.maxLimiterGrDb ?? 0.0;
      final grEngaged = maxGr > MixMeasureTraces.engagedThresholdDb;
      final limitedFraction = grEngaged
          ? (measured.traces?.limiterEngagedFraction ?? 0.0)
          : 0.0;
      final delta = measured.deltaIntegratedLu;
      measuredCells = [
        value(scalars.integratedLufs, 'LUFS'),
        cell(
          delta == null ? '—' : formatQcDeltaLu(delta),
          width: cols.delta,
          color: delta == null
              ? T.textValueDim
              : delta.abs() > _deltaHighlightLu
              ? T.meterYellow
              : T.textValueDim,
          tooltip: _deltaTooltip,
        ),
        value(scalars.truePeakDbtp, 'dBTP'),
        value(scalars.digitalPeakDbfs, 'dBFS'),
        cell(
          lra == null ? '—' : '${lra.toStringAsFixed(1)} LU',
          width: cols.value,
          color: T.textValueDim,
        ),
        Tooltip(
          message: _grTooltip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(
                grEngaged ? '${maxGr.toStringAsFixed(1)} dB' : '—',
                width: cols.value,
                color: grEngaged ? T.meterYellow : T.textValueDim,
              ),
              cell(
                grEngaged
                    ? '${(limitedFraction * 100).toStringAsFixed(0)}%'
                    : '—',
                width: cols.value,
                color: grEngaged ? T.meterYellow : T.textValueDim,
              ),
            ],
          ),
        ),
      ];
    }

    Widget line(Widget label, List<Widget> cells, {Widget? trailing}) => Row(
      children: [
        const SizedBox(width: kReportCheckColumn),
        Expanded(
          child: Padding(padding: const EdgeInsets.only(left: 8), child: label),
        ),
        ...cells,
        SizedBox(
          width: cols.badge,
          child: Align(
            alignment: Alignment.centerRight,
            child: trailing ?? const SizedBox.shrink(),
          ),
        ),
      ],
    );

    return ReportRowShell(
      selected: selected,
      onTap: selectable
          ? () {
              setState(() {
                if (!_selectedRows.remove(key)) _selectedRows.add(key);
              });
            }
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              line(
                measured != null && row.gainsMayVary
                    ? Tooltip(
                        message: _gainsMayVaryNote,
                        child: Text(
                          '${row.layoutLabel} *',
                          style: TextStyle(
                            fontSize: T.fontBody,
                            color: T.textValue,
                          ),
                        ),
                      )
                    : Text(
                        row.layoutLabel,
                        style: TextStyle(
                          fontSize: T.fontBody,
                          color: T.textValue,
                        ),
                      ),
                measuredCells,
                trailing: LayoutTagBadge(
                  tagged: row.taggedInFile,
                  taggedTooltip: _taggedTooltip,
                  untaggedTooltip: _untaggedTooltip,
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: kReportCheckColumn,
                child: Center(
                  child: ReportSelectDot(
                    selected: selected,
                    color: color,
                    selectable: selectable,
                  ),
                ),
              ),
            ],
          ),
          if (shipped != null) ...[
            const SizedBox(height: 2),
            line(
              Text(
                'stored in file',
                style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
              ),
              [
                value(shipped.integratedLufs, 'LUFS', color: T.textValueDim),
                cell('', width: cols.delta),
                value(shipped.truePeakDbtp, 'dBTP', color: T.textValueDim),
                value(shipped.digitalPeakDbfs, 'dBFS', color: T.textValueDim),
                cell('', width: cols.value),
                cell('', width: cols.value),
                cell('', width: cols.value),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Chart ───────────────────────────────────────────────────────────

  Widget _buildChart(QcLoudnessReportData report) {
    final selected = [
      for (final m in report.results)
        if (_selectedRows.contains(m.row.key) && m.traces != null) m,
    ];
    ReportChartTrace trace(QcMeasuredRow m, {required bool gr}) =>
        ReportChartTrace(
          label: '${m.row.mixLabel} · ${m.row.layoutLabel}',
          color: reportRowColor(report.results.indexOf(m)),
          values: gr
              ? m.traces!.limiterGrDb
              : switch (_series) {
                  ReportChartSeries.shortTerm => m.traces!.shortTermLufs,
                  ReportChartSeries.momentary => m.traces!.momentaryLufs,
                  ReportChartSeries.psr => m.traces!.shortTermPsrDb,
                },
          // A window's first entry lands when the window fills; the GR
          // series has no window and entry k covers bucket k.
          offsetSeconds: gr
              ? 0.1
              : _series == ReportChartSeries.momentary
              ? 0.4
              : 3.0,
        );
    final traces = [for (final m in selected) trace(m, gr: false)];
    final grTraces = [for (final m in selected) trace(m, gr: true)];
    final anyEngaged = selected.any(
      (m) => m.traces!.limiterEngagedFraction > 0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ConsoleSegment<ReportChartSeries>(
              value: _series,
              options: [for (final s in ReportChartSeries.values) (s, s.label)],
              onChanged: (s) => setState(() => _series = s),
            ),
            const Spacer(),
            Text(
              traces.isEmpty
                  ? 'Select rows above to plot their trace'
                  : '${_series.label} (${_series.unit}) over time',
              style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
            ),
          ],
        ),
        if (anyEngaged) ...[
          const SizedBox(height: 4),
          Text(
            'GR lane: limiter gain reduction, where the decoded audio '
            'exceeds −1 dBFS',
            style: TextStyle(fontSize: T.fontCaption, color: T.textTertiary),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(T.radiusSm),
            child: CustomPaint(
              painter: TraceChartPainter(
                traces: traces,
                grTraces: grTraces,
                stepMs: MixMeasureTraces.stepMs,
                fontMode: T.fontMode,
                themeMode: T.mode,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }
}

/// [deltaLu] to one decimal with an explicit sign. The sign follows the
/// rounded value, so -0.04 prints "+0.0" and not "-0.0".
@visibleForTesting
String formatQcDeltaLu(double deltaLu) {
  final rounded = (deltaLu * 10).round() / 10;
  return '${rounded >= 0 ? '+' : ''}${rounded.toStringAsFixed(1)}';
}
