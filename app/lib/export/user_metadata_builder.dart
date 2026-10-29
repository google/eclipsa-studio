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

import 'package:path/path.dart' as p;

import '../models/audio_element_enums.dart' show BinauralProfile;
import '../state.dart'
    show
        AudioElement,
        HeadphonesRenderingMode,
        LoudnessInfo,
        Mix,
        MixElementSettings,
        MixLayout,
        SubMix;
import 'iamf_export_config.dart';
import 'iamf_export_validator.dart' show channelCountForLayout;
import 'iamf_fixed_point.dart';
import 'iamf_format_maps.dart';
import 'iamf_profile_rules.dart' show profileAllowsBinauralFilterProfile;

/// Generates an `iamf_tools_cli_proto::UserMetadata` textproto string
/// from an [IamfExportConfig].
///
/// The builder assumes the config has already passed
/// [validateIamfExport]. It will still tolerate minor issues (e.g.
/// unmeasured loudness) by emitting sentinel values, but it does not
/// re-run every validation check.
///
/// Textproto field names follow iamf-tools' `.proto` definitions. If a
/// field name ever doesn't parse against iamf-tools, fix it here — the
/// rest of the pipeline treats the output as an opaque string.
class UserMetadataBuilder {
  UserMetadataBuilder(this.config);

  final IamfExportConfig config;

  final StringBuffer _out = StringBuffer();
  int _indent = 0;

  // ID allocators. Each starts at a different base to make it easy to
  // tell them apart when eyeballing a textproto.
  int _nextCodecConfigId = 200;
  int _nextAudioElementId = 300;
  int _nextMixPresentationId = 400;
  int _nextSubstreamId = 0;
  int _nextParameterId = 100;

  /// (codec, sampleRate, bitDepth) → codecConfigId, to dedup configs.
  final Map<String, int> _codecConfigIds = {};

  /// Element.id → audioElementId (allocated during _writeAudioElements,
  /// consumed by mix presentations and audio frames).
  final Map<int, int> _audioElementIdByElement = {};

  // ── Public entry point ────────────────────────────────────────────────

  String build() {
    _writeTestVectorMetadata();
    _writeIaSequenceHeader();
    _writeCodecConfigs();
    _writeAudioElements();
    _writeMixPresentations();
    _writeAudioFrames();
    // No parameter_block_metadata: all our parameter definitions use
    // param_definition_mode=1 with a constant `default_mix_gain_db`, so
    // iamf-tools uses that default for every frame. Emitting a single
    // full-duration block trips its per-frame timestamp check; emitting
    // one block per 1024-sample frame would bloat the textproto by
    // ~13k entries for a ~5-minute session. Re-enable this step once
    // we actually need time-varying gain.
    _writeTemporalDelimiterMetadata();
    return _out.toString();
  }

  // ── Sections ──────────────────────────────────────────────────────────

  void _writeTestVectorMetadata() {
    _openMessage('test_vector_metadata');
    final stem = p.basenameWithoutExtension(config.outputPath);
    _field(
      'human_readable_description',
      _quote('Eclipsa Studio export ($stem)'),
    );
    _field('file_name_prefix', _quote(stem));
    _field('is_valid', 'true');
    // We emit a single full-duration constant-gain STEP parameter
    // block; iamf-tools' default per-frame partitioning fails because
    // the tail frame is shorter than num_samples_per_frame.
    _field('partition_mix_gain_parameter_blocks', 'false');
    _closeMessage();
  }

  void _writeIaSequenceHeader() {
    _openMessage('ia_sequence_header_metadata');
    final profile = iamfProfileName(config.profile);
    _field('primary_profile', profile);
    _field('additional_profile', profile);
    _closeMessage();
  }

  void _writeCodecConfigs() {
    for (final element in config.elements) {
      final key = _codecConfigKey(element);
      if (_codecConfigIds.containsKey(key)) continue;
      final id = _nextCodecConfigId++;
      _codecConfigIds[key] = id;
      _writeCodecConfig(id, element);
    }
  }

