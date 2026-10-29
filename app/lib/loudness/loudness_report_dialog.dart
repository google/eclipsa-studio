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

/// Loudness Report window (ES-195): measures every mix presentation ×
/// layout offline and shows the results as a grid plus loudness-over-
/// time traces.
///
/// Opens from View → Loudness Report… in Creator; in Playback the same
/// entry points open [QcLoudnessReportDialog], which measures the loaded
/// file (ES-520). Measurement starts on open when
/// there is no current (fingerprint-matching) report; a completed
/// report is kept in [loudnessReportProvider] for the app run and
/// seeds the IAMF export's measure phase. The grid covers each
/// sub-mix's tagged layouts plus the current monitoring layout —
/// monitoring-only rows are badged and never written to the session or
/// the IAMF bitstream.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../export/element_overload_rows.dart';
import '../export/iamf_measure_isolate.dart';
import '../logging/log.dart';
import '../state.dart';
import '../theme.dart';
import '../util/text_width.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/console_widgets.dart' show ConsoleSegment;
import '../widgets/dialog_shell.dart';
import '../workspace/workspace_mode.dart';
import 'loudness_measure_runner.dart';
import 'loudness_measurement.dart';
import 'loudness_report_provider.dart';
import 'loudness_report_widgets.dart';
import 'programme_loudness.dart' show formatProgrammeScalar;
import 'qc_loudness_report_dialog.dart';

/// Measured widths of the grid's numeric and badge columns.
typedef _GridColumns = ({double value, double badge});

class LoudnessReportDialog extends ConsumerStatefulWidget {
  const LoudnessReportDialog({super.key});

  /// Opens the report for the current workspace: this dialog in Creator,
  /// [QcLoudnessReportDialog] for the file open in Playback.
  static void show(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(workspaceModeProvider) == WorkspaceMode.playback) {
      QcLoudnessReportDialog.show(context);
      return;
    }
    showAppDialog(
      context: context,
      id: LoudnessReportDialog,
      builder: (_) => const LoudnessReportDialog(),
    );
  }

  @override
  ConsumerState<LoudnessReportDialog> createState() =>
      _LoudnessReportDialogState();
}

class _LoudnessReportDialogState extends ConsumerState<LoudnessReportDialog> {
  /// Row keys (see [_rowKey]) whose traces are overlaid in the chart.
  final Set<String> _selectedRows = {};
  ReportChartSeries _series = ReportChartSeries.shortTerm;

