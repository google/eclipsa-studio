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

// Shared FFI bindings for the Eclipsa Studio engine library.
//
// This is the single home for the engine-symbol FFI seam that is used
// from more than one isolate. Worker isolates (export, probe, waveform,
// video, ADM import) legitimately cannot share a [DynamicLibrary] handle
// with the main isolate, so each re-OPENS the dylib — the path always
// comes from `EclipsaStudioEngine.dylibPath` (the single path source),
// threaded through the isolate init message — but they all share the
// typedefs, struct mirrors, and lookups defined here instead of
// re-declaring private copies per file.
//
// [EngineBindings] exposes each symbol as a `late final` lazily-bound
// field, so an isolate that binds only what it touches pays only those
// lookups (and a missing symbol only throws if actually used).
//
// The main-isolate facade (`EclipsaStudioEngine` in lib/ffi_bridge.dart) keeps
// its own bindings for the engine-lifecycle surface it alone uses, and
// draws on this module for symbols shared with worker isolates.

import 'dart:ffi';

import 'package:ffi/ffi.dart' as ffi_pkg;

// ---------------------------------------------------------------------------
// Struct mirrors referenced by shared binding signatures
//
// Field order and types mirror the C structs exactly so the Dart FFI
// runtime computes the same ABI layout (including alignment padding).
// Struct mirrors used from a single file stay in that file; only the
// ones that appear in EngineBindings signatures live here.
// ---------------------------------------------------------------------------

/// Mirrors `EclipsaStudioPeakData` header in waveform/peak_compute.h.
///
/// Layout:
///   num_channels      :  4 B
///   num_levels        :  4 B
///   sample_rate       :  4 B
///   total_samples     :  4 B
///   samples_per_peak[8]: 32 B
///   num_peaks[8]      : 32 B
///   total             : 80 B
///
/// The float data immediately follows in memory; use
/// [EngineBindings.peaksLevelData] to access it.
final class EclipsaStudioPeakData extends Struct {
  @Uint32()
  external int numChannels;

  @Uint32()
  external int numLevels;

  @Uint32()
  external int sampleRate;

  @Uint32()
  external int totalSamples;

  @Array(8)
  external Array<Uint32> samplesPerPeak;

  @Array(8)
  external Array<Uint32> numPeaks;
}

// Mirrors the C structs in engine/iamf/iamf_probe_ffi.h. Field order and
// types must match the C ABI exactly; see that header for semantics.

/// One audio element in an `eclipsa_studio_iamf_probe` result.
final class NativeIamfProbeAe extends Struct {
  @Uint32()
  external int audioElementId;

  @Int32()
  external int type;

  @Uint32()
  external int numChannels;

  @Int32()
  external int ambisonicsOrder;

  external Pointer<ffi_pkg.Utf8> layoutLabel;

  @Int32()
  external int renderable;

  @Int32()
  external int skipReason;
}

/// One per-AE mix-gain entry of a probed mix presentation.
final class NativeIamfProbeMixElement extends Struct {
  @Uint32()
  external int audioElementId;

  @Float()
  external double defaultMixGainDb;
}

/// One mix presentation in an `eclipsa_studio_iamf_probe` result.
final class NativeIamfProbeMixPres extends Struct {
  @Uint32()
  external int mixPresentationId;

  external Pointer<ffi_pkg.Utf8> name;
  external Pointer<ffi_pkg.Utf8> language;

  @Double()
  external double loudnessLufs;

  @Double()
  external double truePeakDbtp;

  @Uint32()
  external int numElements;

  external Pointer<NativeIamfProbeMixElement> elements;
  external Pointer<ffi_pkg.Utf8> layoutType;
  external Pointer<ffi_pkg.Utf8> soundSystem;
}

/// Top-level `eclipsa_studio_iamf_probe` result; release with
/// [EngineBindings.iamfProbeFree].
final class NativeIamfProbeResult extends Struct {
  @Int32()
  external int status;

  external Pointer<ffi_pkg.Utf8> errorMessage;

  @Uint32()
  external int sampleRate;

  @Uint64()
  external int totalSamples;

  @Uint32()
  external int numAudioElements;

  external Pointer<NativeIamfProbeAe> audioElements;

  @Uint32()
  external int numMixPresentations;

  external Pointer<NativeIamfProbeMixPres> mixPresentations;
}

