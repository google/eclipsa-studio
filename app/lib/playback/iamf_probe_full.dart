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

// Full descriptor-OBU probe report consumed by the Inspector view.
//
// Companion to `iamf_probe.dart`. The thin probe surface there is what
// the Playback open path consumes (audio elements + mix presentations,
// just enough to gate engine open and seed the active mix). This file
// goes deep: it mirrors the JSON tree emitted by the engine's
// `eclipsa_studio_iamf_probe_json` FFI, which serialises the full upstream
// `iamf_tools::ProbeReport` via `iamf_tools::ProbeReportToJson` (wrapped
// in an {ok, report} envelope). The Inspector renders these classes
// section-by-section to surface the same metadata the iamf-inspector
// browser tool exposes — codec configs (Opus / LPCM / AAC / FLAC),
// scalable channel layers, ambisonics mono / projection, mix-gain
// param definitions, layouts with full loudness annotations, tags.
//
// Why JSON: hand-rolling ~30 nested structs through C ABI would
// quadruple the FFI surface and rot every time iamf-tools adds a
// field. Descriptor data is at most a few KB even on huge files, so
// the encode + parse cost is irrelevant.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../ffi/engine_bindings.dart';
import '../ffi_bridge.dart' show EclipsaStudioEngine;

// ---------------------------------------------------------------------------
// Model classes
// ---------------------------------------------------------------------------

class IamfFullProbe {
  const IamfFullProbe({
    required this.ok,
    required this.errorMessage,
    required this.primaryProfile,
    required this.additionalProfile,
    required this.descriptorBytesConsumed,
    required this.codecConfigs,
    required this.audioElements,
    required this.mixPresentations,
  });

  factory IamfFullProbe.error(String message) => IamfFullProbe(
    ok: false,
    errorMessage: message,
    primaryProfile: '',
    additionalProfile: '',
    descriptorBytesConsumed: 0,
    codecConfigs: const [],
    audioElements: const [],
    mixPresentations: const [],
  );

  final bool ok;
  final String? errorMessage;
  final String primaryProfile;
  final String additionalProfile;
  final int descriptorBytesConsumed;
  final List<IamfCodecConfig> codecConfigs;
  final List<IamfAudioElement> audioElements;
  final List<IamfMixPresentation> mixPresentations;
}

class IamfCodecConfig {
  const IamfCodecConfig({
    required this.id,
    required this.codecId,
    required this.numSamplesPerFrame,
    required this.audioRollDistance,
    required this.outputSampleRate,
    required this.inputSampleRate,
    required this.bitDepthToMeasureLoudness,
    this.opus,
    this.lpcm,
    this.aac,
    this.flac,
  });

  final int id;
  final String codecId;
  final int numSamplesPerFrame;
  final int audioRollDistance;
  final int outputSampleRate;
  final int inputSampleRate;
  final int bitDepthToMeasureLoudness;
  final IamfOpusConfig? opus;
  final IamfLpcmConfig? lpcm;
  final IamfAacConfig? aac;
  final IamfFlacConfig? flac;
}

class IamfOpusConfig {
  const IamfOpusConfig({
    required this.version,
    required this.outputChannelCount,
    required this.preSkip,
    required this.inputSampleRate,
    required this.outputGain,
    required this.mappingFamily,
  });

  final int version;
  final int outputChannelCount;
  final int preSkip;
  final int inputSampleRate;
  final int outputGain; // raw signed Q7.8 → divide by 256 for dB.
  final int mappingFamily;
}

class IamfLpcmConfig {
  const IamfLpcmConfig({
    required this.sampleFormat,
    required this.sampleSize,
    required this.sampleRate,
  });

  final String sampleFormat;
  final int sampleSize;
  final int sampleRate;
}

