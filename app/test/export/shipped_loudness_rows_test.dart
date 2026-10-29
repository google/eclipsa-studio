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

import 'package:eclipsa_studio/export/iamf_export_dialog.dart';
import 'package:eclipsa_studio/playback/iamf_probe_full.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

// ES-492: shippedLoudnessRows pairs the measured per-layout loudness (the
// export config's mixes, exactly what was stamped into the encoder
// metadata) with the loudness_info read back from the artifact. The
// pairing is positional — the builder and the file share write order.

IamfLoudness _shipped(double lufs, {double? truePeak}) => IamfLoudness(
  infoType: truePeak != null ? 1 : 0,
  truePeakPresent: truePeak != null,
  hasLayoutExtension: false,
  integratedLoudness: lufs,
  digitalPeak: -3.0,
  truePeak: truePeak,
);

IamfMixPresentation _mp(List<List<IamfLoudness>> subMixLayouts) =>
    IamfMixPresentation(
      id: 400,
      countLabel: 1,
      numSubMixes: subMixLayouts.length,
      annotations: const [],
      tags: const [],
      subMixes: [
        for (final layouts in subMixLayouts)
          IamfSubMix(
            audioElements: const [],
            outputMixGain: const IamfMixGain(
              paramDefinition: IamfParamDefinition(
                parameterId: 0,
                parameterRate: 48000,
                paramDefinitionMode: 1,
                duration: 0,
                constantSubblockDuration: 0,
              ),
              defaultMixGain: 0,
            ),
            layouts: [
              for (final l in layouts)
                IamfMixPresentationLayout(
                  layoutType: 'LOUDSPEAKERS_SS_CONVENTION',
                  soundSystem: 'A_0_2_0',
                  loudness: l,
                ),
            ],
          ),
      ],
    );

IamfFullProbe _probe(List<IamfMixPresentation> mps) => IamfFullProbe(
  ok: true,
  errorMessage: null,
  primaryProfile: 'base',
  additionalProfile: 'base',
  descriptorBytesConsumed: 0,
  codecConfigs: const [],
  audioElements: const [],
  mixPresentations: mps,
);

Mix _mix(String name, List<MixLayout> layouts) => Mix(
  id: 1,
  name: name,
  subMixes: [SubMix(layouts: layouts)],
);

const _stereoMeasured = MixLayout(
  soundSystem: SoundSystem.stereo,
  loudness: LoudnessInfo(integratedLoudness: -14.2, digitalPeak: -3),
);

void main() {
  test('pairs layouts positionally and computes the delta', () {
    final mixes = [
      _mix('Main', const [
        MixLayout(
          soundSystem: SoundSystem.stereo,
          loudness: LoudnessInfo(integratedLoudness: -14.2, digitalPeak: -3),
        ),
        MixLayout(
          soundSystem: SoundSystem.binaural,
          loudness: LoudnessInfo(integratedLoudness: -15.0, digitalPeak: -3),
        ),
      ]),
    ];
    final probe = _probe([
      _mp([
        [_shipped(-14.0, truePeak: -1.2), _shipped(-15.4)],
      ]),
    ]);

    final rows = shippedLoudnessRows(mixes, probe);
    expect(rows, hasLength(2));
    expect(rows[0].label, 'Main · Stereo');
    expect(rows[0].measuredLufs, -14.2);
    expect(rows[0].measuredDigitalPeakDbfs, -3.0);
    expect(rows[0].measuredTruePeakDbtp, isNull);
    expect(rows[0].shippedLufs, -14.0);
    expect(rows[0].deltaLu, closeTo(0.2, 1e-9));
    expect(rows[0].shippedTruePeakDbtp, -1.2);
    expect(rows[0].shippedDigitalPeakDbfs, -3.0);
    expect(rows[1].label, 'Main · Binaural');
    expect(rows[1].shippedTruePeakDbtp, isNull);
  });

  test('emits rows only where both sides exist', () {
    // Measured has two layouts, the file reports one — no phantom row.
    final mixes = [
      _mix('Main', const [
        MixLayout(
          soundSystem: SoundSystem.stereo,
          loudness: LoudnessInfo(integratedLoudness: -14.2, digitalPeak: -3),
        ),
        MixLayout(
          soundSystem: SoundSystem.surround5_1,
          loudness: LoudnessInfo(integratedLoudness: -13.0, digitalPeak: -3),
        ),
      ]),
      _mix('Alt', const [
        MixLayout(
          soundSystem: SoundSystem.stereo,
          loudness: LoudnessInfo(integratedLoudness: -16.0, digitalPeak: -3),
        ),
      ]),
    ];
    final probe = _probe([
      _mp([
        [_shipped(-14.0)],
      ]),
      // Second mix presentation missing from the probe entirely.
    ]);

    final rows = shippedLoudnessRows(mixes, probe);
    expect(rows, hasLength(1));
    expect(rows[0].label, 'Main · Stereo');
  });

  test('multi-sub-mix mixes qualify the label with the sub-mix name', () {
    final mixes = [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: const [
          SubMix(label: 'Music', layouts: [_stereoMeasured]),
          SubMix(label: 'Commentary', layouts: [_stereoMeasured]),
        ],
      ),
    ];
    final probe = _probe([
      _mp([
        [_shipped(-14.0)],
        [_shipped(-15.0)],
      ]),
    ]);

    final rows = shippedLoudnessRows(mixes, probe);
    expect(rows, hasLength(2));
    expect(rows[0].label, 'Main / Music · Stereo');
    expect(rows[1].label, 'Main / Commentary · Stereo');
    expect(rows[1].shippedLufs, -15.0);
  });

  test('sub-mix truncation emits no phantom rows', () {
    // Measured has two sub-mixes, the file reports one.
    final mixes = [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: const [
          SubMix(label: 'Music', layouts: [_stereoMeasured]),
          SubMix(label: 'Commentary', layouts: [_stereoMeasured]),
        ],
      ),
    ];
    final probe = _probe([
      _mp([
        [_shipped(-14.0)],
      ]),
    ]);

    final rows = shippedLoudnessRows(mixes, probe);
    expect(rows, hasLength(1));
    expect(rows[0].label, 'Main / Music · Stereo');
  });
}