/// Mirrors `EclipsaStudioVideoInfo` (engine/video/video_ffi.h); returned by
/// value from `eclipsa_studio_video_info`.
final class NativeVideoInfo extends Struct {
  @Int32()
  external int width;

  @Int32()
  external int height;

  @Double()
  external double fps;

  @Int64()
  external int durationMs;

  @Int32()
  external int ok; // 0 = failed to open / no video stream.

  @Int32()
  external int hw; // 1 = HW decoder (VideoToolbox/D3D11VA) attached.

  @Int32()
  external int quarterTurns; // Clockwise display rotation, 0-3.
}

/// Mirrors `Adm2iamfRenderConfig` field-for-field. Dart FFI follows the same
/// platform ABI: the leading int is padded to 8 bytes before the pointers.
/// Expected `sizeOf` is 24 on a 64-bit target.
final class Adm2iamfRenderConfig extends Struct {
  @Int32()
  external int minImportance;

  external Pointer<ffi_pkg.Utf8> inPath;

  external Pointer<ffi_pkg.Utf8> outPath;
}

// ---------------------------------------------------------------------------
// Typedefs — one Native + Dart pair per engine symbol
// ---------------------------------------------------------------------------

// ── IAMF export / mux / element bounce (engine.h) ──────────────────

typedef IamfExportCancelNative = Void Function();
typedef IamfExportCancelDart = void Function();

// float eclipsa_studio_iamf_export_progress(void);
typedef IamfExportProgressNative = Float Function();
typedef IamfExportProgressDart = double Function();

// int32_t eclipsa_studio_iamf_push_export_begin(const char* config_textproto,
//                                        const char* output_iamf_path);
typedef IamfPushExportBeginNative =
    Int32 Function(Pointer<ffi_pkg.Utf8>, Pointer<ffi_pkg.Utf8>);
typedef IamfPushExportBeginDart =
    int Function(Pointer<ffi_pkg.Utf8>, Pointer<ffi_pkg.Utf8>);

// int32_t eclipsa_studio_iamf_push_export_add_element(const char* wav_basename,
//     const char* source_wav_path, float gain_db, const int32_t* routing,
//     int32_t routing_len, uint64_t pad_to_frames,
//     uint32_t output_sample_rate);
typedef IamfPushExportAddElementNative =
    Int32 Function(
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
      Float,
      Pointer<Int32>,
      Int32,
      Uint64,
      Uint32,
    );
typedef IamfPushExportAddElementDart =
    int Function(
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
      double,
      Pointer<Int32>,
      int,
      int,
      int,
    );

// int32_t eclipsa_studio_iamf_push_export_run(void);
typedef IamfPushExportRunNative = Int32 Function();
typedef IamfPushExportRunDart = int Function();

// int32_t eclipsa_studio_iamf_push_export_element_clip_stats(uint32_t index,
//     uint64_t* out_clipped_samples, float* out_peak_linear);
typedef IamfPushExportElementClipStatsNative =
    Int32 Function(Uint32, Pointer<Uint64>, Pointer<Float>);
typedef IamfPushExportElementClipStatsDart =
    int Function(int, Pointer<Uint64>, Pointer<Float>);

// int32_t eclipsa_studio_iamf_mux(const char* input_iamf,
//                          const char* input_video,
//                          const char* output_mp4);
typedef IamfMuxNative =
    Int32 Function(
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
    );
typedef IamfMuxDart =
    int Function(
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
      Pointer<ffi_pkg.Utf8>,
    );

// int32_t eclipsa_studio_video_container_probe(const char* input_video);
typedef VideoContainerProbeNative = Int32 Function(Pointer<ffi_pkg.Utf8>);
typedef VideoContainerProbeDart = int Function(Pointer<ffi_pkg.Utf8>);

// int32_t eclipsa_studio_fs_volume_info(const char* path,
//     uint64_t* out_free_bytes, uint64_t* out_volume_id);
typedef FsVolumeInfoNative =
    Int32 Function(Pointer<ffi_pkg.Utf8>, Pointer<Uint64>, Pointer<Uint64>);
typedef FsVolumeInfoDart =
    int Function(Pointer<ffi_pkg.Utf8>, Pointer<Uint64>, Pointer<Uint64>);