  void _writeCodecConfig(int id, AudioElement sample) {
    _openMessage('codec_config_metadata');
    _field('codec_config_id', '$id');
    _openMessage('codec_config');
    // iamf-tools takes the codec ID from the decoder config that is set,
    // and the encoder determines audio_roll_distance and the Opus
    // pre_skip, so none of the three is written.
    _field('num_samples_per_frame', '${config.framesPerCodedBlock}');
    if (config.codec == IamfCodec.opus) {
      _openMessage('decoder_config_opus');
      _field('version', '1');
      _field('input_sample_rate', '${config.sampleRate}');
      _openMessage('opus_encoder_metadata');
      _field('target_bitrate_per_channel', '${config.opusBitratePerChannel}');
      _field('application', 'APPLICATION_AUDIO');
      _closeMessage(); // opus_encoder_metadata
      _closeMessage(); // decoder_config_opus
    } else {
      _openMessage('decoder_config_lpcm');
      _field('sample_format_flags', 'LPCM_LITTLE_ENDIAN');
      _field('sample_size', '${_bitDepth(sample)}');
      _field('sample_rate', '${config.sampleRate}');
      _closeMessage(); // decoder_config_lpcm
    }
    _closeMessage(); // codec_config
    _closeMessage(); // codec_config_metadata
  }

  void _writeAudioElements() {
    for (final element in config.elements) {
      _writeAudioElement(element);
    }
  }

  void _writeAudioElement(AudioElement element) {
    final audioElementId = _nextAudioElementId++;
    _audioElementIdByElement[element.id] = audioElementId;

    final substreamIds = List<int>.generate(
      _substreamCountFor(element),
      (_) => _nextSubstreamId++,
    );

    _openMessage('audio_element_metadata');
    _field('audio_element_id', '$audioElementId');
    _field('audio_element_type', _audioElementTypeName(element));
    _field('reserved', '0');
    _field('codec_config_id', '${_codecConfigIds[_codecConfigKey(element)]}');
    _field('audio_substream_ids', _intList(substreamIds));

    switch (element.type) {
      case 'Channel':
        _writeScalableChannelLayoutConfig(element);
        break;
      case 'Scene':
        _writeAmbisonicsConfig(element, substreamIds);
        break;
      case 'Object':
        _writeObjectsConfig(element);
        break;
    }

    _closeMessage();
  }

  void _writeScalableChannelLayoutConfig(AudioElement element) {
    _openMessage('scalable_channel_layout_config');
    _field('reserved', '0');
    _openMessage('channel_audio_layer_configs');
    final layoutName = loudspeakerLayoutName(element.layout);
    if (layoutName != null) {
      _field('loudspeaker_layout', layoutName);
    } else {
      // Expanded layouts encode as LOUDSPEAKER_LAYOUT_EXPANDED plus an
      // ExpandedLoudspeakerLayout enum. Fail loudly for any expanded layout
      // we can't fully describe (substream grouping + channel labels) rather
      // than emit a textproto that fails to parse or encode downstream.
      final expanded = expandedLoudspeakerLayoutName(element.layout);
      if (expanded == null) {
        throw UnsupportedError(
          'IAMF export does not yet support the "${element.layout}" '
          'loudspeaker layout.',
        );
      }
      _field('loudspeaker_layout', 'LOUDSPEAKER_LAYOUT_EXPANDED');
      _field('expanded_loudspeaker_layout', expanded);
    }
    _field('output_gain_is_present_flag', '0');
    _field('recon_gain_is_present_flag', '0');
    _field('reserved_a', '0');
    // iamf-tools derives substream_count and coupled_substream_count
    // from the loudspeaker layout, so they are not written.
    _closeMessage(); // channel_audio_layer_configs
    _closeMessage(); // scalable_channel_layout_config
  }

  void _writeAmbisonicsConfig(AudioElement element, List<int> substreamIds) {
    // iamf-tools takes the ambisonics mode from which config is set.
    _openMessage('ambisonics_config');
    _openMessage('ambisonics_mono_config');
    final channels = substreamIds.length;
    _field('output_channel_count', '$channels');
    _field('substream_count', '$channels');
    // ACN ordering — identity mapping.
    _field('channel_mapping', _intList(List<int>.generate(channels, (i) => i)));
    _closeMessage(); // ambisonics_mono_config
    _closeMessage(); // ambisonics_config
  }

  void _writeObjectsConfig(AudioElement element) {
    _openMessage('objects_config');
    _field('num_objects', element.isDual ? '2' : '1');
    _closeMessage();
    // The object's default position (POLAR / DUAL_POLAR ParamDefinition)
    // lives in the mix presentation's rendering_config, not here — see
    // _writePolarParamDefinition (iamf-tools mix_presentation.proto).
  }

  void _writeMixPresentations() {
    for (final mix in config.mixes) {
      _writeMixPresentation(mix);
    }
  }

