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

// Orchestration tests for measureMixLoudness with the per-pass runner
// injected (no engine dylib): element assembly from session state
// (source path, pre-gain, routing, pad, rate — the ES-484 stream inputs),
// sequential per-layout progress, cancel between layouts with partial
// results, and failure surfacing the layout label.

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/element_clip_stats.dart';
import 'package:eclipsa_studio/export/iamf_measure_isolate.dart';
import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/state.dart';

AudioElement _element(
  int id, {
  String wavPath = '/tmp/a.wav',
  double gain = 0,
  List<int>? routing,
}) {
  return AudioElement(
    id: id,
    name: 'el$id',
    type: 'Channel',
    layout: 'Stereo',
    codec: 'PCM',
    color: 0xFF000000,
    gain: gain,
    wavPath: wavPath,
    inputRouting: routing,
  );
}

Mix _mix(
  int id, {
  double outputGain = 0,
  List<SoundSystem> layouts = const [SoundSystem.stereo],
  List<MixElementSettings> settings = const [MixElementSettings(elementId: 1)],
}) {
  return Mix(
    id: id,
    name: 'Mix $id',
    subMixes: [
      SubMix(
        outputMixGain: outputGain,
        elementSettings: settings,
        layouts: [for (final s in layouts) MixLayout(soundSystem: s)],
      ),
    ],
  );
}

/// One recorded runPass invocation.
class _Pass {
  final int oarLayout;
  final double outputMixGainDb;
  final List<MixMeasureElement> elements;
  _Pass(this.oarLayout, this.outputMixGainDb, this.elements);
}

const MixMeasureResult _kScalars = (
  integratedLufs: -16.0,
  truePeakDbtp: -1.0,
  digitalPeakDbfs: -2.0,
);

