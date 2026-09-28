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

import 'package:eclipsa_studio/loudness/loudness_fingerprint.dart';
import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/state.dart';

AudioElement _element(
  int id, {
  String? wavPath = '/tmp/a.wav',
  double gain = 0,
  List<int>? routing,
  String type = 'Channel',
  String layout = 'Stereo',
}) {
  return AudioElement(
    id: id,
    name: 'el$id',
    type: type,
    layout: layout,
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
  List<MixElementSettings> settings = const [],
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

MeasuredLayoutLoudness _result(
  int mixId,
  SoundSystem soundSystem, {
  bool tagged = true,
  double lufs = -16,
}) {
  return MeasuredLayoutLoudness(
    mixId: mixId,
    subMixIndex: 0,
    soundSystem: soundSystem,
    taggedInMix: tagged,
    scalars: (integratedLufs: lufs, truePeakDbtp: -1.0, digitalPeakDbfs: -2.0),
  );
}

void main() {
  group('mixesWithMeasuredLoudness', () {
    test('applies a tagged result to the matching layout', () {
      final mixes = [
        _mix(1, layouts: [SoundSystem.stereo, SoundSystem.surround5_1]),
      ];
      final updated = mixesWithMeasuredLoudness(mixes, [
        _result(1, SoundSystem.surround5_1, lufs: -18),
      ]);

      final layouts = updated.single.subMixes.single.layouts;
      // Unmeasured layout untouched (default zeros).
      expect(layouts[0].loudness.integratedLoudness, 0);
      expect(layouts[1].loudness.integratedLoudness, -18);
      expect(layouts[1].loudness.truePeak, -1.0);
      expect(layouts[1].loudness.digitalPeak, -2.0);
    });

    test('never applies monitoring-only results', () {
      final mixes = [
        _mix(1, layouts: [SoundSystem.stereo]),
      ];
      final updated = mixesWithMeasuredLoudness(mixes, [
        _result(1, SoundSystem.stereo, tagged: false, lufs: -14),
      ]);
      expect(
        updated
            .single
            .subMixes
            .single
            .layouts
            .single
            .loudness
            .integratedLoudness,
        0,
      );
    });

    test('matches by mix id, not list position', () {
      final mixes = [
        _mix(7, layouts: [SoundSystem.stereo]),
        _mix(3, layouts: [SoundSystem.stereo]),
      ];
      final updated = mixesWithMeasuredLoudness(mixes, [
        _result(3, SoundSystem.stereo, lufs: -20),
      ]);
      expect(
        updated[0].subMixes.single.layouts.single.loudness.integratedLoudness,
        0,
      );
      expect(
        updated[1].subMixes.single.layouts.single.loudness.integratedLoudness,
        -20,
      );
    });
  });

  group('loudnessFingerprint', () {
    final baseElements = [_element(1), _element(2, wavPath: '/tmp/b.wav')];
    final baseMixes = [
      _mix(1, settings: const [MixElementSettings(elementId: 1, mixGain: -3)]),
    ];

    String fp({
      List<AudioElement>? elements,
      List<Mix>? mixes,
      int sampleRate = 48000,
    }) {
      return loudnessFingerprint(
        elements: elements ?? baseElements,
        mixes: mixes ?? baseMixes,
        sampleRate: sampleRate,
      );
    }

    test('is stable for identical inputs', () {
      expect(fp(), fp());
    });

    test('ignores element list order', () {
      expect(fp(elements: baseElements.reversed.toList()), fp());
    });

    test('changes when measurement inputs change', () {
      // Element-side inputs (bounce).
      expect(
        fp(elements: [_element(1, gain: -6), baseElements[1]]),
        isNot(fp()),
      );
      expect(
        fp(
          elements: [
            _element(1, routing: const [1, 0]),
            baseElements[1],
          ],
        ),
        isNot(fp()),
      );
      expect(
        fp(
          elements: [
            _element(1, wavPath: '/tmp/c.wav'),
            baseElements[1],
          ],
        ),
        isNot(fp()),
      );
      // Mix-side inputs (measure).
      expect(fp(mixes: [_mix(1, outputGain: -2)]), isNot(fp()));
      expect(
        fp(
          mixes: [
            _mix(
              1,
              settings: const [MixElementSettings(elementId: 1, mixGain: -4)],
            ),
          ],
        ),
        isNot(fp()),
      );
      expect(
        fp(
          mixes: [
            _mix(1, layouts: [SoundSystem.surround5_1]),
          ],
        ),
        isNot(fp()),
      );
      expect(fp(sampleRate: 44100), isNot(fp()));
    });

    test('ignores excluded elements settings and mute/solo', () {
      final withExcluded = [
        _mix(
          1,
          settings: const [
            MixElementSettings(elementId: 1, mixGain: -3),
            MixElementSettings(elementId: 2, included: false, mixGain: -12),
          ],
        ),
      ];
      final withExcludedChanged = [
        _mix(
          1,
          settings: const [
            MixElementSettings(elementId: 1, mixGain: -3),
            MixElementSettings(elementId: 2, included: false, mixGain: -20),
          ],
        ),
      ];
      expect(fp(mixes: withExcluded), fp(mixes: withExcludedChanged));

      final muted = [
        baseElements[0].copyWith(mute: true, solo: true),
        baseElements[1],
      ];
      expect(fp(elements: muted), fp());
    });
  });
}