  void _writeMixPresentation(Mix mix) {
    final mixPresentationId = _nextMixPresentationId++;

    _openMessage('mix_presentation_metadata');
    _field('mix_presentation_id', '$mixPresentationId');
    _field('annotations_language', _stringList([mix.language]));
    _field('localized_presentation_annotations', _stringList([mix.name]));

    for (final sub in mix.subMixes) {
      _writeSubMix(sub);
    }

    _closeMessage();
  }

  void _writeSubMix(SubMix sub) {
    _openMessage('sub_mixes');

    for (final settings in sub.elementSettings) {
      if (!settings.included) continue;
      _writeSubMixAudioElement(settings);
    }

    _writeMixGainParamDefinition('output_mix_gain', sub.outputMixGain);

    for (final layout in sub.layouts) {
      _writeLayout(layout);
    }

    _closeMessage();
  }

  void _writeSubMixAudioElement(MixElementSettings settings) {
    final audioElementId = _audioElementIdByElement[settings.elementId];
    if (audioElementId == null) return; // element missing — validator caught
    final element = _elementById(settings.elementId);
    _openMessage('audio_elements');
    _field('audio_element_id', '$audioElementId');
    _field(
      'localized_element_annotations',
      _stringList([element?.name ?? 'element_${settings.elementId}']),
    );
    _openMessage('rendering_config');
    // Coerce like live playback does (effectiveHeadphonesMode):
    // channel-based Binaural elements are pre-rendered binaural stereo
    // and must export mode 0, or a conforming decoder would
    // binauralize them a second time.
    final mode = element == null
        ? settings.headphonesMode
        : settings.effectiveHeadphonesMode(element);
    _field('headphones_rendering_mode', headphonesRenderingModeName(mode));
    // binaural_filter_profile is a v2.0.0 field; older profiles keep the
    // textproto free of it (the validator already flags non-ambient
    // values there, so nothing is lost). The profile only has meaning
    // when the element is binauralized — under the coerced stereo mode
    // emit the ambient default rather than a stale stored value.
    if (profileAllowsBinauralFilterProfile(config.profile)) {
      final profile = mode == HeadphonesRenderingMode.stereo
          ? BinauralProfile.ambient
          : settings.binauralProfile;
      _field('binaural_filter_profile', binauralFilterProfileName(profile));
    }
    if (element != null && element.type == 'Object') {
      _writePolarParamDefinition(element);
    }
    _closeMessage();
    _writeMixGainParamDefinition('element_mix_gain', settings.mixGain);
    _closeMessage();
  }

  /// Emits the object's default position as a POLAR (mono) or DUAL_POLAR
  /// (dual) rendering-config parameter definition. Mode 1 means the
  /// defaults apply for the whole sequence — no parameter blocks needed,
  /// same as the mix gains.
  void _writePolarParamDefinition(AudioElement element) {
    _openMessage('rendering_config_param_definitions');
    _field(
      'param_definition_type',
      element.isDual
          ? 'PARAM_DEFINITION_TYPE_DUAL_POLAR'
          : 'PARAM_DEFINITION_TYPE_POLAR',
    );
    _openMessage(
      element.isDual ? 'dual_polar_param_definition' : 'polar_param_definition',
    );
    _openMessage('param_definition');
    _field('parameter_id', '${_nextParameterId++}');
    _field('parameter_rate', '${config.sampleRate}');
    _field('param_definition_mode', '1');
    _field('reserved', '0');
    _closeMessage(); // param_definition
    final elevation = encodeElevation(element.elevation);
    final distance = encodeNormalizedDistance(element.distance);
    if (element.isDual) {
      // One shared position split by ±spread/2; first = object channel 0
      // (the WAV's left channel), matching the scene visualizer.
      final az = splitDualAzimuth(
        centerAzimuth: element.azimuth,
        spread: element.spread,
      );
      _field('default_first_azimuth', '${az.firstAzimuth}');
      _field('default_first_elevation', '$elevation');
      _field('default_first_distance', '$distance');
      _field('default_second_azimuth', '${az.secondAzimuth}');
      _field('default_second_elevation', '$elevation');
      _field('default_second_distance', '$distance');
    } else {
      _field('default_azimuth', '${encodeAzimuth(element.azimuth)}');
      _field('default_elevation', '$elevation');
      _field('default_distance', '$distance');
    }
    _closeMessage(); // (dual_)polar_param_definition
    _closeMessage(); // rendering_config_param_definitions
  }