  @override
  void initState() {
    super.initState();
    Log.i(LogCat.export, 'Loudness Report opened');
    // Measure on open unless a fingerprint-matching report already
    // exists (re-opening an unchanged session shows instantly).
    // Post-frame: Riverpod forbids provider mutation during initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final report = ref.read(loudnessReportProvider);
      if (report == null || report.fingerprint != _currentFingerprint()) {
        ref.read(loudnessMeasureProvider.notifier).run();
      } else {
        _selectDefaultRows(report);
      }
    });
  }

  String _currentFingerprint() => ref.read(currentLoudnessFingerprintProvider);

  static String _rowKey(MeasuredLayoutLoudness m) =>
      '${m.mixId}/${m.subMixIndex}/${m.soundSystem.name}';

  void _selectDefaultRows(LoudnessReportData report) {
    if (_selectedRows.isNotEmpty || report.results.isEmpty) return;
    // Default overlay: the first mix's tagged layouts.
    final firstMix = report.results.first.mixId;
    setState(() {
      _selectedRows.addAll(
        report.results
            .where((r) => r.mixId == firstMix && r.taggedInMix)
            .map(_rowKey),
      );
    });
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final report = ref.watch(loudnessReportProvider);
    final mixes = ref.watch(mixesNotifierProvider);
    // Fingerprint input → stale banner; also names the overload rows.
    final elements = ref.watch(elementsProvider);
    // The pass itself runs in loudnessMeasureProvider, shared with the
    // Mix view's LAYOUTS bar; a report finishing there lands here too.
    final measure = ref.watch(loudnessMeasureProvider);
    final running = measure.running;
    ref.listen(loudnessReportProvider, (_, next) {
      if (next != null) _selectDefaultRows(next);
    });
    final stale =
        !running &&
        report != null &&
        report.fingerprint != ref.watch(currentLoudnessFingerprintProvider);

    // Track the window so the report keeps using available space. 1120
    // px holds the grid's columns at the Large font size, the IAMF / MON
    // tag at the StatusTag size included.
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(1120.0, screen.width - 80);
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
          _buildHeader(report, running, stale),
          const SizedBox(height: 12),
          Container(height: 1, color: T.border),
          const SizedBox(height: 12),
          if (measure.error case final error?) ...[
            ReportBanner(text: error, color: T.errorRed),
            const SizedBox(height: 12),
          ] else if (stale) ...[
            ReportBanner(
              text:
                  'The session changed since this report was measured, '
                  'so values may no longer match. Re-measure to refresh.',
              color: T.meterYellow,
            ),
            const SizedBox(height: 12),
          ],
          if (running)
            Expanded(
              child: MeasureProgressView(
                measure: measure,
                onCancel: ref.read(loudnessMeasureProvider.notifier).cancel,
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
            // Per-element overload warnings (ES-527): the grid's
            // mix-level peaks are post-limiter by decision
            // (`4ab3166`) and can read clean even while an element
            // overloads — these rows are the element-level check.
            if (clipGateRows(report.elementClipStats, elements)
                case final overloads when overloads.isNotEmpty) ...[
              _OverloadPanel(rows: overloads),
              const SizedBox(height: 12),
            ],
            Expanded(flex: 5, child: _buildGrid(report, mixes)),
            const SizedBox(height: 12),
            Container(height: 1, color: T.border),
            const SizedBox(height: 12),
            Expanded(flex: 4, child: _buildChart(report, mixes)),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(LoudnessReportData? report, bool running, bool stale) {
    return Row(
      children: [
        Text('Loudness Report', style: T.styleDialogTitle),
        const SizedBox(width: 12),
        if (report != null && !running)
          Text(
            'measured at ${formatReportTime(report.measuredAt)}',
            style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
          ),
        const Spacer(),
        if (!running)
          AppButton(
            label: stale ? 'Re-measure' : 'Measure Again',
            role: stale || report == null
                ? AppButtonRole.affirmative
                : AppButtonRole.standard,
            size: AppButtonSize.compact,
            onPressed: ref.read(loudnessMeasureProvider.notifier).run,
          ),
      ],
    );
  }

  // ── Grid ────────────────────────────────────────────────────────────

  String _mixName(List<Mix> mixes, int mixId) =>
      mixes.where((m) => m.id == mixId).firstOrNull?.name ?? 'Mix #$mixId';

  Widget _buildGrid(LoudnessReportData report, List<Mix> mixes) {
    final cols = _measureColumns(context);
    final rows = <Widget>[];
    int? lastMixId;
    int? lastSubIdx;
    for (final m in report.results) {
      if (m.mixId != lastMixId) {
        lastMixId = m.mixId;
        lastSubIdx = null;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              _mixName(mixes, m.mixId),
              style: TextStyle(
                fontSize: T.fontBodyL,
                fontWeight: FontWeight.w600,
                color: T.textPrimary,
              ),
            ),
          ),
        );
      }
      final mix = mixes.where((x) => x.id == m.mixId).firstOrNull;
      final showSub = (mix?.subMixes.length ?? 1) > 1;
      if (showSub && m.subMixIndex != lastSubIdx) {
        lastSubIdx = m.subMixIndex;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
            child: Text(
              mix?.subMixes[m.subMixIndex].label ?? 'Sub-mix ${m.subMixIndex}',
              style: TextStyle(fontSize: T.fontSmall, color: T.textTertiary),
            ),
          ),
        );
      }
      rows.add(_buildRow(report, m, cols));
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

  /// The widest string each numeric cell prints. A value at or below
  /// -120 prints as "—", so "-119.9" is the longest number; limiter
  /// gain reduction is unsigned.
  static const _widestValues = [
    '-119.9 LUFS',
    '-119.9 dBTP',
    '-119.9 dBFS',
    '-119.9 LU',
    '119.9 dB',
    '100%',
  ];

  /// Numeric and badge column widths, measured from the widest text
  /// each column renders at the current font-size mode (ES-621). A fixed
  /// 78 px fit Medium only: at Large the INTEGRATED header and every
  /// value wrapped to a second line. Measured under [context] so the
  /// ambient text style and text scaler match the rendered cells.
  static _GridColumns _measureColumns(BuildContext context) {
    final value = math.max(
      widestTextWidth(context, _valueHeaders, reportHeaderStyle()),
      widestTextWidth(context, _widestValues, reportValueStyle()),
    );
    return (
      value: value + T.gapSm,
      badge: LayoutTagBadge.width(context) + T.gapSm,
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
          for (final label in _valueHeaders.take(4))
            h(label, width: cols.value),
          Tooltip(
            message: kReportGrTooltip,
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

  Widget _buildRow(
    LoudnessReportData report,
    MeasuredLayoutLoudness m,
    _GridColumns cols,
  ) {
    final key = _rowKey(m);
    final selected = _selectedRows.contains(key);
    final color = reportRowColor(report.results.indexOf(m));
    final lra = m.traces?.loudnessRangeLu;
    // Limiter disclosure (ES-517): the row's numbers are measured after
    // the −1 dBFS limiter while the exported file ships unlimited —
    // GR > 0 marks where the exported audio exceeds −1 dBFS.
    final maxGr = m.traces?.maxLimiterGrDb ?? 0.0;
    // One engagement predicate drives both cells: engaged iff any step
    // exceeds the threshold, which is exactly maxGr > threshold — the
    // fraction (a second traversal) is only computed when it shows.
    final grEngaged = maxGr > MixMeasureTraces.engagedThresholdDb;
    final limitedFraction = grEngaged
        ? (m.traces?.limiterEngagedFraction ?? 0.0)
        : 0.0;

    Widget cell(String text, {Color? color}) => SizedBox(
      width: cols.value,
      child: Text(
        text,
        textAlign: TextAlign.right,
        maxLines: 1,
        softWrap: false,
        style: reportValueStyle(color: color),
      ),
    );

    Widget value(double v, String unit) =>
        cell(formatProgrammeScalar(v, unit: unit));

    return ReportRowShell(
      selected: selected,
      onTap: () {
        setState(() {
          if (!_selectedRows.remove(key)) _selectedRows.add(key);
        });
      },
      child: Row(
        children: [
          SizedBox(
            width: kReportCheckColumn,
            child: Center(
              child: ReportSelectDot(selected: selected, color: color),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                m.soundSystem.uiLabel,
                style: TextStyle(fontSize: T.fontBody, color: T.textValue),
              ),
            ),
          ),
          value(m.scalars.integratedLufs, 'LUFS'),
          value(m.scalars.truePeakDbtp, 'dBTP'),
          value(m.scalars.digitalPeakDbfs, 'dBFS'),
          cell(
            lra == null ? '—' : '${lra.toStringAsFixed(1)} LU',
            color: T.textValueDim,
          ),
          Tooltip(
            message: kReportGrTooltip,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                cell(
                  grEngaged ? '${maxGr.toStringAsFixed(1)} dB' : '—',
                  color: grEngaged ? T.meterYellow : T.textValueDim,
                ),
                cell(
                  grEngaged
                      ? '${(limitedFraction * 100).toStringAsFixed(0)}%'
                      : '—',
                  color: grEngaged ? T.meterYellow : T.textValueDim,
                ),
              ],
            ),
          ),
          SizedBox(
            width: cols.badge,
            child: Align(
              alignment: Alignment.centerRight,
              child: LayoutTagBadge(tagged: m.taggedInMix),
            ),
          ),
        ],
      ),
    );
  }

  // ── Chart ───────────────────────────────────────────────────────────

  Widget _buildChart(LoudnessReportData report, List<Mix> mixes) {
    final selected = [
      for (final m in report.results)
        if (_selectedRows.contains(_rowKey(m)) && m.traces != null) m,
    ];
    final traces = <ReportChartTrace>[
      for (final m in selected)
        ReportChartTrace(
          label: '${_mixName(mixes, m.mixId)} · ${m.soundSystem.uiLabel}',
          color: reportRowColor(report.results.indexOf(m)),
          values: switch (_series) {
            ReportChartSeries.shortTerm => m.traces!.shortTermLufs,
            ReportChartSeries.momentary => m.traces!.momentaryLufs,
            ReportChartSeries.psr => m.traces!.shortTermPsrDb,
          },
          // A window's first entry lands when the window fills.
          offsetSeconds: _series == ReportChartSeries.momentary ? 0.4 : 3.0,
        ),
    ];
    // Parallel limiter-GR traces for the always-on GR lane (ES-517):
    // entry k covers bucket k, plotted at the bucket's end time.
    final grTraces = <ReportChartTrace>[
      for (final m in selected)
        ReportChartTrace(
          label: '${_mixName(mixes, m.mixId)} · ${m.soundSystem.uiLabel}',
          color: reportRowColor(report.results.indexOf(m)),
          values: m.traces!.limiterGrDb,
          offsetSeconds: 0.1,
        ),
    ];
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
            'GR lane: limiter gain reduction, where the exported '
            '(unlimited) audio exceeds −1 dBFS',
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

// ── Small widgets ─────────────────────────────────────────────────────

/// Per-element signal-overload warnings (ES-527): the same rows the IAMF
/// export dialog shows in its pre-encode gate, surfaced here so a hot
/// element is visible without ever opening the export dialog. Capped in
/// height so a many-element session cannot crowd out the grid.
class _OverloadPanel extends StatelessWidget {
  final List<ElementOverloadRow> rows;
  const _OverloadPanel({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.gapMd),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.meterYellow.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SIGNAL OVERLOAD', style: T.styleEyebrow),
          const SizedBox(height: T.gapPair),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 96),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final row in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: T.meterYellow,
                          ),
                          const SizedBox(width: T.gapSm),
                          Expanded(
                            child: Text(
                              row.message,
                              style: TextStyle(
                                color: T.textSecondary,
                                fontSize: T.fontBody,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Text(
            'The mix values below are measured after the limiter and can '
            'look clean even when an element overloads. Samples above full '
            'scale will be hard-clipped on IAMF export. Reduce the element '
            'gain or source level.',
            style: TextStyle(color: T.textTertiary, fontSize: T.fontCaption),
          ),
        ],
      ),
    );
  }
}