class IamfAacConfig {
  const IamfAacConfig({
    required this.objectTypeIndication,
    required this.streamType,
    required this.upstream,
    required this.bufferSizeDb,
    required this.maxBitrate,
    required this.averageBitRate,
    required this.audioObjectType,
    required this.sampleFrequencyIndex,
    required this.channelConfiguration,
  });

  final int objectTypeIndication;
  final int streamType;
  final bool upstream;
  final int bufferSizeDb;
  final int maxBitrate;
  final int averageBitRate;
  final int audioObjectType;
  final String sampleFrequencyIndex;
  final int channelConfiguration;
}

class IamfFlacConfig {
  const IamfFlacConfig({required this.metadataBlocks});

  final List<IamfFlacMetadataBlock> metadataBlocks;

  IamfFlacMetadataBlock? get streamInfo {
    for (final b in metadataBlocks) {
      if (b.isStreamInfo) return b;
    }
    return null;
  }
}

class IamfFlacMetadataBlock {
  const IamfFlacMetadataBlock({
    required this.blockType,
    required this.isStreamInfo,
    this.minimumBlockSize,
    this.maximumBlockSize,
    this.minimumFrameSize,
    this.maximumFrameSize,
    this.sampleRate,
    this.numberOfChannels,
    this.bitsPerSample,
    this.totalSamplesInStream,
  });

  final String blockType;
  final bool isStreamInfo;
  final int? minimumBlockSize;
  final int? maximumBlockSize;
  final int? minimumFrameSize;
  final int? maximumFrameSize;
  final int? sampleRate;
  final int? numberOfChannels;
  final int? bitsPerSample;
  final int? totalSamplesInStream;
}

// --- Audio elements ---

class IamfAudioElement {
  const IamfAudioElement({
    required this.id,
    required this.type,
    required this.codecConfigId,
    required this.numSubstreams,
    required this.substreamIds,
    required this.params,
    required this.scalableLayers,
    this.ambisonics,
    this.channelLayout,
    this.ambisonicsOrder,
    this.ambisonicsChannels,
  });

  final int id;
  final String type;
  final int codecConfigId;
  final int numSubstreams;
  final List<int> substreamIds;
  final List<IamfAudioElementParam> params;
  final List<IamfScalableLayer> scalableLayers;
  final IamfAmbisonics? ambisonics;
  final String? channelLayout;
  final int? ambisonicsOrder;
  final int? ambisonicsChannels;
}

class IamfAudioElementParam {
  const IamfAudioElementParam({
    required this.paramType,
    required this.parameterId,
    required this.parameterRate,
    required this.paramDefinitionMode,
    required this.duration,
    required this.constantSubblockDuration,
  });

  final String paramType;
  final int parameterId;
  final int parameterRate;
  final int paramDefinitionMode;
  final int duration;
  final int constantSubblockDuration;
}

class IamfScalableLayer {
  const IamfScalableLayer({
    required this.loudspeakerLayout,
    this.expandedLoudspeakerLayout,
    required this.outputGainIsPresentFlag,
    required this.reconGainIsPresentFlag,
    required this.substreamCount,
    required this.coupledSubstreamCount,
    required this.outputGainFlag,
    required this.outputGain,
  });

  final String loudspeakerLayout;
  final String? expandedLoudspeakerLayout;
  final bool outputGainIsPresentFlag;
  final bool reconGainIsPresentFlag;
  final int substreamCount;
  final int coupledSubstreamCount;
  final int outputGainFlag; // 6-bit per-channel mask
  final int outputGain; // signed Q7.8 → /256 = dB
}

class IamfAmbisonics {
  const IamfAmbisonics({
    required this.mode,
    this.order,
    this.mono,
    this.projection,
  });

  final String mode;
  final int? order;
  final IamfAmbisonicsMono? mono;
  final IamfAmbisonicsProjection? projection;
}

class IamfAmbisonicsMono {
  const IamfAmbisonicsMono({
    required this.outputChannelCount,
    required this.substreamCount,
    required this.channelMapping,
  });