  void _writeMixGainParamDefinition(String fieldName, double gainDb) {
    _openMessage(fieldName);
    _openMessage('param_definition');
    final paramId = _nextParameterId++;
    _field('parameter_id', '$paramId');
    _field('parameter_rate', '${config.sampleRate}');
    _field('param_definition_mode', '1');
    _field('reserved', '0');
    _closeMessage(); // param_definition
    _openMessage('default_mix_gain_db');
    _field('q7_dot8', '${dbToQ7_8(gainDb)}');
    _closeMessage(); // default_mix_gain_db
    _closeMessage();
  }

  void _writeLayout(MixLayout layout) {
    _openMessage('layouts');
    _openMessage('loudness_layout');
    if (layout.soundSystem.label.toLowerCase() == 'binaural') {
      _field('layout_type', 'LAYOUT_TYPE_BINAURAL');
      _openMessage('reserved_or_binaural_layout');
      _field('reserved', '0');
      _closeMessage();
    } else {
      _field('layout_type', 'LAYOUT_TYPE_LOUDSPEAKERS_SS_CONVENTION');
      final ss = iamfSoundSystemName(layout.soundSystem);
      _openMessage('ss_layout');
      _field('sound_system', ss ?? 'SOUND_SYSTEM_INVALID');
      _field('reserved', '0');
      _closeMessage();
    }
    _closeMessage(); // loudness_layout
    _writeLoudness(layout.loudness);
    _closeMessage(); // layouts
  }

  /// The three measured scalars are advisory — iamf-tools recomputes
  /// and overwrites them at finalize (ES-492) — but the TRUE_PEAK
  /// info-type bit ships from this stamp: without it the encoder would
  /// neither compute nor write a true peak.
  void _writeLoudness(LoudnessInfo loudness) {
    _openMessage('loudness');
    if (loudness.truePeak != null) {
      _field('info_type_bit_masks', '[LOUDNESS_INFO_TYPE_TRUE_PEAK]');
    }
    _field('integrated_loudness', '${lufsToQ7_8(loudness.integratedLoudness)}');
    _field('digital_peak', '${dbToQ7_8(loudness.digitalPeak)}');
    if (loudness.truePeak != null) {
      _field('true_peak', '${dbToQ7_8(loudness.truePeak!)}');
    }
    _closeMessage(); // loudness
  }

  void _writeAudioFrames() {
    // iamf-tools requires every substream to share the same
    // samples_to_trim_at_end. The dialog pads every bounced WAV to
    // paddedFrames and sets trim = paddedFrames - longestSource (the
    // frame-alignment pad only). Shorter elements end in silence before
    // the longest; that silence is part of the audio, not trim. Without
    // the dialog's values the trim is 0, and iamf-tools pads a partial
    // final frame and trims the pad itself (auto mode in _writeAudioFrame).
    final trimEnd = config.paddedFrames > 0 && config.longestSourceFrames > 0
        ? config.paddedFrames - config.longestSourceFrames
        : 0;
    for (final element in config.elements) {
      _writeAudioFrame(element, trimEnd);
    }
  }

