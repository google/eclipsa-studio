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

// The QC Loudness Report store and runner (ES-520) without the engine:
// the report is handed out only for the open file, run() without an
// engine reports an error, discard() clears the report and the error,
// and the status bar's running-pass provider picks the pass that runs.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/loudness/loudness_measure_runner.dart';
import 'package:eclipsa_studio/loudness/qc_loudness_report_provider.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/playback/playback_session.dart';

const _emptyReport = IamfProbeReport(
  ok: true,
  errorMessage: null,
  sampleRate: 48000,
  totalSamples: 48000,
  audioElements: [],
  mixPresentations: [],
);

QcLoudnessReportData _data(String path) => QcLoudnessReportData(
  path: path,
  rows: const [],
  results: const [],
  measuredAt: DateTime(2026, 9, 30),
);

class _RunningQc extends QcLoudnessMeasureRunner {
  @override
  LoudnessMeasureState build() =>
      const LoudnessMeasureState(running: true, done: 1, total: 4);
}

class _RunningCreator extends LoudnessMeasureRunner {
  @override
  LoudnessMeasureState build() =>
      const LoudnessMeasureState(running: true, done: 2, total: 3);
}

void main() {
  late ProviderContainer container;

  ProviderContainer make({
    bool runningQc = false,
    bool runningCreator = false,
  }) => ProviderContainer(
    overrides: [
      eclipsaStudioEngineProvider.overrideWithValue(null),
      if (runningQc) qcLoudnessMeasureProvider.overrideWith(_RunningQc.new),
      if (runningCreator)
        loudnessMeasureProvider.overrideWith(_RunningCreator.new),
    ],
  );

  void openFile(String path) => container
      .read(playbackSessionProvider.notifier)
      .open(
        path: path,
        report: _emptyReport,
        sampleRate: 48000,
        totalFrames: 48000,
        audioElements: const [],
      );

  tearDown(() => container.dispose());

  group('currentQcLoudnessReportProvider', () {
    test('is null with no file open', () {
      container = make();
      container.read(qcLoudnessReportProvider.notifier).set(_data('/f/a.mp4'));
      expect(container.read(currentQcLoudnessReportProvider), isNull);
    });

    test('hands out the report only for the open file', () {
      container = make();
      openFile('/f/a.mp4');
      final notifier = container.read(qcLoudnessReportProvider.notifier);

      notifier.set(_data('/f/a.mp4'));
      expect(container.read(currentQcLoudnessReportProvider)?.path, '/f/a.mp4');

      notifier.set(_data('/f/b.mp4'));
      expect(container.read(currentQcLoudnessReportProvider), isNull);
    });
  });

  group('QcLoudnessMeasureRunner', () {
    test('run() without an engine reports an error', () async {
      container = make();
      openFile('/f/a.mp4');
      await container.read(qcLoudnessMeasureProvider.notifier).run();
      final state = container.read(qcLoudnessMeasureProvider);
      expect(state.running, isFalse);
      expect(state.error, 'Audio engine not available.');
    });

    test('discard() clears the report and the error', () async {
      container = make();
      openFile('/f/a.mp4');
      container.read(qcLoudnessReportProvider.notifier).set(_data('/f/a.mp4'));
      final runner = container.read(qcLoudnessMeasureProvider.notifier);
      await runner.run();
      expect(container.read(qcLoudnessMeasureProvider).error, isNotNull);

      runner.discard();
      expect(container.read(qcLoudnessMeasureProvider).error, isNull);
      expect(container.read(qcLoudnessMeasureProvider).running, isFalse);
      expect(container.read(qcLoudnessReportProvider), isNull);
    });
  });

  group('runningLoudnessMeasureProvider', () {
    test('is null when no pass runs', () {
      container = make();
      expect(container.read(runningLoudnessMeasureProvider), isNull);
    });

    test('is the QC pass while it runs', () {
      container = make(runningQc: true);
      expect(container.read(runningLoudnessMeasureProvider)?.total, 4);
    });

    test('is the creator pass while it runs', () {
      container = make(runningCreator: true);
      expect(container.read(runningLoudnessMeasureProvider)?.total, 3);
    });

    test('is the QC pass when both run', () {
      container = make(runningQc: true, runningCreator: true);
      expect(container.read(runningLoudnessMeasureProvider)?.total, 4);
    });
  });
}