  final int outputChannelCount;
  final int substreamCount;
  final List<int> channelMapping;
}

class IamfAmbisonicsProjection {
  const IamfAmbisonicsProjection({
    required this.outputChannelCount,
    required this.substreamCount,
    required this.coupledSubstreamCount,
    required this.demixingMatrix,
  });

  final int outputChannelCount;
  final int substreamCount;
  final int coupledSubstreamCount;
  final List<int> demixingMatrix;
}

// --- Mix presentations ---

class IamfMixPresentation {
  const IamfMixPresentation({
    required this.id,
    required this.countLabel,
    required this.numSubMixes,
    required this.annotations,
    required this.subMixes,
    required this.tags,
    this.integratedLoudnessLkfs,
    this.digitalPeakDbfs,
    this.truePeakDbfs,
  });

  final int id;
  final int countLabel;
  final int numSubMixes;
  final List<IamfAnnotation> annotations;
  final List<IamfSubMix> subMixes;
  final List<IamfTag> tags;
  final double? integratedLoudnessLkfs;
  final double? digitalPeakDbfs;
  final double? truePeakDbfs;
}

class IamfAnnotation {
  const IamfAnnotation({required this.language, required this.label});
  final String language;
  final String label;
}

class IamfTag {
  const IamfTag({required this.tagName, required this.tagValue});
  final String tagName;
  final String tagValue;
}

class IamfSubMix {
  const IamfSubMix({
    required this.audioElements,
    required this.outputMixGain,
    required this.layouts,
  });

  final List<IamfSubMixAudioElement> audioElements;
  final IamfMixGain outputMixGain;
  final List<IamfMixPresentationLayout> layouts;
}

class IamfSubMixAudioElement {
  const IamfSubMixAudioElement({
    required this.audioElementId,
    required this.localizedElementAnnotations,
    required this.headphonesRenderingMode,
    required this.binauralFilterProfile,
    required this.elementMixGain,
  });

  final int audioElementId;
  final List<String> localizedElementAnnotations;
  final String headphonesRenderingMode;
  final String binauralFilterProfile;
  final IamfMixGain elementMixGain;
}

class IamfMixGain {
  const IamfMixGain({
    required this.paramDefinition,
    required this.defaultMixGainQ7_8,
    required this.defaultMixGain,
  });

  final IamfParamDefinition paramDefinition;
  final int defaultMixGainQ7_8;
  final double defaultMixGain; // Already in dB.
}

class IamfParamDefinition {
  const IamfParamDefinition({
    required this.parameterId,
    required this.parameterRate,
    required this.paramDefinitionMode,
    required this.duration,
    required this.constantSubblockDuration,
  });

  final int parameterId;
  final int parameterRate;
  final int paramDefinitionMode;
  final int duration;
  final int constantSubblockDuration;
}

class IamfMixPresentationLayout {
  const IamfMixPresentationLayout({
    required this.layoutType,
    this.soundSystem,
    required this.loudness,
  });

  final String layoutType;
  final String? soundSystem;
  final IamfLoudness loudness;
}

class IamfLoudness {
  const IamfLoudness({
    required this.infoType,
    required this.truePeakPresent,
    required this.hasLayoutExtension,
    required this.integratedLoudness,
    required this.digitalPeak,
    this.truePeak,
  });

  final int infoType;
  final bool truePeakPresent;
  final bool hasLayoutExtension;
  final double integratedLoudness;
  final double digitalPeak;
  final double? truePeak;
}

// ---------------------------------------------------------------------------
// JSON parsing
// ---------------------------------------------------------------------------

