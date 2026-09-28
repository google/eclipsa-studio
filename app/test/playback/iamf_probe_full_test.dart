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

// Hermetic tests for the Inspector's full-probe JSON parser. They feed
// JSON through `parseProbeJson` directly (no dylib / FFI), so they pin the
// parser to the shape `iamf_tools::ProbeReportToJson` actually emits.
//
// The FLAC payload is the verbatim output of
//   eclipsa_studio_cli probe noise_1024samp_stereo_flac.iamf --json
// (engine/test/fixtures/noise_1024samp_stereo_flac.iamf), so this guards
// the real producer→consumer contract, not a hand-massaged stand-in.

import 'package:eclipsa_studio/playback/iamf_probe_full.dart';
import 'package:flutter_test/flutter_test.dart';

// Verbatim `probe --json` output for the vendored stereo FLAC fixture.
const String _flacProbeJson =
    '{"ok":true,"report":{"primary_profile":'
    '"simple","primary_profile_raw":0,"additional_profile":"simple",'
    '"additional_profile_raw":0,"descriptor_bytes_consumed":137,'
    '"descriptor_total_samples":1024,"descriptor_duration_seconds":'
    '0.0213333,"codec_configs":[{"id":0,"codec_id":"FLAC","codec_id_raw":'
    '1716281667,"num_samples_per_frame":4608,"audio_roll_distance":0,'
    '"output_sample_rate":48000,"input_sample_rate":48000,"bit_depth":16,'
    '"flac":{"metadata_blocks":[{"block_type":"StreamInfo","block_type_raw":'
    '0,"minimum_block_size":4608,"maximum_block_size":4608,'
    '"minimum_frame_size":4153,"maximum_frame_size":4153,"sample_rate":48000,'
    '"number_of_channels":1,"bits_per_sample":15,"total_samples_in_stream":'
    '1024}]}}],"audio_elements":[{"id":1,"type":"channel_based","type_raw":0,'
    '"reserved":0,"codec_config_id":0,"num_substreams":1,"substream_ids":[0],'
    '"params":[],"scalable_layers":[{"loudspeaker_layout":"Stereo",'
    '"loudspeaker_layout_raw":1,"substream_count":1,"coupled_substream_count":'
    '1,"output_gain_is_present_flag":false,"recon_gain_is_present_flag":false,'
    '"output_gain_flag":0,"output_gain":0,"output_gain_q7_8":0}],'
    '"channel_layout":"Stereo","channel_layout_raw":1,"num_channels":2}],'
    '"mix_presentations":[{"id":3,"count_label":1,"num_sub_mixes":1,'
    '"annotations":[{"language":"en-us","label":"default_mix_presentation"}],'
    '"sub_mixes":[{"audio_elements":[{"audio_element_id":1,'
    '"localized_element_annotations":["stereo"],"rendering_config":'
    '{"headphones_rendering_mode":"binaural_world_locked",'
    '"headphones_rendering_mode_raw":1,"binaural_filter_profile":"ambient",'
    '"binaural_filter_profile_raw":0},"element_mix_gain":{"param_definition":'
    '{"parameter_id":101,"parameter_rate":48000,"param_definition_mode":1,'
    '"duration":0,"constant_subblock_duration":0},"default_mix_gain":0,'
    '"default_mix_gain_q7_8":0}}],"output_mix_gain":{"param_definition":'
    '{"parameter_id":100,"parameter_rate":48000,"param_definition_mode":1,'
    '"duration":0,"constant_subblock_duration":0},"default_mix_gain":0,'
    '"default_mix_gain_q7_8":0},"layouts":[{"loudness_layout":{"layout_type":'
    '"loudspeakers_ss_convention","layout_type_raw":2,"sound_system":"Stereo",'
    '"sound_system_raw":0},"loudness":{"info_type":0,"true_peak_present":false,'
    '"anchored_loudness_present":false,"has_layout_extension":false,'
    '"integrated_loudness":0,"digital_peak":0}}]}],"tags":[],"layouts":'
    '["Stereo"],"integrated_loudness_lkfs":0,"digital_peak_dbfs":0}]}}';

void main() {
  group('parseProbeJson — FLAC fixture', () {
    final probe = parseProbeJson(_flacProbeJson);

    test('parses the envelope and codec config', () {
      expect(probe.ok, isTrue);
      expect(probe.primaryProfile, 'simple');
      expect(probe.codecConfigs, hasLength(1));
      expect(probe.codecConfigs.single.codecId, 'FLAC');
      // The key was renamed bit_depth_to_measure_loudness -> bit_depth
      // upstream; reading the new key must yield 16, not the 0 fallback.
      expect(probe.codecConfigs.single.bitDepthToMeasureLoudness, 16);
    });

    test('derives StreamInfo from block_type_raw == 0', () {
      final flac = probe.codecConfigs.single.flac;
      expect(flac, isNotNull);
      // Upstream emits no is_stream_info flag; the parser must still find
      // the STREAMINFO block. This is the path the Inspector's _FlacBlock
      // renders, and was previously fixture-untested.
      final info = flac!.streamInfo;
      expect(info, isNotNull);
      expect(info!.isStreamInfo, isTrue);
      expect(info.totalSamplesInStream, 1024);
      expect(info.sampleRate, 48000);
      expect(info.numberOfChannels, 1);
      expect(info.bitsPerSample, 15);
      // The STREAMINFO block must not also show up as an "other" block.
      expect(flac.metadataBlocks.where((b) => !b.isStreamInfo), isEmpty);
    });

    test('parses the channel-based audio element', () {
      expect(probe.audioElements, hasLength(1));
      final ae = probe.audioElements.single;
      expect(ae.type, 'channel_based');
      expect(ae.channelLayout, 'Stereo');
      expect(ae.scalableLayers.single.loudspeakerLayout, 'Stereo');
    });
  });

  group('parseProbeJson — shape regressions', () {
    test('output_gain reads the raw Q7.8 sibling, not the dB float', () {
      // Upstream split output_gain into a decoded-dB float plus an
      // *_q7_8 raw int. The UI divides by 256, so the parser must take
      // the raw sibling — here 640 (= 2.5 dB), distinct from the float.
      const json =
          '{"ok":true,"report":{"codec_configs":[{"id":0,'
          '"codec_id":"Opus","opus":{"output_gain":2.5,'
          '"output_gain_q7_8":640,"output_channel_count":2}}],'
          '"audio_elements":[{"id":1,"type":"channel_based",'
          '"scalable_layers":[{"loudspeaker_layout":"Stereo",'
          '"output_gain":3.5,"output_gain_q7_8":896}]}],'
          '"mix_presentations":[]}}';
      final probe = parseProbeJson(json);
      expect(probe.codecConfigs.single.opus!.outputGain, 640);
      expect(probe.audioElements.single.scalableLayers.single.outputGain, 896);
    });

    test('surfaces the error envelope', () {
      final probe = parseProbeJson('{"ok":false,"error":"boom"}');
      expect(probe.ok, isFalse);
      expect(probe.errorMessage, 'boom');
    });
  });
}
