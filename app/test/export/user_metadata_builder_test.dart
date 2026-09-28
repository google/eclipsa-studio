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

import 'package:eclipsa_studio/export/iamf_export_config.dart';
import 'package:eclipsa_studio/export/iamf_fixed_point.dart';
import 'package:eclipsa_studio/export/user_metadata_builder.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart'
    show BinauralProfile;
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixture helpers — kept close to the validator tests so both files
// read the same way.

AudioElement _channel({
  int id = 1,
  String name = 'Bed',
  String layout = 'Stereo',
  String codec = 'LPCM',
  String wavPath = '/tmp/bed.wav',
  double gain = 0,
}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Channel',
    layout: layout,
    codec: codec,
    color: 0xFF000000,
    gain: gain,
    wavPath: wavPath,
  );
}

AudioElement _scene({
  int id = 10,
  int order = 3,
  String wavPath = '/tmp/scene.wav',
}) {
  return AudioElement(
    id: id,
    name: 'Scene',
    type: 'Scene',
    layout: '${order}OA',
    codec: 'LPCM',
    color: 0xFF000000,
    ambisonicsOrder: order,
    wavPath: wavPath,
  );
}

AudioElement _object({
  int id = 20,
  String name = 'Obj',
  bool isDual = false,
  double az = 0,
  double el = 0,
  double distance = 1.0,
  double spread = 60,
  String wavPath = '/tmp/obj.wav',
}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Object',
    layout: isDual ? 'Stereo' : 'Mono',
    codec: 'LPCM',
    color: 0xFF000000,
    wavPath: wavPath,
    isDual: isDual,
    azimuth: az,
    elevation: el,
    distance: distance,
    spread: spread,
  );
}

