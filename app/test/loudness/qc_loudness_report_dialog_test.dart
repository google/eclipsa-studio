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

// The QC Loudness Report dialog (ES-520) over a seeded report: the grid
// prints the measured line, the stored line and the Δ for a tagged row,
// the reason for a row that could not be measured, and the badges; a
// selected row's badge sits inside its fill, its columns line up with
// the header's, and its highlight has rounded corners (ES-1028); and every
// header and value fits its column at every font-size mode.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/iamf_measure_isolate.dart';
import 'package:eclipsa_studio/loudness/loudness_measure_runner.dart';
import 'package:eclipsa_studio/loudness/loudness_report_widgets.dart';
import 'package:eclipsa_studio/loudness/qc_loudness_measurement.dart';
import 'package:eclipsa_studio/loudness/qc_loudness_report_dialog.dart';
import 'package:eclipsa_studio/loudness/qc_loudness_report_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';

const _headers = [
  'INTEGRATED',
  'Δ LU',
  'TRUE PEAK',
  'PEAK',
  'LRA',
  'MAX GR',
  'LIMITED',
];

const _tagged = QcLoudnessRow(
  mixIndex: 0,
  mixId: 400,
  mixLabel: 'Main Mix',
  subMixIndex: 0,
  layoutIndex: 0,
  soundSystem: SoundSystem.stereo,
  layoutLabel: 'Stereo',
  taggedInFile: true,
  shipped: QcShippedLoudness(
    integratedLufs: -19.53,
    digitalPeakDbfs: 2.30,
    truePeakDbtp: 2.32,
  ),
);

const _monitoring = QcLoudnessRow(
  mixIndex: 0,
  mixId: 400,
  mixLabel: 'Main Mix',
  subMixIndex: 0,
  layoutIndex: -1,
  soundSystem: SoundSystem.binaural,
  layoutLabel: 'Binaural',
  taggedInFile: false,
  shipped: null,
);

const _unmeasurable = QcLoudnessRow(
  mixIndex: 0,
  mixId: 400,
  mixLabel: 'Main Mix',
  subMixIndex: 0,
  layoutIndex: 1,
  soundSystem: null,
  layoutLabel: '9.1.4',
  taggedInFile: true,
  shipped: QcShippedLoudness(
    integratedLufs: -20,
    digitalPeakDbfs: -3,
    truePeakDbtp: null,
  ),
  notMeasurableReason: 'The renderer cannot render 9.1.4.',
);

/// Traces whose limiter series is fully engaged at the widest GR the
/// cell can print, with a loudness range at the same width.
final _traces = MixMeasureTraces(
  momentaryLufs: Float32List(0),
  shortTermLufs: Float32List(0),
  shortTermPsrDb: Float32List(0),
  limiterGrDb: Float32List.fromList([119.9, 119.9]),
  loudnessRangeLu: -119.9,
);

const _widestScalars = (
  integratedLufs: -119.9,
  truePeakDbtp: -119.9,
  digitalPeakDbfs: -119.9,
);

QcLoudnessReportData _report({required bool widest}) => QcLoudnessReportData(
  path: '/qc/mahler.mp4',
  rows: const [_tagged, _monitoring, _unmeasurable],
  results: [
    QcMeasuredRow(
      row: _tagged,
      scalars: widest
          ? _widestScalars
          : (
              integratedLufs: -19.57,
              truePeakDbtp: -0.84,
              digitalPeakDbfs: -1.0,
            ),
      traces: _traces,
    ),
    QcMeasuredRow(
      row: _monitoring,
      scalars: widest
          ? _widestScalars
          : (integratedLufs: -18.2, truePeakDbtp: -0.9, digitalPeakDbfs: -1.0),
    ),
  ],
  measuredAt: DateTime(2026, 9, 30, 6, 30),
);

Future<void> _pump(
  WidgetTester tester, {
  required QcLoudnessReportData report,
  Key? key,
}) async {
  // The dialog lays out for a desktop window; the default 800×600 test
  // surface overflows its header under the wide Ahem test font.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentQcLoudnessReportProvider.overrideWith((ref) => report),
      ],
      child: MaterialApp(
        theme: eclipsaStudioTheme(),
        home: QcLoudnessReportDialog(key: key),
      ),
    ),
  );
  // Let the post-frame check run (a report exists, so no measure).
  await tester.pump();
}

