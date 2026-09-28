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

// Pins the font-scale safety of the Loudness Report grid (ES-621): at
// every font-size mode, every numeric header and every value cell
// renders on one line inside its measured column with no clipping, and
// the column grows with the font scale. The seeded rows print the
// widest strings the cells can show (-119.9 with each unit, a 100%
// limited fraction) and both badge labels.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/iamf_export_config.dart'
    show kIamfTargetSampleRate;
import 'package:eclipsa_studio/export/iamf_measure_isolate.dart';
import 'package:eclipsa_studio/loudness/loudness_fingerprint.dart';
import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/loudness/loudness_report_dialog.dart';
import 'package:eclipsa_studio/loudness/loudness_report_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';

const _headers = [
  'INTEGRATED',
  'TRUE PEAK',
  'PEAK',
  'LRA',
  'MAX GR',
  'LIMITED',
];

/// Every value string the seeded rows print, one finder each.
const _values = [
  '-119.9 LUFS',
  '-119.9 dBTP',
  '-119.9 dBFS',
  '-119.9 LU',
  '119.9 dB',
  '100%',
  '—',
  'IAMF',
  'MON',
];

final _elements = <AudioElement>[
  AudioElement(
    id: 1,
    name: 'Bed',
    type: 'Channel',
    layout: 'Stereo',
    codec: 'PCM',
    color: 0xFF000000,
    gain: 0,
    wavPath: '/tmp/bed.wav',
  ),
];

const _mixes = [
  Mix(id: 1, name: 'Main Mix', language: 'en', subMixes: [SubMix()]),
];

/// Traces whose limiter series is fully engaged at the widest GR the
/// cell can print, with a loudness range at the same width.
final _traces = MixMeasureTraces(
  momentaryLufs: Float32List(0),
  shortTermLufs: Float32List(0),
  shortTermPeakDbfs: Float32List(0),
  shortTermPsrDb: Float32List(0),
  limiterGrDb: Float32List.fromList([119.9, 119.9]),
  loudnessRangeLu: -119.9,
  lraStable: true,
);

const _scalars = (
  integratedLufs: -119.9,
  truePeakDbtp: -119.9,
  digitalPeakDbfs: -119.9,
);

class _FixedElements extends ElementsNotifier {
  @override
  List<AudioElement> build() => _elements;
}

class _FixedMixes extends MixesNotifier {
  @override
  List<Mix> build() => _mixes;
}

class _SeededReport extends LoudnessReportNotifier {
  @override
  LoudnessReportData? build() => LoudnessReportData(
    results: [
      MeasuredLayoutLoudness(
        mixId: 1,
        subMixIndex: 0,
        soundSystem: SoundSystem.stereo,
        taggedInMix: true,
        scalars: _scalars,
        traces: _traces,
      ),
      const MeasuredLayoutLoudness(
        mixId: 1,
        subMixIndex: 0,
        soundSystem: SoundSystem.surround7_1_4,
        taggedInMix: false,
        scalars: _scalars,
      ),
    ],
    fingerprint: loudnessFingerprint(
      elements: _elements,
      mixes: _mixes,
      sampleRate: kIamfTargetSampleRate,
    ),
    measuredAt: DateTime(2026, 9, 3, 12, 0),
    sampleRate: kIamfTargetSampleRate,
    elementClipStats: const {},
  );
}

Future<void> _pumpReport(WidgetTester tester, FontSizeMode mode) async {
  // The dialog lays out for a desktop window; the default 800×600 test
  // surface overflows its header under the wide Ahem test font.
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
        // Keyed per mode: a const dialog would be identical across pumps
        // and skip its rebuild, freezing the first mode's widths.
        home: LoudnessReportDialog(key: ValueKey(mode)),
      ),
    ),
  );
  // Let the post-frame fingerprint check run (it matches → no measure).
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

void main() {
  tearDown(() => T.setFontMode(FontSizeMode.medium));

  for (final mode in FontSizeMode.values) {
    testWidgets('every header and value fits its column at ${mode.label}', (
      tester,
    ) async {
      T.setFontMode(mode);
      await _pumpReport(tester, mode);
      for (final h in _headers) {
        _expectFits(tester, h, mode);
      }
      for (final v in _values) {
        _expectFits(tester, v, mode);
      }
    });
  }

  testWidgets('the value column tracks the font scale', (tester) async {
    final widths = <FontSizeMode, double>{};
    for (final mode in FontSizeMode.values) {
      T.setFontMode(mode);
      await _pumpReport(tester, mode);
      widths[mode] = tester.getSize(find.text('INTEGRATED')).width;
    }
    expect(widths[FontSizeMode.small], lessThan(widths[FontSizeMode.medium]!));
    expect(widths[FontSizeMode.medium], lessThan(widths[FontSizeMode.large]!));
  });
}
