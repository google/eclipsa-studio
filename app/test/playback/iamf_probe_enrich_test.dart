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

// Hermetic tests for enrichReportWithFullProbe: merging the full
// descriptor probe (every sub-mix) into the thin C-struct probe report
// (first sub-mix only). No dylib / FFI — the full probe side is fed
// through parseProbeJson, pinning the same producer contract the
// Inspector tests use.

import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/playback/iamf_probe_full.dart'
    show IamfFullProbe, parseProbeJson;
import 'package:flutter_test/flutter_test.dart';

// Two presentations. ES-10 has two sub-mixes: sub-mix 0 with AEs {1, 2}
// (gains -3 dB / +1.5 dB, element 2's gain time-varying via mode 0),
// sub-mix 1 with AE {3} and output gain -6 dB. ES-11 has one sub-mix
// with AE {1} only.
const String _fullJson =
    '{"ok":true,"report":{"primary_profile":"base","additional_profile":'
    '"base","descriptor_bytes_consumed":512,"codec_configs":[],'
    '"audio_elements":[],"mix_presentations":['
    '{"id":10,"count_label":1,"num_sub_mixes":2,'
    '"annotations":[{"language":"en-us","label":"Main"}],"sub_mixes":['
    '{"audio_elements":['
    '{"audio_element_id":1,"localized_element_annotations":["beds"],'
    '"rendering_config":{"headphones_rendering_mode":"stereo",'
    '"binaural_filter_profile":"ambient"},"element_mix_gain":'
    '{"param_definition":{"parameter_id":101,"parameter_rate":48000,'
    '"param_definition_mode":1,"duration":0,'
    '"constant_subblock_duration":0},"default_mix_gain":-3,'
    '"default_mix_gain_q7_8":-768}},'
    '{"audio_element_id":2,"localized_element_annotations":["fx"],'
    '"rendering_config":{"headphones_rendering_mode":'
    '"binaural_world_locked","binaural_filter_profile":"ambient"},'
    '"element_mix_gain":{"param_definition":{"parameter_id":102,'
    '"parameter_rate":48000,"param_definition_mode":0,"duration":48000,'
    '"constant_subblock_duration":48000},"default_mix_gain":1.5,'
    '"default_mix_gain_q7_8":384}}],'
    '"output_mix_gain":{"param_definition":{"parameter_id":100,'
    '"parameter_rate":48000,"param_definition_mode":1,"duration":0,'
    '"constant_subblock_duration":0},"default_mix_gain":0,'
    '"default_mix_gain_q7_8":0},'
    '"layouts":[{"loudness_layout":{"layout_type":'
    '"loudspeakers_ss_convention","sound_system":"Stereo"},'
    '"loudness":{"info_type":0,"true_peak_present":true,'
    '"anchored_loudness_present":false,"has_layout_extension":false,'
    '"integrated_loudness":-16.2,"digital_peak":-1.1,'
    '"true_peak":-0.9}}]},'
    '{"audio_elements":['
    '{"audio_element_id":3,"localized_element_annotations":["alt"],'
    '"rendering_config":{"headphones_rendering_mode":"stereo",'
    '"binaural_filter_profile":""},"element_mix_gain":'
    '{"param_definition":{"parameter_id":103,"parameter_rate":48000,'
    '"param_definition_mode":1,"duration":0,'
    '"constant_subblock_duration":0},"default_mix_gain":0,'
    '"default_mix_gain_q7_8":0}}],'
    '"output_mix_gain":{"param_definition":{"parameter_id":104,'
    '"parameter_rate":48000,"param_definition_mode":1,"duration":0,'
    '"constant_subblock_duration":0},"default_mix_gain":-6,'
    '"default_mix_gain_q7_8":-1536},"layouts":[]}],'
    '"tags":[]},'
    '{"id":11,"count_label":1,"num_sub_mixes":1,'
    '"annotations":[{"language":"en-us","label":"Dialog Only"}],'
    '"sub_mixes":[{"audio_elements":['
    '{"audio_element_id":1,"localized_element_annotations":["beds"],'
    '"rendering_config":{"headphones_rendering_mode":"stereo",'
    '"binaural_filter_profile":"ambient"},"element_mix_gain":'
    '{"param_definition":{"parameter_id":105,"parameter_rate":48000,'
    '"param_definition_mode":1,"duration":0,'
    '"constant_subblock_duration":0},"default_mix_gain":-1.25,'
    '"default_mix_gain_q7_8":-320}}],'
    '"output_mix_gain":{"param_definition":{"parameter_id":106,'
    '"parameter_rate":48000,"param_definition_mode":1,"duration":0,'
    '"constant_subblock_duration":0},"default_mix_gain":0,'
    '"default_mix_gain_q7_8":0},"layouts":[]}],"tags":[]}]}}';