  void _writeAudioFrame(AudioElement element, int trimEnd) {
    final wavPath = element.wavPath;
    if (wavPath == null) return;
    final basename = config.basenameFor(element.id, wavPath);
    final audioElementId = _audioElementIdByElement[element.id];
    if (audioElementId == null) return;

    _openMessage('audio_frame_metadata');
    _field('wav_filename', _quote(basename));
    _field('samples_to_trim_at_end', '$trimEnd');
    _field('samples_to_trim_at_start', '0');
    // Auto mode, the settings the iamf-tools proto recommends, for both
    // codecs: iamf-tools adds the codec delay to the start trim and the
    // final-frame padding to the end trim. With the defaults (true) the
    // values above must already include both, so an LPCM input that
    // ends partway through a frame, or any Opus input, fails to encode.
    _field('samples_to_trim_at_start_includes_codec_delay', 'false');
    _field('samples_to_trim_at_end_includes_padding', 'false');
    _field('audio_element_id', '$audioElementId');
    final labels = _channelLabelsFor(element);
    if (labels.isNotEmpty) {
      _field(
        'channel_metadatas',
        '[${labels.indexed.map((e) => '{ channel_id: ${e.$1} channel_label: ${e.$2} }').join(', ')}]',
      );
    }
    _closeMessage();
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// IAMF substream grouping per channel layout. IAMF separates center
  /// and LFE into non-coupled mono substreams while pairing the
  /// remaining channels into coupled stereo substreams — the ceiling
  /// formula used to assume *all* channels pair up, which is wrong for
  /// every layout with a C/LFE (5.x, 7.x, 3.1.2).
  ///
  /// iamf-tools derives the substream count from the loudspeaker layout,
  /// and `audio_substream_ids` must list that many IDs. Values mirror
  /// `kInputLayoutToNumSubstreams` in iamf-tools
  /// (`audio_element_metadata_builder.cc`).
  static const _kChannelSubstreamCounts = <String, int>{
    'mono': 1,
    'stereo': 1,
    'binaural': 1,
    '3.1.2': 4,
    '5.1': 4,
    '5.1.2': 5,
    '5.1.4': 6,
    '7.1': 5,
    '7.1.2': 6,
    '7.1.4': 7,
    // 9.1.6 is an expanded layout: 16 channels grouped as 7 coupled stereo
    // substreams + C and LFE as uncoupled mono substreams = 9 total.
    '9.1.6': 9,
  };

  /// Substream count for an element. Channel layouts use the IAMF
  /// grouping table above; scene (ambisonics) is one uncoupled
  /// substream per channel; object is always exactly one substream
  /// (dual = one coupled stereo substream — iamf-tools rejects
  /// object-based elements with any other count).
  int _substreamCountFor(AudioElement element) {
    if (element.type == 'Object') return 1;
    if (element.type == 'Scene') return channelCountForLayout(element);
    final count = _kChannelSubstreamCounts[element.layout.toLowerCase()];
    if (count != null) return count;
    // Fallback for unknown/custom layouts: pair everything as stereo.
    final ch = channelCountForLayout(element);
    return (ch + 1) ~/ 2;
  }

  // ── Temporal delimiter ────────────────────────────────────────────

  void _writeTemporalDelimiterMetadata() {
    _openMessage('temporal_delimiter_metadata');
    _field('enable_temporal_delimiters', 'false');
    _closeMessage();
  }

  // ── Helpers ───────────────────────────────────────────────────────

  /// IAMF channel labels for an element, matching the ChannelLabel
  /// enum in iamf-tools' audio_frame.proto.
  List<String> _channelLabelsFor(AudioElement element) {
    if (element.type == 'Object') {
      return element.isDual
          ? ['CHANNEL_LABEL_OBJECT_CHANNEL0', 'CHANNEL_LABEL_OBJECT_CHANNEL1']
          : ['CHANNEL_LABEL_OBJECT_CHANNEL0'];
    }
    if (element.type == 'Scene') {
      final n = channelCountForLayout(element);
      return List.generate(n, (i) => 'CHANNEL_LABEL_A_$i');
    }
    return _channelLayoutLabels(element.layout);
  }

  static List<String> _channelLayoutLabels(String layout) {
    switch (layout.toLowerCase()) {
      case 'mono':
        return ['CHANNEL_LABEL_MONO'];
      case 'stereo':
      case 'binaural':
        return ['CHANNEL_LABEL_L_2', 'CHANNEL_LABEL_R_2'];
      case '3.1.2':
        return [
          'CHANNEL_LABEL_L_3',
          'CHANNEL_LABEL_R_3',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LTF_3',
          'CHANNEL_LABEL_RTF_3',
        ];
      case '5.1':
        return [
          'CHANNEL_LABEL_L_5',
          'CHANNEL_LABEL_R_5',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LS_5',
          'CHANNEL_LABEL_RS_5',
        ];
      case '5.1.2':
        return [
          'CHANNEL_LABEL_L_5',
          'CHANNEL_LABEL_R_5',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LS_5',
          'CHANNEL_LABEL_RS_5',
          'CHANNEL_LABEL_LTF_2',
          'CHANNEL_LABEL_RTF_2',
        ];
      case '5.1.4':
        return [
          'CHANNEL_LABEL_L_5',
          'CHANNEL_LABEL_R_5',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LS_5',
          'CHANNEL_LABEL_RS_5',
          'CHANNEL_LABEL_LTF_4',
          'CHANNEL_LABEL_RTF_4',
          'CHANNEL_LABEL_LTB_4',
          'CHANNEL_LABEL_RTB_4',
        ];
      case '7.1':
        return [
          'CHANNEL_LABEL_L_7',
          'CHANNEL_LABEL_R_7',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LSS_7',
          'CHANNEL_LABEL_RSS_7',
          'CHANNEL_LABEL_LRS_7',
          'CHANNEL_LABEL_RRS_7',
        ];
      case '7.1.2':
        return [
          'CHANNEL_LABEL_L_7',
          'CHANNEL_LABEL_R_7',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LSS_7',
          'CHANNEL_LABEL_RSS_7',
          'CHANNEL_LABEL_LRS_7',
          'CHANNEL_LABEL_RRS_7',
          'CHANNEL_LABEL_LTF_2',
          'CHANNEL_LABEL_RTF_2',
        ];
      case '7.1.4':
        return [
          'CHANNEL_LABEL_L_7',
          'CHANNEL_LABEL_R_7',
          'CHANNEL_LABEL_CENTRE',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_LSS_7',
          'CHANNEL_LABEL_RSS_7',
          'CHANNEL_LABEL_LRS_7',
          'CHANNEL_LABEL_RRS_7',
          'CHANNEL_LABEL_LTF_4',
          'CHANNEL_LABEL_RTF_4',
          'CHANNEL_LABEL_LTB_4',
          'CHANNEL_LABEL_RTB_4',
        ];
      case '9.1.6':
        // Expanded layout, a WAV in the app's 9.1.6 order (OBR's alt
        // order, models/layout_916.dart): channel_id is the WAV index and
        // the label names the channel at that index. iamf-tools keys each
        // WAV channel by its label (wav_sample_provider.cc), so the order
        // of this list does not have to be its canonical 9.1.6 order (FL
        // FR FC LFE BL BR FLc FRc SiL SiR, then the tops).
        return [
          'CHANNEL_LABEL_FLC',
          'CHANNEL_LABEL_FRC',
          'CHANNEL_LABEL_FC',
          'CHANNEL_LABEL_LFE',
          'CHANNEL_LABEL_FL',
          'CHANNEL_LABEL_FR',
          'CHANNEL_LABEL_SI_L',
          'CHANNEL_LABEL_SI_R',
          'CHANNEL_LABEL_BL',
          'CHANNEL_LABEL_BR',
          'CHANNEL_LABEL_TP_FL',
          'CHANNEL_LABEL_TP_FR',
          'CHANNEL_LABEL_TP_SI_L',
          'CHANNEL_LABEL_TP_SI_R',
          'CHANNEL_LABEL_TP_BL',
          'CHANNEL_LABEL_TP_BR',
        ];
      default:
        return [];
    }
  }

  String _audioElementTypeName(AudioElement element) {
    switch (element.type) {
      case 'Channel':
        return 'AUDIO_ELEMENT_CHANNEL_BASED';
      case 'Scene':
        return 'AUDIO_ELEMENT_SCENE_BASED';
      case 'Object':
        return 'AUDIO_ELEMENT_OBJECT_BASED';
      default:
        throw UnsupportedError('Unknown element type: ${element.type}');
    }
  }

  String _codecConfigKey(AudioElement e) => config.codec == IamfCodec.opus
      // One shared Opus config: source bit depth is irrelevant after
      // the transcode, so every element dedups to the same key.
      ? 'OPUS|${config.sampleRate}'
      : '${e.codec.toUpperCase()}|${config.sampleRate}|${_bitDepth(e)}';

  int _bitDepth(AudioElement e) {
    final wav = e.wavInfo;
    if (wav != null && wav.bitsPerSample > 0) return wav.bitsPerSample;
    return config.bitDepth;
  }

  AudioElement? _elementById(int elementId) {
    for (final e in config.elements) {
      if (e.id == elementId) return e;
    }
    return null;
  }

  // ── Textproto writer primitives ───────────────────────────────────────

  void _openMessage(String name) {
    _writeIndent();
    _out.write(name);
    _out.write(' {\n');
    _indent++;
  }

  void _closeMessage() {
    _indent--;
    _writeIndent();
    _out.write('}\n');
  }

  void _field(String key, String value) {
    _writeIndent();
    _out.write(key);
    _out.write(': ');
    _out.write(value);
    _out.write('\n');
  }

  void _writeIndent() {
    for (var i = 0; i < _indent; i++) {
      _out.write('  ');
    }
  }

  String _quote(String s) => '"${s.replaceAll('"', r'\"')}"';

  String _intList(List<int> xs) => '[${xs.join(", ")}]';

  String _stringList(List<String> xs) => '[${xs.map(_quote).join(", ")}]';
}

/// Convenience — build a textproto in one call.
String buildUserMetadataTextproto(IamfExportConfig config) =>
    UserMetadataBuilder(config).build();