@visibleForTesting
IamfFullProbe parseProbeJson(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    return IamfFullProbe.error('probe JSON parse failed: $e');
  }
  if (decoded is! Map<String, dynamic>) {
    return IamfFullProbe.error('probe JSON: expected object root');
  }
  if (decoded['ok'] != true) {
    final err = decoded['error'];
    return IamfFullProbe.error(err is String ? err : 'unknown probe error');
  }
  final report = decoded['report'];
  if (report is! Map<String, dynamic>) {
    return IamfFullProbe.error('probe JSON: missing "report"');
  }
  return IamfFullProbe(
    ok: true,
    errorMessage: null,
    primaryProfile: _str(report, 'primary_profile') ?? '',
    additionalProfile: _str(report, 'additional_profile') ?? '',
    descriptorBytesConsumed: _int(report, 'descriptor_bytes_consumed') ?? 0,
    codecConfigs: _list(report, 'codec_configs', _parseCodecConfig),
    audioElements: _list(report, 'audio_elements', _parseAudioElement),
    mixPresentations: _list(report, 'mix_presentations', _parseMixPresentation),
  );
}

IamfCodecConfig _parseCodecConfig(Map<String, dynamic> j) => IamfCodecConfig(
  id: _int(j, 'id') ?? 0,
  codecId: _str(j, 'codec_id') ?? '',
  numSamplesPerFrame: _int(j, 'num_samples_per_frame') ?? 0,
  audioRollDistance: _int(j, 'audio_roll_distance') ?? 0,
  outputSampleRate: _int(j, 'output_sample_rate') ?? 0,
  inputSampleRate: _int(j, 'input_sample_rate') ?? 0,
  bitDepthToMeasureLoudness: _int(j, 'bit_depth') ?? 0,
  opus: _obj(j, 'opus', _parseOpus),
  lpcm: _obj(j, 'lpcm', _parseLpcm),
  aac: _obj(j, 'aac', _parseAac),
  flac: _obj(j, 'flac', _parseFlac),
);

IamfOpusConfig _parseOpus(Map<String, dynamic> j) => IamfOpusConfig(
  version: _int(j, 'version') ?? 0,
  outputChannelCount: _int(j, 'output_channel_count') ?? 0,
  preSkip: _int(j, 'pre_skip') ?? 0,
  inputSampleRate: _int(j, 'input_sample_rate') ?? 0,
  // `output_gain` is now the decoded-dB float; the raw Q7.8 the UI
  // divides by 256 lives in the `_q7_8` sibling.
  outputGain: _int(j, 'output_gain_q7_8') ?? 0,
  mappingFamily: _int(j, 'mapping_family') ?? 0,
);

IamfLpcmConfig _parseLpcm(Map<String, dynamic> j) => IamfLpcmConfig(
  sampleFormat: _str(j, 'sample_format') ?? '',
  sampleSize: _int(j, 'sample_size') ?? 0,
  sampleRate: _int(j, 'sample_rate') ?? 0,
);

IamfAacConfig _parseAac(Map<String, dynamic> j) => IamfAacConfig(
  objectTypeIndication: _int(j, 'object_type_indication') ?? 0,
  streamType: _int(j, 'stream_type') ?? 0,
  upstream: _bool(j, 'upstream') ?? false,
  bufferSizeDb: _int(j, 'buffer_size_db') ?? 0,
  maxBitrate: _int(j, 'max_bitrate') ?? 0,
  averageBitRate: _int(j, 'average_bit_rate') ?? 0,
  audioObjectType: _int(j, 'audio_object_type') ?? 0,
  sampleFrequencyIndex: _str(j, 'sample_frequency_index') ?? '',
  channelConfiguration: _int(j, 'channel_configuration') ?? 0,
);

IamfFlacConfig _parseFlac(Map<String, dynamic> j) =>
    IamfFlacConfig(metadataBlocks: _list(j, 'metadata_blocks', _parseFlacMeta));