// int32_t eclipsa_studio_still_video_encode(const uint8_t* rgba,
//     uint64_t rgba_size, uint32_t width, uint32_t height, uint32_t fps,
//     double duration_seconds, const char* output_mp4);
typedef StillVideoEncodeNative =
    Int32 Function(
      Pointer<Uint8>,
      Uint64,
      Uint32,
      Uint32,
      Uint32,
      Double,
      Pointer<ffi_pkg.Utf8>,
    );
typedef StillVideoEncodeDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      double,
      Pointer<ffi_pkg.Utf8>,
    );

// ── Offline mix renderer (engine.h) ────────────────────────────────

typedef MixRendererCreateNative = Pointer Function(Uint32, Uint32, Uint32);
typedef MixRendererCreateDart = Pointer Function(int, int, int);

// int32_t eclipsa_studio_mix_renderer_add_element(
//     eclipsa_studio_mix_renderer_t* r, const char* source_wav_path,
//     uint32_t element_id,
//     int32_t element_type, int32_t element_sub_type, uint32_t channels,
//     float mix_gain_db, uint32_t headphones_mode,
//     uint32_t binaural_profile, float gain_db, const int32_t* routing,
//     int32_t routing_len, uint64_t pad_to_frames,
//     uint32_t output_sample_rate);
typedef MixRendererAddElementNative =
    Int32 Function(
      Pointer,
      Pointer<ffi_pkg.Utf8>,
      Uint32,
      Int32,
      Int32,
      Uint32,
      Float,
      Uint32,
      Uint32,
      Float,
      Pointer<Int32>,
      Int32,
      Uint64,
      Uint32,
    );
typedef MixRendererAddElementDart =
    int Function(
      Pointer,
      Pointer<ffi_pkg.Utf8>,
      int,
      int,
      int,
      int,
      double,
      int,
      int,
      double,
      Pointer<Int32>,
      int,
      int,
      int,
    );

typedef MixRendererSetObjectPositionNative =
    Void Function(
      Pointer,
      Uint32,
      Uint32,
      Float,
      Float,
      Float,
      Float,
      Float,
      Float,
    );
typedef MixRendererSetObjectPositionDart =
    void Function(
      Pointer,
      int,
      int,
      double,
      double,
      double,
      double,
      double,
      double,
    );

typedef MixRendererSetOutputGainNative = Void Function(Pointer, Float);
typedef MixRendererSetOutputGainDart = void Function(Pointer, double);

typedef MixRendererMeasureNative =
    Int32 Function(Pointer, Pointer<Float>, Pointer<Float>, Pointer<Float>);
typedef MixRendererMeasureDart =
    int Function(Pointer, Pointer<Float>, Pointer<Float>, Pointer<Float>);

typedef MixRendererTraceLenNative = Uint32 Function(Pointer, Uint32);
typedef MixRendererTraceLenDart = int Function(Pointer, int);

typedef MixRendererCopyTraceNative =
    Uint32 Function(Pointer, Uint32, Pointer<Float>, Uint32);
typedef MixRendererCopyTraceDart =
    int Function(Pointer, int, Pointer<Float>, int);

typedef MixRendererLoudnessRangeNative =
    Int32 Function(Pointer, Pointer<Float>, Pointer<Int32>);
typedef MixRendererLoudnessRangeDart =
    int Function(Pointer, Pointer<Float>, Pointer<Int32>);

// int32_t eclipsa_studio_mix_renderer_element_clip_stats(
//     eclipsa_studio_mix_renderer_t* r, uint32_t element_id,
//     uint64_t* out_clipped_samples,
//     float* out_peak_linear);
typedef MixRendererElementClipStatsNative =
    Int32 Function(Pointer, Uint32, Pointer<Uint64>, Pointer<Float>);
typedef MixRendererElementClipStatsDart =
    int Function(Pointer, int, Pointer<Uint64>, Pointer<Float>);

typedef MixRendererDestroyNative = Void Function(Pointer);
typedef MixRendererDestroyDart = void Function(Pointer);

// ── Waveform peaks (waveform/peak_compute.h) ───────────────────────

typedef PeaksComputeNative =
    Pointer<EclipsaStudioPeakData> Function(
      Pointer<ffi_pkg.Utf8>,
      Uint32,
      Uint32,
    );
typedef PeaksComputeDart =
    Pointer<EclipsaStudioPeakData> Function(Pointer<ffi_pkg.Utf8>, int, int);

