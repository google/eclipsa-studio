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
/// Opens from View → Loudness Report…. Measurement starts on open when
/// there is no current (fingerprint-matching) report; a completed
/// report is kept in [loudnessReportProvider] for the app run and
/// seeds the IAMF export's measure phase. The grid covers each
/// sub-mix's tagged layouts plus the current monitoring layout —
/// monitoring-only rows are badged and never written to the session or
/// the IAMF bitstream.
library;

import 'dart:math' as math;
import 'dart:typed_data';

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
import 'loudness_measure_runner.dart';
import 'loudness_measurement.dart';
import 'loudness_report_provider.dart';
import 'programme_loudness.dart' show formatProgrammeScalar;

/// Trace series selectable in the chart.
enum _ChartSeries {
  shortTerm('Short-term', 'LUFS'),
  momentary('Momentary', 'LUFS'),
  psr('PSR', 'dB');

  const _ChartSeries(this.label, this.unit);
  final String label;
  final String unit;
}

/// Measured widths of the grid's numeric and badge columns.
typedef _GridColumns = ({double value, double badge});

class LoudnessReportDialog extends ConsumerStatefulWidget {
  const LoudnessReportDialog({super.key});

  static void show(BuildContext context) {
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
  _ChartSeries _series = _ChartSeries.shortTerm;

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

    // Track the window so the report keeps using available space.
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(1100.0, screen.width - 80);
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
            _Banner(text: error, color: T.errorRed),
            const SizedBox(height: 12),
          ] else if (stale) ...[
            _Banner(
              text:
                  'The session changed since this report was measured, '
                  'so values may no longer match. Re-measure to refresh.',
              color: T.meterYellow,
            ),
            const SizedBox(height: 12),
          ],
          if (running)
            Expanded(child: _buildProgress(measure))
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
            'measured at ${_fmtTime(report.measuredAt)}',
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

