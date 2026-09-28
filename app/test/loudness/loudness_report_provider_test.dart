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

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/loudness/loudness_report_provider.dart';
import 'package:eclipsa_studio/state.dart';

Mix _mix(int id, List<SoundSystem> layouts) {
  return Mix(
    id: id,
    name: 'Mix $id',
    subMixes: [
      SubMix(layouts: [for (final s in layouts) MixLayout(soundSystem: s)]),
    ],
  );
}

MeasuredLayoutLoudness _result(
  int mixId,
  SoundSystem soundSystem, {
  bool tagged = true,
}) {
  return MeasuredLayoutLoudness(
    mixId: mixId,
    subMixIndex: 0,
    soundSystem: soundSystem,
    taggedInMix: tagged,
    scalars: (integratedLufs: -16.0, truePeakDbtp: -1.0, digitalPeakDbfs: -2.0),
  );
}

LoudnessReportData _report(List<MeasuredLayoutLoudness> results) {
  return LoudnessReportData(
    results: results,
    fingerprint: 'fp',
    measuredAt: DateTime(2026),
    sampleRate: 48000,
    elementClipStats: const {},
  );
}

void main() {
  group('coversAllTaggedLayouts', () {
    test('true when every tagged layout has a tagged result', () {
      final mixes = [
        _mix(1, [SoundSystem.stereo, SoundSystem.surround5_1]),
      ];
      final report = _report([
        _result(1, SoundSystem.stereo),
        _result(1, SoundSystem.surround5_1),
      ]);
      expect(report.coversAllTaggedLayouts(mixes), isTrue);
    });

    test('false when a layout is missing', () {
      final mixes = [
        _mix(1, [SoundSystem.stereo, SoundSystem.surround5_1]),
      ];
      final report = _report([_result(1, SoundSystem.stereo)]);
      expect(report.coversAllTaggedLayouts(mixes), isFalse);
    });

    test('monitoring-only results do not count as coverage', () {
      final mixes = [
        _mix(1, [SoundSystem.stereo]),
      ];
      final report = _report([_result(1, SoundSystem.stereo, tagged: false)]);
      expect(report.coversAllTaggedLayouts(mixes), isFalse);
    });

    // Every shipped SoundSystem maps to an OAR target layout, so none is
    // exempt from coverage — 10.2.9.3 included. It used to be exempt only
    // because soundSystemToOarLayout wrongly reported it unrenderable.
    test('10.2.9.3 is measured like any other layout, not exempt', () {
      final mixes = [
        _mix(1, [SoundSystem.stereo, SoundSystem.surround10_2_9_3]),
      ];
      final report = _report([_result(1, SoundSystem.stereo)]);
      expect(report.coversAllTaggedLayouts(mixes), isFalse);

      final full = _report([
        _result(1, SoundSystem.stereo),
        _result(1, SoundSystem.surround10_2_9_3),
      ]);
      expect(full.coversAllTaggedLayouts(mixes), isTrue);
    });

    test('extra results for other mixes do not satisfy coverage', () {
      final mixes = [
        _mix(1, [SoundSystem.stereo]),
        _mix(2, [SoundSystem.stereo]),
      ];
      final report = _report([_result(1, SoundSystem.stereo)]);
      expect(report.coversAllTaggedLayouts(mixes), isFalse);
    });
  });

  group('canReuseLoudnessReport', () {
    final mixes = [
      _mix(1, [SoundSystem.stereo]),
    ];
    final report = _report([_result(1, SoundSystem.stereo)]);

    bool reuse({
      LoudnessReportData? withReport,
      String fingerprint = 'fp',
      int sampleRate = 48000,
      bool isPartialRange = false,
    }) {
      return canReuseLoudnessReport(
        report: withReport ?? report,
        currentFingerprint: fingerprint,
        sampleRate: sampleRate,
        isPartialRange: isPartialRange,
        mixes: mixes,
      );
    }

    test('reuses a matching, covering report', () {
      expect(reuse(), isTrue);
    });

    test('no report means no reuse', () {
      expect(
        canReuseLoudnessReport(
          report: null,
          currentFingerprint: 'fp',
          sampleRate: 48000,
          isPartialRange: false,
          mixes: mixes,
        ),
        isFalse,
      );
    });

    test('fingerprint mismatch forces re-measure', () {
      expect(reuse(fingerprint: 'other'), isFalse);
    });

    test('sample-rate mismatch forces re-measure', () {
      expect(reuse(sampleRate: 44100), isFalse);
    });

    test('a partial-range export always re-measures', () {
      // Cached measurements cover the full timeline; a clamped MP4
      // export ships something shorter and R128 must be measured over
      // what actually ships.
      expect(reuse(isPartialRange: true), isFalse);
    });

    test('incomplete tagged-layout coverage forces re-measure', () {
      final wider = [
        _mix(1, [SoundSystem.stereo, SoundSystem.surround5_1]),
      ];
      expect(
        canReuseLoudnessReport(
          report: report,
          currentFingerprint: 'fp',
          sampleRate: 48000,
          isPartialRange: false,
          mixes: wider,
        ),
        isFalse,
      );
    });
  });
}