void main() {
  test('assembles the stream inputs from session state per element', () async {
    final passes = <_Pass>[];
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(
          1,
          outputGain: -3,
          settings: const [
            MixElementSettings(elementId: 1, mixGain: -4),
            MixElementSettings(elementId: 2, included: false),
            MixElementSettings(elementId: 99), // no such element — skipped
          ],
        ),
      ],
      elements: [
        _element(1, wavPath: '/stems/a.wav', gain: -6, routing: [1, 0]),
        _element(2, wavPath: '/stems/b.wav'),
      ],
      paddedFrames: 96000,
      sampleRate: 48000,
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            passes.add(_Pass(oarLayout, outputMixGainDb, elements));
            return const MixMeasureOutcome(scalars: _kScalars);
          },
    );

    expect(outcome.status, LoudnessPassStatus.completed);
    expect(outcome.results.single.scalars, _kScalars);

    final pass = passes.single;
    expect(pass.oarLayout, 2); // stereo
    expect(pass.outputMixGainDb, -3);

    // Element 2 is excluded, element 99 doesn't exist: exactly one
    // element reaches the renderer, carrying the same source-of-truth
    // stream inputs the encode uses.
    final elem = pass.elements.single;
    expect(elem.sourceWavPath, '/stems/a.wav');
    expect(elem.gainDb, -6);
    expect(elem.routing, [1, 0]);
    expect(elem.padToFrames, 96000);
    expect(elem.outputSampleRate, 48000);
    expect(elem.mixGainDb, -4);
    expect(elem.channels, 2);
  });

  test('cancel between layouts keeps completed results', () async {
    var completed = 0;
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(1, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      isCancelled: () => completed >= 1, // flips after the first pass
      // Sequential mode: cancel-before-dispatch is only observable
      // between passes when exactly one runs at a time.
      maxConcurrency: 1,
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            completed++;
            return const MixMeasureOutcome(scalars: _kScalars);
          },
    );

    expect(outcome.status, LoudnessPassStatus.cancelled);
    expect(completed, 1); // the second pass never ran
    expect(outcome.results, hasLength(1));
    expect(outcome.results.single.soundSystem, SoundSystem.stereo);
  });

  test(
    'aggregates per-element clip stats across layouts (max-merge)',
    () async {
      var calls = 0;
      final outcome = await measureMixLoudness(
        mixes: [
          _mix(1, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
        ],
        elements: [_element(1)],
        paddedFrames: 48000,
        sampleRate: 48000,
        maxConcurrency: 1,
        runPass:
            ({
              required int sampleRate,
              required int bufferSize,
              required int oarLayout,
              required double outputMixGainDb,
              required List<MixMeasureElement> elements,
              bool withTraces = false,
            }) async {
              calls++;
              // Slightly different numbers per layout cell; the aggregate
              // must keep the max of each field.
              return MixMeasureOutcome(
                scalars: _kScalars,
                elementClipStats: {
                  1: ElementClipStats(
                    clippedSamples: calls == 1 ? 10 : 7,
                    peakLinear: calls == 1 ? 1.2 : 1.5,
                  ),
                },
              );
            },
      );

      expect(outcome.status, LoudnessPassStatus.completed);
      final stats = outcome.elementClipStats[1]!;
      expect(stats.clippedSamples, 10);
      expect(stats.peakLinear, 1.5);
    },
  );

  test('cancel keeps the partial clip-stats aggregate', () async {
    var completed = 0;
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(1, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      isCancelled: () => completed >= 1,
      maxConcurrency: 1,
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            completed++;
            return const MixMeasureOutcome(
              scalars: _kScalars,
              elementClipStats: {
                1: ElementClipStats(clippedSamples: 3, peakLinear: 1.1),
              },
            );
          },
    );

    expect(outcome.status, LoudnessPassStatus.cancelled);
    expect(outcome.elementClipStats[1]!.clippedSamples, 3);
  });

  test('a failed pass surfaces the layout label and partial results', () async {
    var calls = 0;
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(1, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            calls++;
            if (calls == 2) return null; // second layout fails
            return const MixMeasureOutcome(scalars: _kScalars);
          },
    );

    expect(outcome.status, LoudnessPassStatus.failed);
    expect(outcome.failedLayoutLabel, SoundSystem.surround5_1.uiLabel);
    expect(outcome.results, hasLength(1));
  });

  test('reports per-layout progress across mixes sequentially', () async {
    final progress = <(int, int)>[];
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(1),
        _mix(2, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      onProgress: (done, total) => progress.add((done, total)),
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async => const MixMeasureOutcome(scalars: _kScalars),
    );

    expect(outcome.status, LoudnessPassStatus.completed);
    expect(outcome.results, hasLength(3));
    expect(progress, [(1, 3), (2, 3), (3, 3)]);
  });

  test('out-of-order completions still yield plan-ordered results', () async {
    // First layout (stereo) finishes LAST; results must still come back
    // in plan order, not completion order.
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(
          1,
          layouts: const [
            SoundSystem.stereo,
            SoundSystem.surround5_1,
            SoundSystem.surround7_1_4,
          ],
        ),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      maxConcurrency: 3,
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            await Future<void>.delayed(
              Duration(milliseconds: oarLayout == 2 ? 60 : 5),
            );
            return const MixMeasureOutcome(scalars: _kScalars);
          },
    );

    expect(outcome.status, LoudnessPassStatus.completed);
    expect(outcome.results.map((r) => r.soundSystem), [
      SoundSystem.stereo,
      SoundSystem.surround5_1,
      SoundSystem.surround7_1_4,
    ]);
  });

  test('pooled progress stays monotonic under concurrency', () async {
    final progress = <(int, int)>[];
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(1),
        _mix(2, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      maxConcurrency: 3,
      onProgress: (done, total) => progress.add((done, total)),
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            // Jittered completion order.
            await Future<void>.delayed(
              Duration(milliseconds: 5 + (oarLayout % 3) * 10),
            );
            return const MixMeasureOutcome(scalars: _kScalars);
          },
    );

    expect(outcome.status, LoudnessPassStatus.completed);
    expect(progress, hasLength(3));
    for (var i = 0; i < progress.length; i++) {
      expect(progress[i], (i + 1, 3)); // 1/3, 2/3, 3/3 — monotonic
    }
  });

  test(
    'pooled cancel drains in-flight passes and keeps their results',
    () async {
      var cancelled = false;
      var started = 0;
      var finished = 0;
      final outcome = await measureMixLoudness(
        mixes: [
          _mix(
            1,
            layouts: const [
              SoundSystem.stereo,
              SoundSystem.surround5_1,
              SoundSystem.surround7_1_4,
              SoundSystem.surround9_1_6, // never dispatched after cancel
            ],
          ),
        ],
        elements: [_element(1)],
        paddedFrames: 48000,
        sampleRate: 48000,
        maxConcurrency: 2,
        isCancelled: () => cancelled,
        runPass:
            ({
              required int sampleRate,
              required int bufferSize,
              required int oarLayout,
              required double outputMixGainDb,
              required List<MixMeasureElement> elements,
              bool withTraces = false,
            }) async {
              started++;
              await Future<void>.delayed(const Duration(milliseconds: 10));
              finished++;
              cancelled = true; // flips while the other worker is in flight
              return const MixMeasureOutcome(scalars: _kScalars);
            },
      );

      expect(outcome.status, LoudnessPassStatus.cancelled);
      // Both initially dispatched passes ran to completion and their
      // results were kept; nothing new was dispatched after the flip.
      expect(started, 2);
      expect(finished, 2);
      expect(outcome.results, hasLength(2));
      expect(outcome.results.map((r) => r.soundSystem), [
        SoundSystem.stereo,
        SoundSystem.surround5_1,
      ]);
    },
  );

  test('pooled failure reports the lowest failed plan index', () async {
    final outcome = await measureMixLoudness(
      mixes: [
        _mix(
          1,
          layouts: const [
            SoundSystem.stereo, // fails slowly
            SoundSystem.surround5_1, // fails fast
          ],
        ),
      ],
      elements: [_element(1)],
      paddedFrames: 48000,
      sampleRate: 48000,
      maxConcurrency: 2,
      runPass:
          ({
            required int sampleRate,
            required int bufferSize,
            required int oarLayout,
            required double outputMixGainDb,
            required List<MixMeasureElement> elements,
            bool withTraces = false,
          }) async {
            // The 5.1 pass fails first, the stereo pass fails later —
            // the reported label must still be the lowest plan index
            // (stereo), independent of completion order.
            await Future<void>.delayed(
              Duration(milliseconds: oarLayout == 2 ? 30 : 5),
            );
            return null;
          },
    );

    expect(outcome.status, LoudnessPassStatus.failed);
    expect(outcome.failedLayoutLabel, SoundSystem.stereo.uiLabel);
    expect(outcome.results, isEmpty);
  });

  test('a thrown pass drains the pool and rethrows', () async {
    var started = 0;
    await expectLater(
      measureMixLoudness(
        mixes: [
          _mix(1, layouts: const [SoundSystem.stereo, SoundSystem.surround5_1]),
        ],
        elements: [_element(1)],
        paddedFrames: 48000,
        sampleRate: 48000,
        maxConcurrency: 2,
        runPass:
            ({
              required int sampleRate,
              required int bufferSize,
              required int oarLayout,
              required double outputMixGainDb,
              required List<MixMeasureElement> elements,
              bool withTraces = false,
            }) async {
              started++;
              if (oarLayout == 2) throw StateError('boom');
              await Future<void>.delayed(const Duration(milliseconds: 10));
              return const MixMeasureOutcome(scalars: _kScalars);
            },
      ),
      throwsStateError,
    );
    expect(started, 2); // in-flight pass drained before the rethrow
  });

  group('uniqueWavBasenames', () {
    test('distinct paths with one basename disambiguate by element id', () {
      final map = uniqueWavBasenames([
        _element(1, wavPath: '/stems/drums.wav'),
        _element(2, wavPath: '/alt/drums.wav'),
      ]);
      expect(map[1], 'drums.wav');
      expect(map[2], 'drums_2.wav');
    });

    test('elements sharing one source WAV get distinct join keys', () {
      // Regression: keyed by path, the second element overwrote the
      // first's entry, both push elements carried one basename, and the
      // engine's metadata join collapsed them onto one audio_element_id.
      final map = uniqueWavBasenames([
        _element(1, wavPath: '/stems/drums.wav'),
        _element(2, wavPath: '/stems/drums.wav'),
      ]);
      expect(map[1], 'drums.wav');
      expect(map[2], 'drums_2.wav');
      expect(map.values.toSet(), hasLength(2));
    });
  });
}