IamfFlacMetadataBlock _parseFlacMeta(Map<String, dynamic> j) {
  // Upstream's serializer drops a dedicated is_stream_info flag and only
  // emits the STREAMINFO detail fields for that block. FLAC fixes
  // STREAMINFO as metadata block type 0, so key off the raw type.
  final isInfo = (_int(j, 'block_type_raw') ?? -1) == 0;
  return IamfFlacMetadataBlock(
    blockType: _str(j, 'block_type') ?? '',
    isStreamInfo: isInfo,
    minimumBlockSize: _int(j, 'minimum_block_size'),
    maximumBlockSize: _int(j, 'maximum_block_size'),
    minimumFrameSize: _int(j, 'minimum_frame_size'),
    maximumFrameSize: _int(j, 'maximum_frame_size'),
    sampleRate: _int(j, 'sample_rate'),
    numberOfChannels: _int(j, 'number_of_channels'),
    bitsPerSample: _int(j, 'bits_per_sample'),
    totalSamplesInStream: _int(j, 'total_samples_in_stream'),
  );
}

IamfAudioElement _parseAudioElement(Map<String, dynamic> j) => IamfAudioElement(
  id: _int(j, 'id') ?? 0,
  type: _str(j, 'type') ?? '',
  codecConfigId: _int(j, 'codec_config_id') ?? 0,
  numSubstreams: _int(j, 'num_substreams') ?? 0,
  substreamIds: _intList(j, 'substream_ids'),
  params: _list(j, 'params', _parseAudioElementParam),
  scalableLayers: _list(j, 'scalable_layers', _parseScalableLayer),
  ambisonics: _obj(j, 'ambisonics', _parseAmbisonics),
  channelLayout: _str(j, 'channel_layout'),
  ambisonicsOrder: _int(j, 'ambisonics_order'),
  ambisonicsChannels: _int(j, 'ambisonics_channels'),
);

IamfAudioElementParam _parseAudioElementParam(Map<String, dynamic> j) =>
    IamfAudioElementParam(
      paramType: _str(j, 'param_type') ?? '',
      parameterId: _int(j, 'parameter_id') ?? 0,
      parameterRate: _int(j, 'parameter_rate') ?? 0,
      paramDefinitionMode: _int(j, 'param_definition_mode') ?? 0,
      duration: _int(j, 'duration') ?? 0,
      constantSubblockDuration: _int(j, 'constant_subblock_duration') ?? 0,
    );

IamfScalableLayer _parseScalableLayer(Map<String, dynamic> j) =>
    IamfScalableLayer(
      loudspeakerLayout: _str(j, 'loudspeaker_layout') ?? '',
      expandedLoudspeakerLayout: _str(j, 'expanded_loudspeaker_layout'),
      outputGainIsPresentFlag: _bool(j, 'output_gain_is_present_flag') ?? false,
      reconGainIsPresentFlag: _bool(j, 'recon_gain_is_present_flag') ?? false,
      substreamCount: _int(j, 'substream_count') ?? 0,
      coupledSubstreamCount: _int(j, 'coupled_substream_count') ?? 0,
      outputGainFlag: _int(j, 'output_gain_flag') ?? 0,
      // Raw Q7.8 (the UI divides by 256); `output_gain` is the dB float.
      outputGain: _int(j, 'output_gain_q7_8') ?? 0,
    );

IamfAmbisonics _parseAmbisonics(Map<String, dynamic> j) => IamfAmbisonics(
  mode: _str(j, 'mode') ?? '',
  order: _int(j, 'order'),
  mono: _obj(j, 'mono', _parseAmbisonicsMono),
  projection: _obj(j, 'projection', _parseAmbisonicsProjection),
);

IamfAmbisonicsMono _parseAmbisonicsMono(Map<String, dynamic> j) =>
    IamfAmbisonicsMono(
      outputChannelCount: _int(j, 'output_channel_count') ?? 0,
      substreamCount: _int(j, 'substream_count') ?? 0,
      channelMapping: _intList(j, 'channel_mapping'),
    );