/// Asserts every paragraph matching [text] laid out its whole string
/// inside the width it was given, on one line.
void _expectFits(WidgetTester tester, String text, FontSizeMode mode) {
  final paragraphs = tester.renderObjectList<RenderParagraph>(find.text(text));
  expect(paragraphs, isNotEmpty, reason: '"$text" must be in the grid');
  for (final p in paragraphs) {
    expect(
      p.textSize.width,
      lessThanOrEqualTo(p.size.width + 0.01),
      reason: '"$text" is clipped by its column at ${mode.label}',
    );
    expect(
      p.textSize.height,
      lessThanOrEqualTo(p.text.style!.fontSize! * 1.6),
      reason: '"$text" wraps to a second line at ${mode.label}',
    );
  }
}

/// A measure runner that starts running, as a pass discarded when
/// another file opened would still be, and counts the [run] calls that
/// would start a pass.
class _BusyRunner extends QcLoudnessMeasureRunner {
  int started = 0;

  @override
  LoudnessMeasureState build() =>
      const LoudnessMeasureState(running: true, cancelRequested: true);

  @override
  Future<void> run() async {
    if (state.running) return;
    started++;
  }

  void stop({String? error}) => state = LoudnessMeasureState(error: error);
}

Future<_BusyRunner> _pumpBusy(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final runner = _BusyRunner();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentQcLoudnessReportProvider.overrideWith((ref) => null),
        qcLoudnessMeasureProvider.overrideWith(() => runner),
      ],
      child: MaterialApp(
        theme: eclipsaStudioTheme(),
        home: const QcLoudnessReportDialog(),
      ),
    ),
  );
  await tester.pump();
  return runner;
}

