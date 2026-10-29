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

import 'dart:ffi';

import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../ffi/engine_bindings.dart';
import '../ffi/engine_strings.dart';
import '../ffi_bridge.dart' show EclipsaStudioEngine;
import 'iamf_probe_full.dart' as full_probe;

/// Why an AE is not renderable, as judged by the engine
/// (`EclipsaStudioAeSkipReason` in engine/iamf/iamf_probe_ffi.h).
enum IamfAeSkipReason {
  none,
  notDecodable,
  layoutNotRenderable,
  objectBased,
  unknownType;

  /// Sentence-case copy for notices and tooltips.
  String get label => switch (this) {
    none => '',
    notDecodable => "this build can't decode the element",
    layoutNotRenderable => 'the renderer has no support for the layout',
    objectBased => "object-based audio isn't supported yet",
    unknownType => 'unrecognised audio element type',
  };
}

/// One audio element as reported by `iamf_tools::Probe()`.
///
/// `layoutLabel` is the probe's raw loudspeaker-layout string (e.g.
/// `"Stereo"`, `"5.1.4"`) — null for scene- or object-based AEs and for
/// channel-based AEs whose layout the probe could not resolve.
/// `ambisonicsOrder` is the scene-based ambisonics order, or -1.
///
/// `renderable` is the engine's authoritative verdict (ES-330): its decode
/// capability ANDed with the OAR capability mapping — the same mapping
/// playback registration uses, so this flag and what actually plays
/// cannot drift apart. Never re-derive it from [layoutLabel].
class IamfAe {
  const IamfAe({
    required this.id,
    required this.layoutLabel,
    required this.ambisonicsOrder,
    required this.numChannels,
    this.renderable = true,
    this.skipReason = IamfAeSkipReason.none,
  });

  final int id;
  final String? layoutLabel;
  final int ambisonicsOrder;
  final int numChannels;
  final bool renderable;
  final IamfAeSkipReason skipReason;
}

/// Per-AE default mix gain inside a mix presentation, in dB. Used as
/// the seed value when the engine switches to this mix presentation;
/// the stream's per-TU `mix_gain_db_per_ae` overrides at runtime.
class IamfMixElementGain {
  const IamfMixElementGain({
    required this.audioElementId,
    required this.defaultGainDb,
    this.paramDefinitionMode = 1,
    this.headphonesRenderingMode,
    this.binauralFilterProfile,
  });

  final int audioElementId;
  final double defaultGainDb;

  /// `param_definition_mode` of the element mix gain (IAMF §3.6.1).
  /// Descriptors alone cannot prove whether the stream carries mix-gain
  /// parameter blocks: mode 0 fixes the block partitioning in the
  /// definition and strongly implies stream-carried (time-varying)
  /// gain; mode 1 with no blocks in the stream — the shape our own
  /// exporter writes — means [defaultGainDb] is the whole truth.
  /// Defaults to 1 when the full probe was unavailable.
  final int paramDefinitionMode;

  /// Rendering-config strings from the full probe (e.g.
  /// `"binaural_world_locked"`, `"ambient"`); null when unavailable.
  final String? headphonesRenderingMode;
  final String? binauralFilterProfile;
}

/// One sub-mix of a mix presentation, populated from the full
/// descriptor probe by [enrichReportWithFullProbe]. Carries the
/// complete element set (with gains and rendering configs), the
/// sub-mix output gain, and every declared layout — the data Playback
/// needs to gate and gain elements per selected presentation.
class IamfSubMixInfo {
  const IamfSubMixInfo({
    required this.elements,
    required this.outputMixGainDb,
    this.outputGainParamDefinitionMode = 1,
    this.layouts = const [],
  });

  final List<IamfMixElementGain> elements;
  final double outputMixGainDb;

  /// See [IamfMixElementGain.paramDefinitionMode]; same semantics for
  /// the sub-mix output gain.
  final int outputGainParamDefinitionMode;
  final List<IamfSubMixLayout> layouts;
}