IamfAmbisonicsProjection _parseAmbisonicsProjection(Map<String, dynamic> j) =>
    IamfAmbisonicsProjection(
      outputChannelCount: _int(j, 'output_channel_count') ?? 0,
      substreamCount: _int(j, 'substream_count') ?? 0,
      coupledSubstreamCount: _int(j, 'coupled_substream_count') ?? 0,
      demixingMatrix: _intList(j, 'demixing_matrix'),
    );

IamfMixPresentation _parseMixPresentation(Map<String, dynamic> j) =>
    IamfMixPresentation(
      id: _int(j, 'id') ?? 0,
      countLabel: _int(j, 'count_label') ?? 0,
      numSubMixes: _int(j, 'num_sub_mixes') ?? 0,
      annotations: _list(j, 'annotations', _parseAnnotation),
      subMixes: _list(j, 'sub_mixes', _parseSubMix),
      tags: _list(j, 'tags', _parseTag),
      integratedLoudnessLkfs: _double(j, 'integrated_loudness_lkfs'),
      digitalPeakDbfs: _double(j, 'digital_peak_dbfs'),
      truePeakDbfs: _double(j, 'true_peak_dbfs'),
    );

IamfAnnotation _parseAnnotation(Map<String, dynamic> j) => IamfAnnotation(
  language: _str(j, 'language') ?? '',
  label: _str(j, 'label') ?? '',
);

IamfTag _parseTag(Map<String, dynamic> j) => IamfTag(
  tagName: _str(j, 'tag_name') ?? '',
  tagValue: _str(j, 'tag_value') ?? '',
);

IamfSubMix _parseSubMix(Map<String, dynamic> j) => IamfSubMix(
  audioElements: _list(j, 'audio_elements', _parseSubMixAe),
  outputMixGain:
      _obj(j, 'output_mix_gain', _parseMixGain) ??
      const IamfMixGain(
        paramDefinition: IamfParamDefinition(
          parameterId: 0,
          parameterRate: 0,
          paramDefinitionMode: 0,
          duration: 0,
          constantSubblockDuration: 0,
        ),
        defaultMixGainQ7_8: 0,
        defaultMixGain: 0,
      ),
  layouts: _list(j, 'layouts', _parseLayout),
);

IamfSubMixAudioElement _parseSubMixAe(Map<String, dynamic> j) {
  final rc = j['rendering_config'];
  final renderingConfig = rc is Map<String, dynamic> ? rc : <String, dynamic>{};
  return IamfSubMixAudioElement(
    audioElementId: _int(j, 'audio_element_id') ?? 0,
    localizedElementAnnotations: _strList(j, 'localized_element_annotations'),
    headphonesRenderingMode:
        _str(renderingConfig, 'headphones_rendering_mode') ?? '',
    binauralFilterProfile:
        _str(renderingConfig, 'binaural_filter_profile') ?? '',
    elementMixGain:
        _obj(j, 'element_mix_gain', _parseMixGain) ??
        const IamfMixGain(
          paramDefinition: IamfParamDefinition(
            parameterId: 0,
            parameterRate: 0,
            paramDefinitionMode: 0,
            duration: 0,
            constantSubblockDuration: 0,
          ),
          defaultMixGainQ7_8: 0,
          defaultMixGain: 0,
        ),
  );
}

IamfMixGain _parseMixGain(Map<String, dynamic> j) => IamfMixGain(
  paramDefinition:
      _obj(j, 'param_definition', _parseParamDef) ??
      const IamfParamDefinition(
        parameterId: 0,
        parameterRate: 0,
        paramDefinitionMode: 0,
        duration: 0,
        constantSubblockDuration: 0,
      ),
  defaultMixGainQ7_8: _int(j, 'default_mix_gain_q7_8') ?? 0,
  defaultMixGain: _double(j, 'default_mix_gain') ?? 0,
);