void main() {
  tearDown(() => T.setFontMode(FontSizeMode.medium));

  testWidgets('measures once a pass running at open stops', (tester) async {
    final runner = await _pumpBusy(tester);
    expect(runner.started, 0);
    runner.stop();
    await tester.pump();
    expect(runner.started, 1);
  });

  testWidgets('does not measure again after a pass that failed', (
    tester,
  ) async {
    final runner = await _pumpBusy(tester);
    runner.stop(error: 'Measurement failed.');
    await tester.pump();
    expect(runner.started, 0);
  });

  testWidgets('prints measured, stored and Δ for a tagged row', (tester) async {
    await _pump(tester, report: _report(widest: false));
    expect(find.text('Main Mix'), findsOneWidget);
    expect(find.text('Stereo'), findsOneWidget);
    expect(find.text('-19.6 LUFS'), findsOneWidget); // measured
    expect(find.text('-19.5 LUFS'), findsOneWidget); // stored
    expect(find.text('+0.0'), findsOneWidget); // stored − measured
    expect(tester.widget<Text>(find.text('+0.0')).style!.color, T.textValueDim);
    expect(find.text('2.3 dBTP'), findsOneWidget); // stored true peak
    expect(find.text('2.3 dBFS'), findsOneWidget); // stored digital peak
    // Two tagged rows have a stored line; the monitoring row has none.
    expect(find.text('stored in file'), findsNWidgets(2));
    expect(find.text('IAMF'), findsNWidgets(2));
    expect(find.text('MON'), findsOneWidget);
  });

  group('the selected row (ES-1028)', () {
    // The dialog opens with the tagged Stereo row selected.
    final fill = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == T.bgSelected,
    );

    testWidgets('keeps its badge inside its fill', (tester) async {
      await _pump(tester, report: _report(widest: false));
      expect(fill, findsOneWidget);
      final badge = find.descendant(
        of: fill,
        matching: find.byType(LayoutTagBadge),
      );
      expect(tester.getRect(badge).right, tester.getRect(fill).right - T.gapSm);
    });

    testWidgets('lines its columns up with the header', (tester) async {
      await _pump(tester, report: _report(widest: false));
      expect(
        tester.getRect(find.text('INTEGRATED')).right,
        tester.getRect(find.text('-19.6 LUFS')).right,
      );
    });

    testWidgets('has rounded highlight corners', (tester) async {
      await _pump(tester, report: _report(widest: false));
      final inkWell = tester.widget<InkWell>(
        find.ancestor(of: fill, matching: find.byType(InkWell)),
      );
      expect(inkWell.borderRadius, BorderRadius.circular(T.radiusSm));
    });
  });

  testWidgets('a row that cannot be measured prints its reason', (
    tester,
  ) async {
    await _pump(tester, report: _report(widest: false));
    expect(find.text('The renderer cannot render 9.1.4.'), findsOneWidget);
    // Its stored values still show; the omitted true peak prints as —.
    expect(find.text('-20.0 LUFS'), findsOneWidget);
    expect(find.text('-3.0 dBFS'), findsOneWidget);
  });

  testWidgets('highlights a Δ above 0.5 LU', (tester) async {
    final report = QcLoudnessReportData(
      path: '/qc/mahler.mp4',
      rows: const [_tagged],
      results: const [
        QcMeasuredRow(
          row: _tagged,
          scalars: (
            integratedLufs: -21.0,
            truePeakDbtp: -1.0,
            digitalPeakDbfs: -1.0,
          ),
        ),
      ],
      measuredAt: DateTime(2026, 9, 30),
    );
    await _pump(tester, report: report);
    final delta = tester.widget<Text>(find.text('+1.5'));
    expect(delta.style!.color, T.meterYellow);
  });

  test('formatQcDeltaLu takes the sign of the rounded value', () {
    expect(formatQcDeltaLu(-0.04), '+0.0');
    expect(formatQcDeltaLu(0.04), '+0.0');
    expect(formatQcDeltaLu(0), '+0.0');
    expect(formatQcDeltaLu(1.46), '+1.5');
    expect(formatQcDeltaLu(-1.46), '-1.5');
  });

  testWidgets('marks a row measured with default gains that can vary', (
    tester,
  ) async {
    const varying = QcLoudnessRow(
      mixIndex: 0,
      mixId: 400,
      mixLabel: 'Main Mix',
      subMixIndex: 0,
      layoutIndex: 0,
      soundSystem: SoundSystem.stereo,
      layoutLabel: 'Stereo',
      taggedInFile: true,
      shipped: null,
      gainsMayVary: true,
    );
    final report = QcLoudnessReportData(
      path: '/qc/mahler.mp4',
      rows: const [varying, _monitoring],
      results: const [
        QcMeasuredRow(
          row: varying,
          scalars: (
            integratedLufs: -21.0,
            truePeakDbtp: -1.0,
            digitalPeakDbfs: -1.0,
          ),
        ),
        QcMeasuredRow(
          row: _monitoring,
          scalars: (
            integratedLufs: -18.2,
            truePeakDbtp: -0.9,
            digitalPeakDbfs: -1.0,
          ),
        ),
      ],
      measuredAt: DateTime(2026, 9, 30),
    );
    await _pump(tester, report: report);
    expect(find.text('Stereo *'), findsOneWidget);
    expect(find.text('Binaural'), findsOneWidget);
    expect(find.textContaining('Rows marked * belong to'), findsOneWidget);
  });

  testWidgets('has no gain note when no row is marked', (tester) async {
    await _pump(tester, report: _report(widest: false));
    expect(find.textContaining('Rows marked *'), findsNothing);
  });

  for (final mode in FontSizeMode.values) {
    testWidgets('every header and value fits its column at ${mode.label}', (
      tester,
    ) async {
      T.setFontMode(mode);
      await _pump(tester, report: _report(widest: true), key: ValueKey(mode));
      for (final h in _headers) {
        _expectFits(tester, h, mode);
      }
      for (final v in const [
        '-119.9 LUFS',
        '-119.9 dBTP',
        '-119.9 dBFS',
        '-119.9 LU',
        '119.9 dB',
        '+100.4', // Δ: stored -19.53 minus measured -119.9
        '100%',
        'IAMF',
        'MON',
      ]) {
        _expectFits(tester, v, mode);
      }
    });
  }
}