typedef PeaksFreeNative = Void Function(Pointer<EclipsaStudioPeakData>);
typedef PeaksFreeDart = void Function(Pointer<EclipsaStudioPeakData>);

typedef PeaksLevelDataNative =
    Pointer<Float> Function(Pointer<EclipsaStudioPeakData>, Uint32, Uint32);
typedef PeaksLevelDataDart =
    Pointer<Float> Function(Pointer<EclipsaStudioPeakData>, int, int);

// ── IAMF probe (engine/iamf/iamf_probe_ffi.h) ──────────────────────

typedef IamfProbeNative =
    Pointer<NativeIamfProbeResult> Function(Pointer<ffi_pkg.Utf8>);
typedef IamfProbeDart =
    Pointer<NativeIamfProbeResult> Function(Pointer<ffi_pkg.Utf8>);

typedef IamfProbeFreeNative = Void Function(Pointer<NativeIamfProbeResult>);
typedef IamfProbeFreeDart = void Function(Pointer<NativeIamfProbeResult>);

typedef IamfProbeJsonNative =
    Pointer<ffi_pkg.Utf8> Function(Pointer<ffi_pkg.Utf8>);
typedef IamfProbeJsonDart =
    Pointer<ffi_pkg.Utf8> Function(Pointer<ffi_pkg.Utf8>);

typedef IamfProbeJsonFreeNative = Void Function(Pointer<ffi_pkg.Utf8>);
typedef IamfProbeJsonFreeDart = void Function(Pointer<ffi_pkg.Utf8>);

// ── Video decode (engine/video/video_ffi.h) ────────────────────────

typedef VideoOpenNative = Pointer<Void> Function(Pointer<ffi_pkg.Utf8>);
typedef VideoOpenDart = Pointer<Void> Function(Pointer<ffi_pkg.Utf8>);

typedef VideoInfoNative = NativeVideoInfo Function(Pointer<Void>);
typedef VideoInfoDart = NativeVideoInfo Function(Pointer<Void>);

