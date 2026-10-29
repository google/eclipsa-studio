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

import 'dart:io';

import 'package:eclipsa_studio/export/iamf_export_config.dart';
import 'package:eclipsa_studio/export/user_metadata_builder.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart'
    show BinauralProfile;
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden contract tests for the textproto builder.
///
/// The goldens under `engine/test/fixtures/golden/` are the app half of
/// the export contract with iamf-tools: the engine's encode round-trip
/// tests (`engine/test/cli_commands_test.cc`, run by `bazel test //...`)
/// feed these exact files through the real encoder and probe the result.
/// This test pins the goldens to what the builder actually emits, so
/// the checked-in files can't silently drift from the app.
///
/// When a builder change legitimately alters the output, regenerate:
///
///   flutter test test/export/user_metadata_golden_test.dart \
///       --dart-define=updateGoldens=true
///
/// then re-run the engine tests — a golden change means the encoder
/// contract changed and the round trip must be re-proven. If the engine
/// round-trip test asserts values baked into these configs (gains,
/// positions, profile names), keep them in sync.
const bool _updateGoldens = bool.fromEnvironment('updateGoldens');

/// Resolved relative to the test cwd, which `flutter test` pins to the
/// package root (`app/`).
const String _goldenDir = '../engine/test/fixtures/golden';