IamfParamDefinition _parseParamDef(Map<String, dynamic> j) =>
    IamfParamDefinition(
      parameterId: _int(j, 'parameter_id') ?? 0,
      parameterRate: _int(j, 'parameter_rate') ?? 0,
      paramDefinitionMode: _int(j, 'param_definition_mode') ?? 0,
      duration: _int(j, 'duration') ?? 0,
      constantSubblockDuration: _int(j, 'constant_subblock_duration') ?? 0,
    );

IamfMixPresentationLayout _parseLayout(Map<String, dynamic> j) {
  final ll = j['loudness_layout'];
  final layoutMap = ll is Map<String, dynamic> ? ll : <String, dynamic>{};
  return IamfMixPresentationLayout(
    layoutType: _str(layoutMap, 'layout_type') ?? '',
    soundSystem: _str(layoutMap, 'sound_system'),
    loudness:
        _obj(j, 'loudness', _parseLoudness) ??
        const IamfLoudness(
          infoType: 0,
          truePeakPresent: false,
          hasLayoutExtension: false,
          integratedLoudness: 0,
          digitalPeak: 0,
          truePeak: null,
        ),
  );
}

IamfLoudness _parseLoudness(Map<String, dynamic> j) => IamfLoudness(
  infoType: _int(j, 'info_type') ?? 0,
  truePeakPresent: _bool(j, 'true_peak_present') ?? false,
  hasLayoutExtension: _bool(j, 'has_layout_extension') ?? false,
  integratedLoudness: _double(j, 'integrated_loudness') ?? 0,
  digitalPeak: _double(j, 'digital_peak') ?? 0,
  truePeak: _double(j, 'true_peak'),
);

// --- JSON field accessors ---

String? _str(Map<String, dynamic> j, String k) {
  final v = j[k];
  return v is String ? v : null;
}

int? _int(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is int) return v;
  if (v is double) return v.toInt();
  return null;
}

double? _double(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is num) return v.toDouble();
  return null;
}

bool? _bool(Map<String, dynamic> j, String k) {
  final v = j[k];
  return v is bool ? v : null;
}

List<int> _intList(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is num) e.toInt(),
  ];
}

List<String> _strList(Map<String, dynamic> j, String k) {
  final v = j[k];
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is String) e,
  ];
}

List<T> _list<T>(
  Map<String, dynamic> j,
  String k,
  T Function(Map<String, dynamic>) parse,
) {
  final v = j[k];
  if (v is! List) return const [];
  final out = <T>[];
  for (final e in v) {
    if (e is Map<String, dynamic>) out.add(parse(e));
  }
  return out;
}

T? _obj<T>(
  Map<String, dynamic> j,
  String k,
  T Function(Map<String, dynamic>) parse,
) {
  final v = j[k];
  return v is Map<String, dynamic> ? parse(v) : null;
}

// ---------------------------------------------------------------------------
// FFI entry point
// ---------------------------------------------------------------------------

/// Probe `path` and return the full descriptor-OBU dump. Runs the FFI
/// call on a background isolate via `compute()` so the UI thread stays
/// responsive on large files (the slurp + descriptor parse is the
/// dominant cost).
Future<IamfFullProbe> probeIamfFull(String path) =>
    compute(_probeIamfFullInIsolate, path);

IamfFullProbe _probeIamfFullInIsolate(String path) {
  final bindings = EngineBindings(
    DynamicLibrary.open(EclipsaStudioEngine.dylibPath),
  );
  final probeFn = bindings.iamfProbeJson;
  final freeFn = bindings.iamfProbeJsonFree;

  final pathPtr = path.toNativeUtf8(allocator: ffi_pkg.malloc);
  Pointer<ffi_pkg.Utf8> resultPtr;
  try {
    resultPtr = probeFn(pathPtr);
  } finally {
    ffi_pkg.malloc.free(pathPtr);
  }
  if (resultPtr == nullptr) {
    return IamfFullProbe.error('probe_json: native allocation failed');
  }
  try {
    return parseProbeJson(resultPtr.toDartString());
  } finally {
    freeFn(resultPtr);
  }
}