IamfExportConfig _configWith({
  IamfProfile profile = IamfProfile.baseEnhanced,
  required List<AudioElement> elements,
  List<Mix>? mixes,
  Map<int, String>? wavBasenames,
  IamfCodec codec = IamfCodec.lpcm,
}) {
  final wavs =
      wavBasenames ??
      {
        for (final e in elements)
          if (e.wavPath != null) e.id: _basename(e.wavPath!),
      };
  return IamfExportConfig(
    profile: profile,
    sampleRate: 48000,
    codec: codec,
    framesPerCodedBlock: codec == IamfCodec.opus
        ? kOpusFramesPerCodedBlock
        : kDefaultFramesPerCodedBlock,
    elements: elements,
    mixes:
        mixes ??
        [
          Mix(
            id: 1,
            name: 'Main',
            subMixes: [
              SubMix(
                elementSettings: [
                  for (final e in elements) MixElementSettings(elementId: e.id),
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
    wavBasenames: wavs,
    outputPath: '/tmp/session_export.iamf',
  );
}

String _basename(String path) {
  final i = path.lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

void main() {
  group('UserMetadataBuilder — header sections', () {
    test('test_vector_metadata carries file stem and profile', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      expect(out, contains('test_vector_metadata {'));
      expect(out, contains('file_name_prefix: "session_export"'));
      expect(out, contains('primary_profile: PROFILE_VERSION_BASE_ENHANCED'));
    });

    test('ia_sequence_header picks up profile enum', () {
      final out = buildUserMetadataTextproto(
        _configWith(profile: IamfProfile.baseAdvanced, elements: [_channel()]),
      );
      expect(out, contains('ia_sequence_header_metadata {'));
      expect(out, contains('primary_profile: PROFILE_VERSION_BASE_ADVANCED'));
      expect(
        out,
        contains('additional_profile: PROFILE_VERSION_BASE_ADVANCED'),
      );
    });
  });

  group('UserMetadataBuilder — codec configs', () {
    test('LPCM stereo element emits one codec config', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      expect('codec_config_metadata {'.allMatches(out).length, 1);
      expect(out, contains('codec_id: CODEC_ID_LPCM'));
      expect(out, contains('sample_rate: 48000'));
      expect(out, contains('num_samples_per_frame: 1024'));
    });

    test('two elements with same codec share one config', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          elements: [
            _channel(id: 1, layout: 'Stereo'),
            _channel(id: 2, layout: '5.1', wavPath: '/tmp/bed2.wav'),
          ],
        ),
      );
      expect('codec_config_metadata {'.allMatches(out).length, 1);
    });

    test('Opus emits 960-frame config with encoder metadata', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()], codec: IamfCodec.opus),
      );
      expect(out, contains('codec_id: CODEC_ID_OPUS'));
      expect(out, contains('num_samples_per_frame: 960'));
      expect(out, contains('audio_roll_distance: -4'));
      expect(out, contains('decoder_config_opus {'));
      expect(out, contains('input_sample_rate: 48000'));
      expect(out, contains('target_bitrate_per_channel: 64000'));
      expect(out, contains('application: APPLICATION_AUDIO'));
      expect(out, isNot(contains('decoder_config_lpcm')));
    });

    test('Opus dedups mixed-bit-depth sources into one config', () {
      // Source codec strings differ ("WAV 16bit" vs "WAV 24bit") —
      // irrelevant after the transcode, so one shared Opus config.
      final out = buildUserMetadataTextproto(
        _configWith(
          elements: [
            _channel(id: 1, codec: 'WAV 16bit'),
            _channel(id: 2, codec: 'WAV 24bit', wavPath: '/tmp/bed2.wav'),
          ],
          codec: IamfCodec.opus,
        ),
      );
      expect('codec_config_metadata {'.allMatches(out).length, 1);
    });
  });

  group('UserMetadataBuilder — channel-based element', () {
    test('stereo -> LOUDSPEAKER_LAYOUT_STEREO with 1 coupled substream', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel(layout: 'Stereo')]),
      );
      expect(out, contains('audio_element_type: AUDIO_ELEMENT_CHANNEL_BASED'));
      expect(out, contains('loudspeaker_layout: LOUDSPEAKER_LAYOUT_STEREO'));
      expect(out, contains('audio_substream_ids: [0]'));
      expect(out, contains('substream_count: 1'));
      expect(out, contains('coupled_substream_count: 1'));
    });

    test('7.1.4 -> LOUDSPEAKER_LAYOUT_7_1_4_CH with 5 coupled substreams', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel(layout: '7.1.4')]),
      );
      expect(out, contains('loudspeaker_layout: LOUDSPEAKER_LAYOUT_7_1_4_CH'));
      // iamf-tools groups 7.1.4 as 7 substreams with 5 coupled pairs
      // (C and LFE ride as uncoupled mono substreams).
      expect(out, contains('audio_substream_ids: [0, 1, 2, 3, 4, 5, 6]'));
      expect(out, contains('substream_count: 7'));
      expect(out, contains('coupled_substream_count: 5'));
    });

    test('9.1.6 -> EXPANDED + 9_1_6_CH with 9 substreams (7 coupled)', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel(layout: '9.1.6')]),
      );
      expect(out, contains('loudspeaker_layout: LOUDSPEAKER_LAYOUT_EXPANDED'));
      expect(
        out,
        contains(
          'expanded_loudspeaker_layout: '
          'EXPANDED_LOUDSPEAKER_LAYOUT_9_1_6_CH',
        ),
      );
      // 16 channels: 7 coupled stereo pairs + C and LFE as mono = 9 total.
      expect(out, contains('audio_substream_ids: [0, 1, 2, 3, 4, 5, 6, 7, 8]'));
      expect(out, contains('substream_count: 9'));
      expect(out, contains('coupled_substream_count: 7'));
      // All 16 channel labels, in OAR render order (= iamf-tools canonical
      // 9.1.6 order). Pinned exactly so a mid-list transposition is caught.
      const expectedLabels = [
        'FL',
        'FR',
        'FC',
        'LFE',
        'BL',
        'BR',
        'FLC',
        'FRC',
        'SI_L',
        'SI_R',
        'TP_FL',
        'TP_FR',
        'TP_BL',
        'TP_BR',
        'TP_SI_L',
        'TP_SI_R',
      ];
      for (final (i, label) in expectedLabels.indexed) {
        expect(
          out,
          contains('{ channel_id: $i channel_label: CHANNEL_LABEL_$label }'),
        );
      }
    });

    test('unsupported expanded layout (7.1.5.4) throws a clear error', () {
      expect(
        () => buildUserMetadataTextproto(
          _configWith(elements: [_channel(layout: '7.1.5.4')]),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('UserMetadataBuilder — scene-based element', () {
    test('3OA -> AMBISONICS_MODE_MONO with 16 channels', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_scene(order: 3)]),
      );
      expect(out, contains('audio_element_type: AUDIO_ELEMENT_SCENE_BASED'));
      expect(out, contains('ambisonics_mode: AMBISONICS_MODE_MONO'));
      expect(out, contains('output_channel_count: 16'));
      expect(
        out,
        contains(
          'channel_mapping: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, '
          '12, 13, 14, 15]',
        ),
      );
    });

    test('1OA -> 4 channels with identity mapping', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_scene(order: 1)]),
      );
      expect(out, contains('output_channel_count: 4'));
      expect(out, contains('channel_mapping: [0, 1, 2, 3]'));
    });
  });

  group('UserMetadataBuilder — object element', () {
    test('mono object -> OBJECT_BASED with num_objects=1', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [_object(isDual: false)],
        ),
      );
      expect(out, contains('audio_element_type: AUDIO_ELEMENT_OBJECT_BASED'));
      expect(out, contains('objects_config {'));
      expect(out, contains('num_objects: 1'));
    });

    test('dual object -> num_objects=2 with 1 coupled substream', () {
      // iamf-tools rejects object-based elements with more than one
      // substream — a dual object is one coupled stereo substream.
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [_object(isDual: true)],
        ),
      );
      expect(out, contains('num_objects: 2'));
      expect(out, contains('audio_substream_ids: [0]'));
      expect(out, contains('CHANNEL_LABEL_OBJECT_CHANNEL0'));
      expect(out, contains('CHANNEL_LABEL_OBJECT_CHANNEL1'));
    });
  });

  group('UserMetadataBuilder — rendering config', () {
    test('mono object emits POLAR default position', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [_object(az: 30, el: 10, distance: 0.5)],
        ),
      );
      expect(out, contains('rendering_config_param_definitions {'));
      expect(
        out,
        contains('param_definition_type: PARAM_DEFINITION_TYPE_POLAR'),
      );
      expect(out, contains('polar_param_definition {'));
      expect(out, contains('default_azimuth: 30'));
      expect(out, contains('default_elevation: 10'));
      expect(out, contains('default_distance: 64'));
    });

    test('dual object emits DUAL_POLAR with split azimuths', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [_object(isDual: true, az: 10, el: -5, spread: 60)],
        ),
      );
      expect(
        out,
        contains('param_definition_type: PARAM_DEFINITION_TYPE_DUAL_POLAR'),
      );
      expect(out, contains('dual_polar_param_definition {'));
      // First = object channel 0 (L) at center + spread/2 (positive
      // azimuth is left); elevation and distance shared.
      expect(out, contains('default_first_azimuth: 40'));
      expect(out, contains('default_second_azimuth: -20'));
      expect(out, contains('default_first_elevation: -5'));
      expect(out, contains('default_second_elevation: -5'));
      expect(out, contains('default_first_distance: 127'));
      expect(out, contains('default_second_distance: 127'));
    });

    test('non-object elements emit no position param definition', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [
            _channel(),
            _scene(id: 2, wavPath: '/tmp/s.wav'),
          ],
        ),
      );
      expect(out, isNot(contains('rendering_config_param_definitions')));
    });

    test('binaural filter profile emitted on v2.0 profiles', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [_channel()],
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
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      expect(
        out,
        contains('binaural_filter_profile: BINAURAL_FILTER_PROFILE_DIRECT'),
      );
    });

    test('channel-based Binaural element coerces to stereo mode', () {
      // Pre-rendered binaural stereo must export mode 0 (stereo) like
      // live playback's effectiveHeadphonesMode coercion — and the
      // filter profile falls back to ambient, since a stored profile
      // has no meaning when the element is not binauralized.
      final out = buildUserMetadataTextproto(
        _configWith(
          profile: IamfProfile.baseAdvanced,
          elements: [_channel(layout: 'Binaural')],
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
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      expect(
        out,
        contains('headphones_rendering_mode: HEADPHONES_RENDERING_MODE_STEREO'),
      );
      expect(
        out,
        contains('binaural_filter_profile: BINAURAL_FILTER_PROFILE_AMBIENT'),
      );
      expect(out, isNot(contains('BINAURAL_FILTER_PROFILE_DIRECT')));
    });

    test('binaural filter profile omitted on pre-v2.0 profiles', () {
      // Base-Enhanced (v1.1.0) predates the field — the textproto must
      // stay byte-identical to what older exports produced.
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      expect(out, isNot(contains('binaural_filter_profile')));
    });
  });

  group('UserMetadataBuilder — mix presentation', () {
    test('single mix emits one mix_presentation_metadata', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      expect('mix_presentation_metadata {'.allMatches(out).length, 1);
      expect(out, contains('annotations_language: ["en"]'));
      expect(out, contains('localized_presentation_annotations: ["Main"]'));
    });

    test('two mixes -> two mix_presentation_metadata blocks', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          elements: [_channel()],
          mixes: [
            Mix(
              id: 1,
              name: 'Main',
              subMixes: [
                SubMix(elementSettings: [MixElementSettings(elementId: 1)]),
              ],
            ),
            Mix(
              id: 2,
              name: 'Commentary',
              subMixes: [
                SubMix(elementSettings: [MixElementSettings(elementId: 1)]),
              ],
            ),
          ],
        ),
      );
      expect('mix_presentation_metadata {'.allMatches(out).length, 2);
      expect(out, contains('"Main"'));
      expect(out, contains('"Commentary"'));
    });

    test('loudness is emitted in Q7.8 integer units', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      // -18 LUFS * 256 = -4608; -2 dBFS * 256 = -512; -1 dBTP * 256 = -256.
      expect(out, contains('integrated_loudness: -4608'));
      expect(out, contains('digital_peak: -512'));
      expect(out, contains('true_peak: -256'));
      expect(out, contains('LOUDNESS_INFO_TYPE_TRUE_PEAK'));
    });

    test('binaural layout emits LAYOUT_TYPE_BINAURAL', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          elements: [_channel()],
          mixes: [
            Mix(
              id: 1,
              name: 'Main',
              subMixes: [
                SubMix(
                  elementSettings: [MixElementSettings(elementId: 1)],
                  layouts: const [
                    MixLayout(
                      soundSystem: SoundSystem.binaural,
                      loudness: LoudnessInfo(integratedLoudness: -23.0),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      expect(out, contains('layout_type: LAYOUT_TYPE_BINAURAL'));
      expect(out, isNot(contains('sound_system:')));
    });
  });

  group('UserMetadataBuilder — audio frames', () {
    test('emits one audio_frame_metadata per element with WAV basename', () {
      final out = buildUserMetadataTextproto(
        _configWith(
          elements: [
            _channel(id: 1, wavPath: '/Users/me/sessions/mix/bed.wav'),
            _channel(id: 2, wavPath: '/Users/me/sessions/mix/vocal.wav'),
          ],
        ),
      );
      expect('audio_frame_metadata {'.allMatches(out).length, 2);
      expect(out, contains('wav_filename: "bed.wav"'));
      expect(out, contains('wav_filename: "vocal.wav"'));
    });

    test('stereo emits L_2 and R_2 channel labels', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel(layout: 'Stereo')]),
      );
      expect(out, contains('CHANNEL_LABEL_L_2'));
      expect(out, contains('CHANNEL_LABEL_R_2'));
    });

    test('7.1.4 emits all 12 channel labels', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel(layout: '7.1.4')]),
      );
      expect(out, contains('CHANNEL_LABEL_L_7'));
      expect(out, contains('CHANNEL_LABEL_LTB_4'));
    });

    test('ambisonics 1OA emits A_0..A_3 labels', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_scene(order: 1)]),
      );
      expect(out, contains('CHANNEL_LABEL_A_0'));
      expect(out, contains('CHANNEL_LABEL_A_3'));
    });
  });

  group('UserMetadataBuilder — parameter blocks', () {
    test('omits parameter_block_metadata (constant default gain)', () {
      // All parameter definitions use param_definition_mode=1 with a
      // constant default_mix_gain, so iamf-tools uses that default for
      // every frame and no explicit per-frame blocks are needed.
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      expect(out, isNot(contains('parameter_block_metadata {')));
    });

    test('emits temporal_delimiter_metadata', () {
      final out = buildUserMetadataTextproto(
        _configWith(elements: [_channel()]),
      );
      expect(out, contains('temporal_delimiter_metadata'));
      expect(out, contains('enable_temporal_delimiters: false'));
    });
  });

  group('dbToQ7_8', () {
    test('zero dB round-trips to zero', () {
      expect(dbToQ7_8(0), 0);
    });

    test('positive / negative integer dB scale by 256', () {
      expect(dbToQ7_8(-18), -4608);
      expect(dbToQ7_8(6), 1536);
    });

    test('clamps to int16 range', () {
      expect(dbToQ7_8(1000), 32767);
      expect(dbToQ7_8(-1000), -32768);
    });

    test('NaN becomes zero', () {
      expect(dbToQ7_8(double.nan), 0);
    });
  });

  group('angle encoders', () {
    test('encodeAzimuth wraps to (-180, 180]', () {
      expect(encodeAzimuth(0), 0);
      // Boundary maps to +180: OLR's back-center speaker is at exactly
      // +180 (no -180 twin), and OBR normalizes to (-180, 180].
      expect(encodeAzimuth(180), 180);
      expect(encodeAzimuth(-180), 180);
      expect(encodeAzimuth(270), -90);
      expect(encodeAzimuth(-270), 90);
      expect(encodeAzimuth(540), 180);
    });

    test('encodeElevation clamps to [-90, 90]', () {
      expect(encodeElevation(0), 0);
      expect(encodeElevation(45), 45);
      expect(encodeElevation(120), 90);
      expect(encodeElevation(-120), -90);
    });

    test('encodeNormalizedDistance maps [0, 1] to [0, 127]', () {
      expect(encodeNormalizedDistance(0), 0);
      expect(encodeNormalizedDistance(1), 127);
      expect(encodeNormalizedDistance(0.5), 64);
      expect(encodeNormalizedDistance(2), 127);
      expect(encodeNormalizedDistance(-1), 0);
    });

    test('splitDualAzimuth splits around center (first = left)', () {
      // First = object channel 0 (L); positive azimuth is left.
      final r = splitDualAzimuth(centerAzimuth: 0, spread: 60);
      expect(r.firstAzimuth, 30);
      expect(r.secondAzimuth, -30);
    });

    test('splitDualAzimuth wraps past 180', () {
      final r = splitDualAzimuth(centerAzimuth: 170, spread: 60);
      expect(r.firstAzimuth, -160);
      expect(r.secondAzimuth, 140);
    });
  });
}