/// Object session: mono + dual object with non-origin positions and a
/// non-default binaural filter profile — the ES-283 contract
/// (POLAR / DUAL_POLAR param definitions, binaural_filter_profile,
/// single-substream objects). Values are asserted byte-for-byte by the
/// engine round-trip test.
IamfExportConfig _objectsBinauralConfig() {
  return IamfExportConfig(
    profile: IamfProfile.baseAdvanced,
    sampleRate: 48000,
    elements: [
      AudioElement(
        id: 1,
        name: 'MonoObj',
        type: 'Object',
        layout: 'Mono',
        codec: 'LPCM',
        color: 0xFF000000,
        wavPath: '/wavs/obj_mono.wav',
        azimuth: 30,
        elevation: 10,
        distance: 0.5,
      ),
      AudioElement(
        id: 2,
        name: 'DualObj',
        type: 'Object',
        layout: 'Stereo',
        codec: 'LPCM',
        color: 0xFF000000,
        wavPath: '/wavs/obj_dual.wav',
        isDual: true,
        azimuth: 10,
        elevation: -5,
        distance: 1.0,
        spread: 60,
      ),
    ],
    mixes: [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            elementSettings: [
              MixElementSettings(
                elementId: 1,
                binauralProfile: BinauralProfile.direct,
              ),
              MixElementSettings(elementId: 2),
            ],
            layouts: const [
              MixLayout(
                soundSystem: SoundSystem.stereo,
                loudness: LoudnessInfo(
                  integratedLoudness: -18.0,
                  digitalPeak: -2.0,
                  truePeak: -1.0,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    wavBasenames: const {1: 'obj_mono.wav', 2: 'obj_dual.wav'},
    outputPath: '/tmp/objects_binaural.iamf',
  );
}

/// Multi-presentation session: two mixes over the same two beds with
/// different element subsets and distinct element/output mix gains —
/// the export leg of ES-285. Gains are asserted as Q7.8 by the engine
/// round-trip test (-3 dB -> -768, +2 dB -> 512, -1.5 dB -> -384).
IamfExportConfig _multiMixConfig() {
  return IamfExportConfig(
    profile: IamfProfile.baseEnhanced,
    sampleRate: 48000,
    elements: [
      AudioElement(
        id: 1,
        name: 'Bed',
        type: 'Channel',
        layout: 'Stereo',
        codec: 'LPCM',
        color: 0xFF000000,
        wavPath: '/wavs/bed.wav',
      ),
      AudioElement(
        id: 2,
        name: 'Vocal',
        type: 'Channel',
        layout: 'Stereo',
        codec: 'LPCM',
        color: 0xFF000000,
        wavPath: '/wavs/vocal.wav',
      ),
    ],
    mixes: [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            outputMixGain: -1.5,
            elementSettings: [
              MixElementSettings(elementId: 1, mixGain: -3.0),
              MixElementSettings(elementId: 2),
            ],
            layouts: const [
              MixLayout(
                soundSystem: SoundSystem.stereo,
                loudness: LoudnessInfo(
                  integratedLoudness: -18.0,
                  digitalPeak: -2.0,
                  truePeak: -1.0,
                ),
              ),
            ],
          ),
        ],
      ),
      Mix(
        id: 2,
        name: 'Vocal Only',
        subMixes: [
          SubMix(
            elementSettings: [
              MixElementSettings(elementId: 1, included: false),
              MixElementSettings(elementId: 2, mixGain: 2.0),
            ],
            layouts: const [
              MixLayout(
                soundSystem: SoundSystem.stereo,
                loudness: LoudnessInfo(
                  integratedLoudness: -16.0,
                  digitalPeak: -3.0,
                  truePeak: -2.0,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    wavBasenames: const {1: 'bed.wav', 2: 'vocal.wav'},
    outputPath: '/tmp/multi_mix.iamf',
  );
}

/// The multi-mix session re-encoded as Opus — pins the Opus codec
/// config contract (ES-382): 960-sample frames, one shared codec config,
/// the per-channel bitrate in opus_encoder_metadata, and the two
/// includes_* trim fields set to false. The engine encode round-trip
/// test feeds this through the real Opus encoder.
IamfExportConfig _multiMixOpusConfig() {
  final base = _multiMixConfig();
  return IamfExportConfig(
    profile: base.profile,
    sampleRate: base.sampleRate,
    codec: IamfCodec.opus,
    framesPerCodedBlock: kOpusFramesPerCodedBlock,
    elements: base.elements,
    mixes: base.mixes,
    wavBasenames: base.wavBasenames,
    outputPath: '/tmp/multi_mix_opus.iamf',
  );
}

/// Multichannel session for the loudness agreement test's ES-514 cell:
/// a single 7.1.4 bed whose mix declares loudness on BOTH a stereo and
/// a 7.1.4 layout — the shapes where the OAR and iamf-tools renderers
/// can genuinely diverge (downmix, per-layout BS.1770 weights, channel
/// ordering). The engine test asserts the gains baked in here
/// (-2 dB element -> -512, -1 dB output -> -256).
IamfExportConfig _bed714Config() {
  return IamfExportConfig(
    profile: IamfProfile.baseEnhanced,
    sampleRate: 48000,
    elements: [
      AudioElement(
        id: 1,
        name: 'Bed',
        type: 'Channel',
        layout: '7.1.4',
        codec: 'LPCM',
        color: 0xFF000000,
        wavPath: '/wavs/bed714.wav',
      ),
    ],
    mixes: [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            outputMixGain: -1.0,
            elementSettings: [MixElementSettings(elementId: 1, mixGain: -2.0)],
            layouts: const [
              MixLayout(
                soundSystem: SoundSystem.stereo,
                loudness: LoudnessInfo(
                  integratedLoudness: -18.0,
                  digitalPeak: -2.0,
                  truePeak: -1.0,
                ),
              ),
              MixLayout(
                soundSystem: SoundSystem.surround7_1_4,
                loudness: LoudnessInfo(
                  integratedLoudness: -18.0,
                  digitalPeak: -2.0,
                  truePeak: -1.0,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    wavBasenames: const {1: 'bed714.wav'},
    outputPath: '/tmp/bed714.iamf',
  );
}

/// 9.1.6 bed (ES-940, ES-960): one "9.1.6" element, a WAV in the app's
/// order (OBR's alt order), declared on a Stereo loudness layout. The
/// engine's CliEncode.Golden916AltRoundTrip encodes it and checks that
/// WAV channel 0 decodes as FLc, so the channel labels here are listed
/// per WAV index in the alt order.
IamfExportConfig _bed916Config() {
  return IamfExportConfig(
    profile: IamfProfile.baseEnhanced,
    sampleRate: 48000,
    elements: [
      AudioElement(
        id: 1,
        name: 'Bed',
        type: 'Channel',
        layout: '9.1.6',
        codec: 'LPCM',
        color: 0xFF000000,
        wavPath: '/wavs/bed916.wav',
      ),
    ],
    mixes: [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            outputMixGain: 0.0,
            elementSettings: [MixElementSettings(elementId: 1, mixGain: 0.0)],
            layouts: const [
              MixLayout(
                soundSystem: SoundSystem.stereo,
                loudness: LoudnessInfo(
                  integratedLoudness: -18.0,
                  digitalPeak: -2.0,
                  truePeak: -1.0,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    wavBasenames: const {1: 'bed916.wav'},
    outputPath: '/tmp/bed916.iamf',
  );
}

/// Third-order ambisonics scene (ES-940): one "3OA" element, 16 channels
/// in ACN order, declared on a Stereo loudness layout. The builder writes
/// an ambisonics_mono_config with one substream per channel, an identity
/// channel_mapping and the labels A_0 to A_15. The engine's
/// CliEncode.GoldenScene3oaRoundTrip encodes it, checks the probed
/// mapping, and checks that each of the 16 WAV channels decodes on the
/// same ACN channel.
IamfExportConfig _scene3oaConfig() {
  return IamfExportConfig(
    profile: IamfProfile.baseEnhanced,
    sampleRate: 48000,
    elements: [
      AudioElement(
        id: 1,
        name: 'Scene',
        type: 'Scene',
        layout: '3OA',
        codec: 'LPCM',
        color: 0xFF000000,
        ambisonicsOrder: 3,
        wavPath: '/wavs/scene3oa.wav',
      ),
    ],
    mixes: [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            outputMixGain: 0.0,
            elementSettings: [MixElementSettings(elementId: 1, mixGain: 0.0)],
            layouts: const [
              MixLayout(
                soundSystem: SoundSystem.stereo,
                loudness: LoudnessInfo(
                  integratedLoudness: -18.0,
                  digitalPeak: -2.0,
                  truePeak: -1.0,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
    wavBasenames: const {1: 'scene3oa.wav'},
    outputPath: '/tmp/scene3oa.iamf',
  );
}

void _checkGolden(String name, IamfExportConfig config) {
  final file = File('$_goldenDir/$name');
  final built = buildUserMetadataTextproto(config);
  if (_updateGoldens) {
    file.writeAsStringSync(built);
    return;
  }
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '$name missing — regenerate with '
        '--dart-define=updateGoldens=true',
  );
  expect(
    built,
    file.readAsStringSync(),
    reason:
        'builder output diverged from $name — if the change is '
        'intentional, regenerate with --dart-define=updateGoldens=true '
        'and re-run the engine round-trip tests (bazel test //...)',
  );
}

void main() {
  test('objects_binaural golden matches builder output', () {
    _checkGolden('objects_binaural.textproto', _objectsBinauralConfig());
  });

  test('multi_mix golden matches builder output', () {
    _checkGolden('multi_mix.textproto', _multiMixConfig());
  });

  test('multi_mix_opus golden matches builder output', () {
    _checkGolden('multi_mix_opus.textproto', _multiMixOpusConfig());
  });

  test('bed916 golden matches builder output', () {
    _checkGolden('bed916.textproto', _bed916Config());
  });

  test('scene3oa golden matches builder output', () {
    _checkGolden('scene3oa.textproto', _scene3oaConfig());
  });

  test('bed714 golden matches builder output', () {
    _checkGolden('bed714.textproto', _bed714Config());
  });
}