  Widget _buildProgress(LoudnessMeasureState measure) {
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
                onPressed: measure.cancelRequested
                    ? null
                    : ref.read(loudnessMeasureProvider.notifier).cancel,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Grid ────────────────────────────────────────────────────────────

  String _mixName(List<Mix> mixes, int mixId) =>
      mixes.where((m) => m.id == mixId).firstOrNull?.name ?? 'Mix #$mixId';

  Color _rowColor(LoudnessReportData report, MeasuredLayoutLoudness m) {
    final palette = [
      T.purpleLight,
      T.objCyan,
      T.objGreen,
      T.objAmber,
      T.pink,
      T.meterRed,
      T.textSecondary,
    ];
    final idx = report.results.indexOf(m);
    return palette[idx % palette.length];
  }

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

  /// Selection-dot column: a 12 px circle, no text, so it does not
  /// scale with the font mode.
  static const _colCheck = 30.0;

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

  /// Header cell style. Shared with [_measureColumns] so the rendered
  /// text and the measured width cannot drift.
  static TextStyle _headerStyle() => TextStyle(
    fontSize: T.fontCaption,
    color: T.textMuted,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
  );

  /// Value cell style; [color] is applied at the render site.
  static TextStyle _valueStyle({Color? color}) => TextStyle(
    fontFamily: T.monoFamily,
    fontSize: T.fontBody,
    color: color ?? T.textValue,
  );

  /// Numeric and badge column widths, measured from the widest text
  /// each column renders at the current font-size mode (ES-621). A fixed
  /// 78 px fit Medium only: at Large the INTEGRATED header and every
  /// value wrapped to a second line. Measured under [context] so the
  /// ambient text style and text scaler match the rendered cells.
  static _GridColumns _measureColumns(BuildContext context) {
    final value = math.max(
      widestTextWidth(context, _valueHeaders, _headerStyle()),
      widestTextWidth(context, _widestValues, _valueStyle()),
    );
    return (value: value + T.gapSm, badge: _IamfBadge.width(context) + T.gapSm);
  }

  /// Shared by the MAX GR / LIMITED header and value cells so the
  /// explanation is discoverable before any row engages.
  static const _grTooltip =
      'Limiter gain reduction — where the exported (unlimited) audio '
      'exceeds −1 dBFS. Report values are measured after the −1 dBFS '
      'limiter; the exported file is not limited.';

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
        style: _headerStyle(),
      );
      return width == null
          ? Expanded(child: t)
          : SizedBox(width: width, child: t);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: _colCheck),
          h('MIX / LAYOUT', align: TextAlign.left),
          for (final label in _valueHeaders.take(4))
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

  Widget _buildRow(
    LoudnessReportData report,
    MeasuredLayoutLoudness m,
    _GridColumns cols,
  ) {
    final key = _rowKey(m);
    final selected = _selectedRows.contains(key);
    final color = _rowColor(report, m);
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
        style: _valueStyle(color: color),
      ),
    );

    Widget value(double v, String unit) =>
        cell(formatProgrammeScalar(v, unit: unit));

    return InkWell(
      onTap: () {
        setState(() {
          if (!_selectedRows.remove(key)) _selectedRows.add(key);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: selected ? T.bgSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: Row(
          children: [
            SizedBox(
              width: _colCheck,
              child: Center(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? color : Colors.transparent,
                    border: Border.all(
                      color: selected ? color : T.borderStrong,
                    ),
                  ),
                ),
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
              message: _grTooltip,
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
                child: _IamfBadge(tagged: m.taggedInMix),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Chart ───────────────────────────────────────────────────────────

  Widget _buildChart(LoudnessReportData report, List<Mix> mixes) {
    final selected = [
      for (final m in report.results)
        if (_selectedRows.contains(_rowKey(m)) && m.traces != null) m,
    ];
    final traces = <_ChartTrace>[
      for (final m in selected)
        _ChartTrace(
          label: '${_mixName(mixes, m.mixId)} · ${m.soundSystem.uiLabel}',
          color: _rowColor(report, m),
          values: switch (_series) {
            _ChartSeries.shortTerm => m.traces!.shortTermLufs,
            _ChartSeries.momentary => m.traces!.momentaryLufs,
            _ChartSeries.psr => m.traces!.shortTermPsrDb,
          },
          // A window's first entry lands when the window fills.
          offsetSeconds: _series == _ChartSeries.momentary ? 0.4 : 3.0,
        ),
    ];
    // Parallel limiter-GR traces for the always-on GR lane (ES-517):
    // entry k covers bucket k, plotted at the bucket's end time.
    final grTraces = <_ChartTrace>[
      for (final m in selected)
        _ChartTrace(
          label: '${_mixName(mixes, m.mixId)} · ${m.soundSystem.uiLabel}',
          color: _rowColor(report, m),
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
            ConsoleSegment<_ChartSeries>(
              value: _series,
              options: [for (final s in _ChartSeries.values) (s, s.label)],
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
            'GR lane: limiter gain reduction — where the exported '
            '(unlimited) audio exceeds −1 dBFS',
            style: TextStyle(fontSize: T.fontCaption, color: T.textTertiary),
          ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(T.radiusSm),
            child: CustomPaint(
              painter: _TraceChartPainter(
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

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

// ── Small widgets ─────────────────────────────────────────────────────

class _Banner extends StatelessWidget {
  final String text;
  final Color color;
  const _Banner({required this.text, required this.color});

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

class _IamfBadge extends StatelessWidget {
  final bool tagged;
  const _IamfBadge({required this.tagged});

  static const _hPad = 6.0;
  static const _borderWidth = 1.0;

  /// Label style; the colour is applied at the render site. Shared
  /// with [width] so the pill and its column measure the same text.
  static TextStyle _style({Color? color}) => TextStyle(
    fontSize: T.fontMeter,
    color: color,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
  );

  /// Rendered width of the wider label at the current font mode, plus
  /// padding and border.
  static double width(BuildContext context) =>
      widestTextWidth(context, const ['IAMF', 'MON'], _style()) +
      2 * _hPad +
      2 * _borderWidth;

  @override
  Widget build(BuildContext context) {
    final color = tagged ? T.purpleLight : T.objAmber;
    return Tooltip(
      message: tagged
          ? 'This layout is tagged in the mix presentation. Its measured '
                'integrated loudness, digital peak and true peak are '
                'written into the IAMF file on export.'
          : 'Monitoring layout only: measured for reference, not part '
                'of this mix presentation, and never written to the '
                'IAMF file.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(
            color: color.withValues(alpha: 0.6),
            width: _borderWidth,
          ),
        ),
        child: Text(
          tagged ? 'IAMF' : 'MON',
          maxLines: 1,
          softWrap: false,
          style: _style(color: color),
        ),
      ),
    );
  }
}

// ── Chart painter ─────────────────────────────────────────────────────

class _ChartTrace {
  final String label;
  final Color color;
  final Float32List values;
  final double offsetSeconds;
  const _ChartTrace({
    required this.label,
    required this.color,
    required this.values,
    required this.offsetSeconds,
  });
}

class _TraceChartPainter extends CustomPainter {
  final List<_ChartTrace> traces;

  /// Limiter gain-reduction traces for the GR lane, parallel to
  /// [traces] (same rows, same colors). Non-empty whenever rows are
  /// selected, so the lane is always on and the layout stays stable.
  final List<_ChartTrace> grTraces;
  final int stepMs;
  final FontSizeMode fontMode;
  final AppThemeMode themeMode;

  const _TraceChartPainter({
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
  bool shouldRepaint(_TraceChartPainter old) =>
      old.traces != traces ||
      old.grTraces != grTraces ||
      old.stepMs != stepMs ||
      old.fontMode != fontMode ||
      old.themeMode != themeMode;
}
