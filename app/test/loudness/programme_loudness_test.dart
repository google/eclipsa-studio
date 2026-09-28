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

// Pins the per-layout programme-loudness lookup (ES-615): every row of
// the sub-mix keyed by layout, rows of another sub-mix or mix ignored,
// a monitoring-only row marked as not written to the file, the stale
// flag on every entry, and an empty map without a report.

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/loudness/loudness_report_provider.dart';
import 'package:eclipsa_studio/loudness/programme_loudness.dart';
import 'package:eclipsa_studio/state.dart';

MeasuredLayoutLoudness _row(
  SoundSystem s, {
  int mixId = 1,
  int subMix = 0,
  bool tagged = true,
  double lufs = -24,
  double tp = -2,
}) => MeasuredLayoutLoudness(
  mixId: mixId,
  subMixIndex: subMix,
  soundSystem: s,
  taggedInMix: tagged,
  scalars: (integratedLufs: lufs, truePeakDbtp: tp, digitalPeakDbfs: tp),
);

LoudnessReportData _report(List<MeasuredLayoutLoudness> rows) =>
    LoudnessReportData(
      results: rows,
      fingerprint: 'fp',
      measuredAt: DateTime(2026, 9, 3),
      sampleRate: 48000,
      elementClipStats: const {},
    );

void main() {
  group('programmeLoudnessByLayout', () {
    test('keys every row of the sub-mix by layout, nothing else', () {
      final m = programmeLoudnessByLayout(
        report: _report([
          _row(SoundSystem.stereo, lufs: -21),
          _row(SoundSystem.surround7_1_4, lufs: -23),
          _row(SoundSystem.surround5_1, tagged: false, lufs: -22),
          _row(SoundSystem.stereo, subMix: 1, lufs: -18),
          _row(SoundSystem.stereo, mixId: 2, lufs: -19),
        ]),
        stale: true,
        mixId: 1,
        subMixIndex: 0,
      );
      expect(
        m.keys,
        unorderedEquals([
          SoundSystem.stereo,
          SoundSystem.surround7_1_4,
          SoundSystem.surround5_1,
        ]),
      );
      expect(m[SoundSystem.stereo]!.integratedLufs, -21);
      expect(m[SoundSystem.stereo]!.layoutLabel, 'Stereo');
      expect(m[SoundSystem.surround5_1]!.writtenToFile, isFalse);
      expect(m.values.every((v) => v.stale), isTrue);
    });

    test('empty without a report', () {
      expect(
        programmeLoudnessByLayout(
          report: null,
          stale: false,
          mixId: 1,
          subMixIndex: 0,
        ),
        isEmpty,
      );
    });
  });
}
