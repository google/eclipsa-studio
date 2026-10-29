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

// Selected rows in the Loudness Report (ES-1028): two adjacent selected
// rows draw as two fills kReportRowGap apart, each row's badge sits
// T.gapSm inside its fill, the header's columns line up with the rows',
// and the hover and press highlight has the fill's rounded corners.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/iamf_export_config.dart'
    show kIamfTargetSampleRate;
import 'package:eclipsa_studio/export/iamf_measure_isolate.dart';
import 'package:eclipsa_studio/loudness/loudness_fingerprint.dart';
import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/loudness/loudness_report_dialog.dart';
import 'package:eclipsa_studio/loudness/loudness_report_provider.dart';
import 'package:eclipsa_studio/loudness/loudness_report_widgets.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';

final _elements = <AudioElement>[
  AudioElement(
    id: 1,
    name: 'Bed',
    type: 'Channel',
    layout: '7.1.4',
    codec: 'PCM',
    color: 0xFF000000,
    gain: 0,
    wavPath: '/tmp/bed.wav',
  ),
];

const _mixes = [
  Mix(id: 1, name: 'Main Mix', language: 'en', subMixes: [SubMix()]),
];

final _traces = MixMeasureTraces(
  momentaryLufs: Float32List(0),
  shortTermLufs: Float32List(0),
  shortTermPsrDb: Float32List(0),
  limiterGrDb: Float32List(0),
  loudnessRangeLu: 16.8,
);

class _FixedElements extends ElementsNotifier {
  @override
  List<AudioElement> build() => _elements;
}

class _FixedMixes extends MixesNotifier {
  @override
  List<Mix> build() => _mixes;
}

/// Two tagged layouts of the first mix, which the dialog selects when
/// it opens.
class _SeededReport extends LoudnessReportNotifier {
  @override
  LoudnessReportData? build() => LoudnessReportData(
    results: [
      MeasuredLayoutLoudness(
        mixId: 1,
        subMixIndex: 0,
        soundSystem: SoundSystem.stereo,
        taggedInMix: true,
        scalars: (
          integratedLufs: -24.9,
          truePeakDbtp: -5.8,
          digitalPeakDbfs: -5.8,
        ),
        traces: _traces,
      ),
      MeasuredLayoutLoudness(
        mixId: 1,
        subMixIndex: 0,
        soundSystem: SoundSystem.surround7_1_4,
        taggedInMix: true,
        scalars: (
          integratedLufs: -23.0,
          truePeakDbtp: -8.9,
          digitalPeakDbfs: -8.9,
        ),
        traces: _traces,
      ),
    ],
    fingerprint: loudnessFingerprint(
      elements: _elements,
      mixes: _mixes,
      sampleRate: kIamfTargetSampleRate,
    ),
    measuredAt: DateTime(2026, 10, 28, 23, 0),
    sampleRate: kIamfTargetSampleRate,
    elementClipStats: const {},
  );
}

/// The selected rows' fills, top to bottom.
List<Rect> _selectedFills(WidgetTester tester) {
  final fills = find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).color == T.bgSelected,
  );
  return [
    for (var i = 0; i < fills.evaluate().length; i++)
      tester.getRect(fills.at(i)),
  ]..sort((a, b) => a.top.compareTo(b.top));
}

void main() {
  Future<void> pumpReport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          elementsProvider.overrideWith(_FixedElements.new),
          mixesNotifierProvider.overrideWith(_FixedMixes.new),
          loudnessReportProvider.overrideWith(_SeededReport.new),
        ],
        child: MaterialApp(
          theme: eclipsaStudioTheme(),
          home: const LoudnessReportDialog(),
        ),
      ),
    );
    // The post-frame callback selects the first mix's tagged layouts.
    await tester.pump();
  }

  testWidgets('two adjacent selected rows are two fills, the gap apart', (
    tester,
  ) async {
    await pumpReport(tester);

    final fills = _selectedFills(tester);
    expect(fills, hasLength(2));
    expect(fills[1].top - fills[0].bottom, kReportRowGap);
  });

  testWidgets('each badge sits inside its row fill', (tester) async {
    await pumpReport(tester);

    final fills = _selectedFills(tester);
    final badgeFinder = find.byType(LayoutTagBadge);
    final badges = [
      for (var i = 0; i < badgeFinder.evaluate().length; i++)
        tester.getRect(badgeFinder.at(i)),
    ]..sort((a, b) => a.top.compareTo(b.top));
    expect(badges, hasLength(2));
    for (var i = 0; i < 2; i++) {
      expect(badges[i].right, fills[i].right - T.gapSm);
    }
  });

  testWidgets('the header columns line up with the rows', (tester) async {
    await pumpReport(tester);

    expect(
      tester.getRect(find.text('INTEGRATED')).right,
      tester.getRect(find.text('-24.9 LUFS')).right,
    );
  });

  testWidgets('the highlight has the fill corners', (tester) async {
    await pumpReport(tester);

    final inkWell = tester.widget<InkWell>(
      find.ancestor(
        of: find.text('-24.9 LUFS'),
        matching: find.byType(InkWell),
      ),
    );
    expect(inkWell.borderRadius, BorderRadius.circular(T.radiusSm));
  });
}