/// One loudness layout of a sub-mix, with the loudness_info the file
/// stores for it. [digitalPeakDbfs] is null only when the full probe
/// was unavailable; [truePeakDbtp] is also null when the file's
/// `info_type` omits true peak.
class IamfSubMixLayout {
  const IamfSubMixLayout({
    required this.layoutType,
    this.soundSystem,
    this.integratedLoudnessLufs,
    this.digitalPeakDbfs,
    this.truePeakDbtp,
  });

  final String layoutType;
  final String? soundSystem;
  final double? integratedLoudnessLufs;
  final double? digitalPeakDbfs;
  final double? truePeakDbtp;
}

/// One mix presentation entry. `loudnessLufs` / `truePeakDbtp` are null
/// when the source's Mix Presentation OBU does not carry the annotation.
///
/// `layoutType` / `soundSystem` and `elements` are derived from the
/// first sub-mix. `soundSystem` is null for non-loudspeaker layouts
/// (e.g. binaural).
class IamfMixPresentation {
  const IamfMixPresentation({
    required this.id,
    required this.name,
    required this.language,
    required this.loudnessLufs,
    required this.truePeakDbtp,
    required this.elements,
    required this.layoutType,
    required this.soundSystem,
    this.subMixes = const [],
  });

  final int id;
  final String? name;
  final String? language;
  final double? loudnessLufs;
  final double? truePeakDbtp;
  final List<IamfMixElementGain> elements;
  final String? layoutType;
  final String? soundSystem;

  /// Every sub-mix of this presentation, populated by
  /// [enrichReportWithFullProbe] (the C-struct probe itself only
  /// carries the first sub-mix, mirrored in [elements] / [layoutType]
  /// / [soundSystem]). Never empty after enrichment: when the full
  /// probe is unavailable a single sub-mix is synthesized from the
  /// first-sub-mix fields.
  final List<IamfSubMixInfo> subMixes;
}

/// Summary of an IAMF file returned by [probeIamfWithFull].
class IamfProbeReport {
  const IamfProbeReport({
    required this.ok,
    required this.errorMessage,
    required this.sampleRate,
    required this.totalSamples,
    required this.audioElements,
    required this.mixPresentations,
  });

  const IamfProbeReport.error(String message)
    : ok = false,
      errorMessage = message,
      sampleRate = 0,
      totalSamples = 0,
      audioElements = const [],
      mixPresentations = const [];

  final bool ok;
  final String? errorMessage;
  final int sampleRate;
  final int totalSamples;
  final List<IamfAe> audioElements;
  final List<IamfMixPresentation> mixPresentations;

  /// Duration in seconds, or null when the probe could not determine it
  /// (file is descriptors-only or the temporal-unit scan produced no
  /// samples).
  double? get durationSeconds {
    if (sampleRate == 0 || totalSamples == 0) return null;
    return totalSamples / sampleRate;
  }
}

// ---------------------------------------------------------------------------
// Full-probe enrichment (ES-282)
// ---------------------------------------------------------------------------

/// Merge the full descriptor probe into [report]'s mix presentations.
///
/// The C-struct probe collapses each presentation to its first sub-mix
/// (see `iamf_probe_ffi.h`); the JSON full probe carries every sub-mix.
/// Presentations are matched by id. When [full] failed, or has no match
/// for a presentation, a single sub-mix is synthesized from the thin
/// first-sub-mix data so consumers always see a uniform
/// [IamfMixPresentation.subMixes] surface.
IamfProbeReport enrichReportWithFullProbe(
  IamfProbeReport report,
  full_probe.IamfFullProbe full,
) {
  if (!report.ok) return report;
  final fullById = <int, full_probe.IamfMixPresentation>{
    if (full.ok)
      for (final mp in full.mixPresentations) mp.id: mp,
  };
  return IamfProbeReport(
    ok: true,
    errorMessage: null,
    sampleRate: report.sampleRate,
    totalSamples: report.totalSamples,
    audioElements: report.audioElements,
    mixPresentations: [
      for (final mp in report.mixPresentations)
        _enrichPresentation(mp, fullById[mp.id]),
    ],
  );
}