typedef VideoFrameAtNative =
    Pointer<Uint8> Function(
      Pointer<Void>,
      Double,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef VideoFrameAtDart =
    Pointer<Uint8> Function(
      Pointer<Void>,
      double,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
    );

// Zero-copy path: returns an opaque CVPixelBuffer handle (or null) for a
// hardware-decoded frame; writes width / height.
typedef VideoFrameAtPixbufNative =
    Pointer<Void> Function(
      Pointer<Void>,
      Double,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef VideoFrameAtPixbufDart =
    Pointer<Void> Function(
      Pointer<Void>,
      double,
      Pointer<Int32>,
      Pointer<Int32>,
    );

typedef VideoReleasePixbufNative = Void Function(Pointer<Void>);
typedef VideoReleasePixbufDart = void Function(Pointer<Void>);

typedef VideoCloseNative = Void Function(Pointer<Void>);
typedef VideoCloseDart = void Function(Pointer<Void>);

// ── ADM import (engine/adm_import/ffi/adm2iamf_ffi.h) ──────────────

typedef AdmProbeJsonNative =
    Pointer<ffi_pkg.Utf8> Function(Pointer<ffi_pkg.Utf8>);
typedef AdmProbeJsonDart =
    Pointer<ffi_pkg.Utf8> Function(Pointer<ffi_pkg.Utf8>);

typedef AdmStringFreeNative = Void Function(Pointer<ffi_pkg.Utf8>);
typedef AdmStringFreeDart = void Function(Pointer<ffi_pkg.Utf8>);

typedef AdmRenderStartNative = Int32 Function(Pointer<Adm2iamfRenderConfig>);
typedef AdmRenderStartDart = int Function(Pointer<Adm2iamfRenderConfig>);

typedef AdmRenderProgressNative = Float Function(Int32);
typedef AdmRenderProgressDart = double Function(int);

typedef AdmRenderStateNative = Int32 Function(Int32);
typedef AdmRenderStateDart = int Function(int);

typedef AdmRenderResultJsonNative = Pointer<ffi_pkg.Utf8> Function(Int32);
typedef AdmRenderResultJsonDart = Pointer<ffi_pkg.Utf8> Function(int);

typedef AdmRenderCancelNative = Void Function(Int32);
typedef AdmRenderCancelDart = void Function(int);

typedef AdmShutdownNative = Void Function();
typedef AdmShutdownDart = void Function();

typedef AdmVersionNative = Pointer<ffi_pkg.Utf8> Function();
typedef AdmVersionDart = Pointer<ffi_pkg.Utf8> Function();

// ---------------------------------------------------------------------------
// EngineBindings
// ---------------------------------------------------------------------------

/// Lazily-bound lookups over an opened engine [DynamicLibrary].
///
/// Construct one per dylib handle (per isolate). Every field is a
/// `late final` lookup, so only the symbols actually used are resolved.
class EngineBindings {
  EngineBindings(this.lib);

  /// The opened engine library the lookups resolve against.
  final DynamicLibrary lib;

  // ── IAMF export / mux / element bounce ───────────────────────────

  late final iamfExportCancel = lib
      .lookupFunction<IamfExportCancelNative, IamfExportCancelDart>(
        'eclipsa_studio_iamf_export_cancel',
      );

  late final iamfExportProgress = lib
      .lookupFunction<IamfExportProgressNative, IamfExportProgressDart>(
        'eclipsa_studio_iamf_export_progress',
      );

  late final iamfPushExportBegin = lib
      .lookupFunction<IamfPushExportBeginNative, IamfPushExportBeginDart>(
        'eclipsa_studio_iamf_push_export_begin',
      );

  late final iamfPushExportAddElement = lib
      .lookupFunction<
        IamfPushExportAddElementNative,
        IamfPushExportAddElementDart
      >('eclipsa_studio_iamf_push_export_add_element');

  late final iamfPushExportRun = lib
      .lookupFunction<IamfPushExportRunNative, IamfPushExportRunDart>(
        'eclipsa_studio_iamf_push_export_run',
      );

  late final iamfPushExportElementClipStats = lib
      .lookupFunction<
        IamfPushExportElementClipStatsNative,
        IamfPushExportElementClipStatsDart
      >('eclipsa_studio_iamf_push_export_element_clip_stats');

  late final iamfMux = lib.lookupFunction<IamfMuxNative, IamfMuxDart>(
    'eclipsa_studio_iamf_mux',
  );

  late final videoContainerProbe = lib
      .lookupFunction<VideoContainerProbeNative, VideoContainerProbeDart>(
        'eclipsa_studio_video_container_probe',
      );

  late final fsVolumeInfo = lib
      .lookupFunction<FsVolumeInfoNative, FsVolumeInfoDart>(
        'eclipsa_studio_fs_volume_info',
      );

  late final stillVideoEncode = lib
      .lookupFunction<StillVideoEncodeNative, StillVideoEncodeDart>(
        'eclipsa_studio_still_video_encode',
      );

  // ── Offline mix renderer ─────────────────────────────────────────

  late final mixRendererCreate = lib
      .lookupFunction<MixRendererCreateNative, MixRendererCreateDart>(
        'eclipsa_studio_mix_renderer_create',
      );

  late final mixRendererAddElement = lib
      .lookupFunction<MixRendererAddElementNative, MixRendererAddElementDart>(
        'eclipsa_studio_mix_renderer_add_element',
      );

  late final mixRendererSetObjectPosition = lib
      .lookupFunction<
        MixRendererSetObjectPositionNative,
        MixRendererSetObjectPositionDart
      >('eclipsa_studio_mix_renderer_set_object_position');

  late final mixRendererSetOutputGain = lib
      .lookupFunction<
        MixRendererSetOutputGainNative,
        MixRendererSetOutputGainDart
      >('eclipsa_studio_mix_renderer_set_output_gain');

  late final mixRendererMeasure = lib
      .lookupFunction<MixRendererMeasureNative, MixRendererMeasureDart>(
        'eclipsa_studio_mix_renderer_measure',
      );

  late final mixRendererTraceLen = lib
      .lookupFunction<MixRendererTraceLenNative, MixRendererTraceLenDart>(
        'eclipsa_studio_mix_renderer_trace_len',
      );

  late final mixRendererCopyTrace = lib
      .lookupFunction<MixRendererCopyTraceNative, MixRendererCopyTraceDart>(
        'eclipsa_studio_mix_renderer_copy_trace',
      );

  late final mixRendererLoudnessRange = lib
      .lookupFunction<
        MixRendererLoudnessRangeNative,
        MixRendererLoudnessRangeDart
      >('eclipsa_studio_mix_renderer_loudness_range');

  late final mixRendererElementClipStats = lib
      .lookupFunction<
        MixRendererElementClipStatsNative,
        MixRendererElementClipStatsDart
      >('eclipsa_studio_mix_renderer_element_clip_stats');

  late final mixRendererDestroy = lib
      .lookupFunction<MixRendererDestroyNative, MixRendererDestroyDart>(
        'eclipsa_studio_mix_renderer_destroy',
      );

  // ── Waveform peaks ───────────────────────────────────────────────

  late final peaksCompute = lib
      .lookupFunction<PeaksComputeNative, PeaksComputeDart>(
        'eclipsa_studio_peaks_compute',
      );

  late final peaksFree = lib.lookupFunction<PeaksFreeNative, PeaksFreeDart>(
    'eclipsa_studio_peaks_free',
  );

  late final peaksLevelData = lib
      .lookupFunction<PeaksLevelDataNative, PeaksLevelDataDart>(
        'eclipsa_studio_peaks_level_data',
      );

  // ── IAMF probe ───────────────────────────────────────────────────

  late final iamfProbe = lib.lookupFunction<IamfProbeNative, IamfProbeDart>(
    'eclipsa_studio_iamf_probe',
  );

  late final iamfProbeFree = lib
      .lookupFunction<IamfProbeFreeNative, IamfProbeFreeDart>(
        'eclipsa_studio_iamf_probe_free',
      );

  late final iamfProbeJson = lib
      .lookupFunction<IamfProbeJsonNative, IamfProbeJsonDart>(
        'eclipsa_studio_iamf_probe_json',
      );

  late final iamfProbeJsonFree = lib
      .lookupFunction<IamfProbeJsonFreeNative, IamfProbeJsonFreeDart>(
        'eclipsa_studio_iamf_probe_json_free',
      );

  // ── Video decode ─────────────────────────────────────────────────

  late final videoOpen = lib.lookupFunction<VideoOpenNative, VideoOpenDart>(
    'eclipsa_studio_video_open',
  );

  late final videoInfo = lib.lookupFunction<VideoInfoNative, VideoInfoDart>(
    'eclipsa_studio_video_info',
  );

  late final videoFrameAtSeconds = lib
      .lookupFunction<VideoFrameAtNative, VideoFrameAtDart>(
        'eclipsa_studio_video_frame_at_seconds',
      );

  late final videoFrameAtSecondsPixbuf = lib
      .lookupFunction<VideoFrameAtPixbufNative, VideoFrameAtPixbufDart>(
        'eclipsa_studio_video_frame_at_seconds_pixbuf',
      );

  late final videoReleasePixbuf = lib
      .lookupFunction<VideoReleasePixbufNative, VideoReleasePixbufDart>(
        'eclipsa_studio_video_release_pixbuf',
      );

  late final videoClose = lib.lookupFunction<VideoCloseNative, VideoCloseDart>(
    'eclipsa_studio_video_close',
  );

  // ── ADM import ───────────────────────────────────────────────────

  late final admProbeJson = lib
      .lookupFunction<AdmProbeJsonNative, AdmProbeJsonDart>(
        'adm2iamf_probe_json',
      );

  late final admStringFree = lib
      .lookupFunction<AdmStringFreeNative, AdmStringFreeDart>(
        'adm2iamf_string_free',
      );

  late final admRenderStart = lib
      .lookupFunction<AdmRenderStartNative, AdmRenderStartDart>(
        'adm2iamf_render_start',
      );

  late final admRenderProgress = lib
      .lookupFunction<AdmRenderProgressNative, AdmRenderProgressDart>(
        'adm2iamf_render_progress',
      );

  late final admRenderState = lib
      .lookupFunction<AdmRenderStateNative, AdmRenderStateDart>(
        'adm2iamf_render_state',
      );

  late final admRenderResultJson = lib
      .lookupFunction<AdmRenderResultJsonNative, AdmRenderResultJsonDart>(
        'adm2iamf_render_result_json',
      );

  late final admRenderCancel = lib
      .lookupFunction<AdmRenderCancelNative, AdmRenderCancelDart>(
        'adm2iamf_render_cancel',
      );

  late final admShutdown = lib
      .lookupFunction<AdmShutdownNative, AdmShutdownDart>('adm2iamf_shutdown');

  late final admVersion = lib.lookupFunction<AdmVersionNative, AdmVersionDart>(
    'adm2iamf_version',
  );
}