/// Thin report the C-struct probe would produce for the same file
/// (first sub-mix only).
IamfProbeReport _thinReport() => IamfProbeReport(
  ok: true,
  errorMessage: null,
  sampleRate: 48000,
  totalSamples: 480000,
  audioElements: const [
    IamfAe(
      id: 1,
      type: IamfAeType.channelBased,
      layoutLabel: 'Stereo',
      ambisonicsOrder: -1,
      numChannels: 2,
    ),
  ],
  mixPresentations: const [
    IamfMixPresentation(
      id: 10,
      name: 'Main',
      language: 'en-us',
      loudnessLufs: -16.2,
      truePeakDbtp: -0.9,
      elements: [
        IamfMixElementGain(audioElementId: 1, defaultGainDb: -3),
        IamfMixElementGain(audioElementId: 2, defaultGainDb: 1.5),
      ],
      layoutType: 'loudspeakers_ss_convention',
      soundSystem: 'Stereo',
    ),
    IamfMixPresentation(
      id: 11,
      name: 'Dialog Only',
      language: 'en-us',
      loudnessLufs: null,
      truePeakDbtp: null,
      elements: [IamfMixElementGain(audioElementId: 1, defaultGainDb: -1.25)],
      layoutType: null,
      soundSystem: null,
    ),
  ],
);

void main() {
  group('enrichReportWithFullProbe', () {
    final full = parseProbeJson(_fullJson);
    final report = enrichReportWithFullProbe(_thinReport(), full);

    test('fixture parses', () {
      expect(full.ok, isTrue);
      expect(full.mixPresentations, hasLength(2));
    });

    test('carries every sub-mix with element sets and gains', () {
      final mp = report.mixPresentations[0];
      expect(mp.subMixes, hasLength(2));

      final sm0 = mp.subMixes[0];
      expect(sm0.elements.map((e) => e.audioElementId), [1, 2]);
      expect(sm0.elements[0].defaultGainDb, -3);
      expect(sm0.elements[1].defaultGainDb, 1.5);
      expect(sm0.outputMixGainDb, 0);

      final sm1 = mp.subMixes[1];
      expect(sm1.elements.map((e) => e.audioElementId), [3]);
      expect(sm1.outputMixGainDb, -6);
    });

    test('exposes param modes and rendering configs', () {
      final sm0 = report.mixPresentations[0].subMixes[0];
      expect(sm0.elements[0].paramDefinitionMode, 1);
      expect(sm0.elements[1].paramDefinitionMode, 0); // time-varying
      expect(sm0.elements[1].headphonesRenderingMode, 'binaural_world_locked');
      expect(sm0.elements[0].binauralFilterProfile, 'ambient');
      // Empty rendering-config strings become null.
      final sm1 = report.mixPresentations[0].subMixes[1];
      expect(sm1.elements[0].binauralFilterProfile, isNull);
      expect(sm0.outputGainParamDefinitionMode, 1);
    });

    test('carries layouts with loudness', () {
      final layouts = report.mixPresentations[0].subMixes[0].layouts;
      expect(layouts, hasLength(1));
      expect(layouts[0].layoutType, 'loudspeakers_ss_convention');
      expect(layouts[0].soundSystem, 'Stereo');
      expect(layouts[0].integratedLoudnessLufs, -16.2);
      expect(layouts[0].truePeakDbtp, -0.9);
    });

    test('upgrades the first-sub-mix convenience list in place', () {
      final mp = report.mixPresentations[0];
      expect(mp.elements, same(mp.subMixes.first.elements));
      expect(mp.elements[1].paramDefinitionMode, 0);
    });

    test('preserves thin-report identity fields', () {
      expect(report.sampleRate, 48000);
      expect(report.totalSamples, 480000);
      expect(report.audioElements, hasLength(1));
      final mp = report.mixPresentations[1];
      expect(mp.name, 'Dialog Only');
      expect(mp.subMixes, hasLength(1));
      expect(mp.subMixes[0].elements[0].defaultGainDb, -1.25);
    });

    test('synthesizes a sub-mix when the full probe failed', () {
      final degraded = enrichReportWithFullProbe(
        _thinReport(),
        IamfFullProbe.error('boom'),
      );
      final mp = degraded.mixPresentations[0];
      expect(mp.subMixes, hasLength(1));
      expect(mp.subMixes[0].elements.map((e) => e.audioElementId), [1, 2]);
      expect(mp.subMixes[0].elements[0].defaultGainDb, -3);
      expect(mp.subMixes[0].outputMixGainDb, 0);
      expect(mp.subMixes[0].layouts.single.soundSystem, 'Stereo');
      // No layout info on presentation 11 → no synthesized layout.
      expect(degraded.mixPresentations[1].subMixes[0].layouts, isEmpty);
    });

    test('synthesizes when a presentation id has no full-probe match', () {
      final mismatched = parseProbeJson(
        _fullJson.replaceAll('"id":10', '"id":99'),
      );
      final r = enrichReportWithFullProbe(_thinReport(), mismatched);
      expect(r.mixPresentations[0].subMixes, hasLength(1));
      expect(
        r.mixPresentations[0].subMixes[0].elements.map((e) => e.audioElementId),
        [1, 2],
      );
      // Presentation 11 still matches and gets the real sub-mix data.
      expect(
        r.mixPresentations[1].subMixes[0].elements[0].defaultGainDb,
        -1.25,
      );
    });

    test('error reports pass through untouched', () {
      const err = IamfProbeReport.error('probe failed');
      final r = enrichReportWithFullProbe(err, full);
      expect(r.ok, isFalse);
      expect(r.errorMessage, 'probe failed');
    });
  });
}