IamfMixPresentation _enrichPresentation(
  IamfMixPresentation mp,
  full_probe.IamfMixPresentation? f,
) {
  final subMixes = f != null && f.subMixes.isNotEmpty
      ? [for (final sm in f.subMixes) _subMixFrom(sm)]
      : [_synthesizedSubMix(mp)];
  return IamfMixPresentation(
    id: mp.id,
    name: mp.name,
    language: mp.language,
    loudnessLufs: mp.loudnessLufs,
    truePeakDbtp: mp.truePeakDbtp,
    // Keep the first-sub-mix convenience list, upgraded to the enriched
    // entries (adds param modes + rendering configs).
    elements: subMixes.first.elements,
    layoutType: mp.layoutType,
    soundSystem: mp.soundSystem,
    subMixes: subMixes,
  );
}

IamfSubMixInfo _subMixFrom(full_probe.IamfSubMix sm) => IamfSubMixInfo(
  elements: [
    for (final ae in sm.audioElements)
      IamfMixElementGain(
        audioElementId: ae.audioElementId,
        defaultGainDb: ae.elementMixGain.defaultMixGain,
        paramDefinitionMode:
            ae.elementMixGain.paramDefinition.paramDefinitionMode,
        headphonesRenderingMode: ae.headphonesRenderingMode.isEmpty
            ? null
            : ae.headphonesRenderingMode,
        binauralFilterProfile: ae.binauralFilterProfile.isEmpty
            ? null
            : ae.binauralFilterProfile,
      ),
  ],
  outputMixGainDb: sm.outputMixGain.defaultMixGain,
  outputGainParamDefinitionMode:
      sm.outputMixGain.paramDefinition.paramDefinitionMode,
  layouts: [
    for (final l in sm.layouts)
      IamfSubMixLayout(
        layoutType: l.layoutType,
        soundSystem: l.soundSystem,
        integratedLoudnessLufs: l.loudness.integratedLoudness,
        digitalPeakDbfs: l.loudness.digitalPeak,
        truePeakDbtp: l.loudness.truePeak,
      ),
  ],
);

IamfSubMixInfo _synthesizedSubMix(IamfMixPresentation mp) => IamfSubMixInfo(
  elements: mp.elements,
  outputMixGainDb: 0,
  layouts: [
    if (mp.layoutType != null)
      IamfSubMixLayout(
        layoutType: mp.layoutType!,
        soundSystem: mp.soundSystem,
        integratedLoudnessLufs: mp.loudnessLufs,
        truePeakDbtp: mp.truePeakDbtp,
      ),
  ],
);

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Parses the descriptor OBUs of the IAMF file at [path] twice, into the
/// C-struct report and the full descriptor dump
/// ([full_probe.probeIamfFullSync]), on one background isolate so the UI
/// stays responsive. The full probe is skipped when the first one fails.
Future<(IamfProbeReport, full_probe.IamfFullProbe)> probeIamfWithFull(
  String path,
) => compute(_probeIamfWithFullInIsolate, path);

(IamfProbeReport, full_probe.IamfFullProbe) _probeIamfWithFullInIsolate(
  String path,
) {
  final report = _probeIamfInIsolate(path);
  return (
    report,
    report.ok
        ? full_probe.probeIamfFullSync(path)
        : full_probe.IamfFullProbe.error('skipped: probe failed'),
  );
}

// Runs the first probe on the isolate that [probeIamfWithFull] starts.
IamfProbeReport _probeIamfInIsolate(String path) {
  // The probe isolate has no shared Dart state with main, so we open
  // the dylib fresh here. EclipsaStudioEngine.dylibPath resolves the same
  // path the main-isolate engine uses.
  final bindings = EngineBindings(
    DynamicLibrary.open(EclipsaStudioEngine.dylibPath),
  );
  final probeFn = bindings.iamfProbe;
  final freeFn = bindings.iamfProbeFree;

  final pathPtr = path.toNativeUtf8(allocator: ffi_pkg.malloc);
  Pointer<NativeIamfProbeResult> resultPtr;
  try {
    resultPtr = probeFn(pathPtr);
  } finally {
    ffi_pkg.malloc.free(pathPtr);
  }
  if (resultPtr == nullptr) {
    return const IamfProbeReport.error('probe allocation failed');
  }
  try {
    return readProbeResult(resultPtr.ref);
  } finally {
    freeFn(resultPtr);
  }
}

/// Copies [native], an `eclipsa_studio_iamf_probe` result, into Dart. Does
/// not free it.
@visibleForTesting
IamfProbeReport readProbeResult(NativeIamfProbeResult native) {
  if (native.status != 0) {
    // A file-open error holds the path cut to 256 bytes, which can end
    // inside a character.
    final msg = native.errorMessage == nullptr
        ? 'probe failed (status ${native.status})'
        : decodeEngineString(native.errorMessage);
    return IamfProbeReport.error(msg);
  }

  final aes = <IamfAe>[];
  for (var i = 0; i < native.numAudioElements; i++) {
    final n = (native.audioElements + i).ref;
    final label = n.layoutLabel == nullptr
        ? null
        : n.layoutLabel.toDartString();
    aes.add(
      IamfAe(
        id: n.audioElementId,
        layoutLabel: label,
        ambisonicsOrder: n.ambisonicsOrder,
        numChannels: n.numChannels != 0
            ? n.numChannels
            : (_channelCountForLayout(label) ?? 0),
        renderable: n.renderable != 0,
        skipReason: _mapSkipReason(n.skipReason),
      ),
    );
  }

  final mps = <IamfMixPresentation>[];
  for (var i = 0; i < native.numMixPresentations; i++) {
    final n = (native.mixPresentations + i).ref;
    final els = <IamfMixElementGain>[];
    for (var j = 0; j < n.numElements; j++) {
      final e = (n.elements + j).ref;
      els.add(
        IamfMixElementGain(
          audioElementId: e.audioElementId,
          defaultGainDb: e.defaultMixGainDb,
        ),
      );
    }
    mps.add(
      IamfMixPresentation(
        id: n.mixPresentationId,
        // Copied from the file's annotations, so not necessarily UTF-8.
        name: n.name == nullptr ? null : decodeEngineString(n.name),
        language: n.language == nullptr ? null : decodeEngineString(n.language),
        loudnessLufs: n.loudnessLufs.isNaN ? null : n.loudnessLufs,
        truePeakDbtp: n.truePeakDbtp.isNaN ? null : n.truePeakDbtp,
        elements: els,
        layoutType: n.layoutType == nullptr
            ? null
            : n.layoutType.toDartString(),
        soundSystem: n.soundSystem == nullptr
            ? null
            : n.soundSystem.toDartString(),
      ),
    );
  }

  return IamfProbeReport(
    ok: true,
    errorMessage: null,
    sampleRate: native.sampleRate,
    totalSamples: native.totalSamples,
    audioElements: aes,
    mixPresentations: mps,
  );
}

IamfAeSkipReason _mapSkipReason(int r) => switch (r) {
  0 => IamfAeSkipReason.none,
  1 => IamfAeSkipReason.notDecodable,
  2 => IamfAeSkipReason.layoutNotRenderable,
  3 => IamfAeSkipReason.objectBased,
  _ => IamfAeSkipReason.unknownType,
};

int? _channelCountForLayout(String? label) => switch (label) {
  'Mono' => 1,
  'Stereo' => 2,
  '5.1' => 6,
  '5.1.2' => 8,
  '5.1.4' => 10,
  '7.1.4' => 12,
  _ => null,
};
