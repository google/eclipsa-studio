/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef ECLIPSA_STUDIO_IAMF_PROBE_FFI_H_
#define ECLIPSA_STUDIO_IAMF_PROBE_FFI_H_

// FFI shim around iamf_tools::Probe() for the Playback inspector tab.
// Mirrored by app/lib/playback/iamf_probe.dart.
//
// The per-AE `renderable` flag is the engine's authoritative judgement
// (issue ES-330): upstream's decode
// capability (iamf_tools::api::DescriptorFromProbeReport) ANDed with
// the OAR capability mapping (renderer/oar_capability.h) — the same
// mapping `eclipsa_studio_playback_open` registers through, so the probe's
// verdict and what actually renders cannot drift apart. The app must
// not re-derive renderability from layout labels.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Why an AE is not renderable. Mirrored by the Dart-side skip-reason
// mapping in app/lib/playback/iamf_probe.dart.
typedef enum {
  ECLIPSA_STUDIO_AE_RENDERABLE = 0,
  // This build's decode pipeline can't decode the AE (recon-gain
  // layers, projection-mode ambisonics, reserved layout, ...).
  ECLIPSA_STUDIO_AE_SKIP_NOT_DECODABLE = 1,
  // Decodable, but OAR has no element sub-renderer for the shape.
  ECLIPSA_STUDIO_AE_SKIP_LAYOUT_NOT_RENDERABLE = 2,
  // Object-based AEs have no graph feed path yet.
  ECLIPSA_STUDIO_AE_SKIP_OBJECT_BASED = 3,
  // Reserved / future-spec audio element type.
  ECLIPSA_STUDIO_AE_SKIP_UNKNOWN_TYPE = 4,
} EclipsaStudioAeSkipReason;

// Audio-element descriptor. `layout_label` is the loudspeaker-layout
// string from the probe ("Stereo", "5.1.4", "Expanded", or the expanded
// layout name when top-level layout is "Expanded"); NULL for AEs that
// carry no scalable channel layer. `ambisonics_order` is the scene-
// based ambisonics order derived from the output channel count, or -1
// for non-scene AEs.
typedef struct {
  uint32_t audio_element_id;
  int32_t type;              // 0=channel, 1=scene, 2=object, -1=unknown
  uint32_t num_channels;     // decoded channel count; 0 when unknown
  int32_t ambisonics_order;  // -1 if not scene-based
  const char* layout_label;  // heap-owned; nullable
  int32_t renderable;        // 1 = decodable AND OAR-renderable
  int32_t skip_reason;       // EclipsaStudioAeSkipReason; 0 when renderable
} EclipsaStudioIamfAe;

// Per-AE default mix-gain entry inside a mix presentation. The gain is
// the default value of `element_mix_gain` as carried in the Mix
// Presentation OBU — in dB, already unpacked from Q7.8. At runtime the
// stream's per-TU mix gain overrides this, but the default is what
// AudioGraph seeds into the chain's slewed gain when the active mix
// presentation changes.
typedef struct {
  uint32_t audio_element_id;
  float default_mix_gain_db;
} EclipsaStudioIamfMixElement;

// Mix-presentation descriptor. `name` / `language` come from the first
// annotation pair (nullable). Loudness values use NaN as the "not
// reported" sentinel so Dart can hide the field without a separate
// present-flag.
//
// Layout fields (`layout_type`, `sound_system`) and `elements` are
// derived from sub-mix[0] / layout[0]. IAMF allows multiple sub-mixes
// per mix presentation but OAR has a single output bus; this struct
// probe exposes the first sub-mix and the engine side logs a warning
// when `num_sub_mixes` > 1. Consumers that need every sub-mix (element
// sets, gains, output gains) get them via `eclipsa_studio_iamf_probe_json`,
// merged Dart-side by `enrichReportWithFullProbe` in
// app/lib/playback/iamf_probe.dart. `sound_system` is NULL for
// non-loudspeaker layouts (e.g. binaural, reserved).
typedef struct {
  uint32_t mix_presentation_id;
  const char* name;       // heap-owned; nullable
  const char* language;   // heap-owned; nullable
  double loudness_lufs;   // NaN when absent
  double true_peak_dbtp;  // NaN when absent

  uint32_t num_elements;
  const EclipsaStudioIamfMixElement* elements;  // heap-owned; NULL iff num==0
  const char* layout_type;                      // heap-owned; nullable
  const char* sound_system;                     // heap-owned; nullable
} EclipsaStudioIamfMixPresentation;

// Heap-allocated probe result. All pointers inside are owned by the
// enclosing result and valid until eclipsa_studio_iamf_probe_free() is called.
typedef struct {
  // 0 on success; negative on error. On error, `error_message` carries
  // a human-readable reason and the arrays are NULL / counts are 0.
  int32_t status;
  const char* error_message;  // heap-owned; NULL on success

  uint32_t sample_rate;    // from the first codec config; 0 if unknown
  uint64_t total_samples;  // descriptors-only total (FLAC STREAMINFO); 0
                           // when the codec carries no usable total

  uint32_t num_audio_elements;
  const EclipsaStudioIamfAe* audio_elements;

  uint32_t num_mix_presentations;
  const EclipsaStudioIamfMixPresentation* mix_presentations;
} EclipsaStudioIamfProbeResult;

// Parse descriptor OBUs (and the temporal-unit scan for duration) of
// the IAMF file at `path` and return a heap-allocated summary. Always
// returns non-NULL unless the top-level allocation itself failed.
// Inspect `status` / `error_message` to distinguish success from
// unreadable/malformed input.
//
// Caller must free the returned pointer with eclipsa_studio_iamf_probe_free().
EclipsaStudioIamfProbeResult* eclipsa_studio_iamf_probe(const char* path);

// Release a result returned by eclipsa_studio_iamf_probe, including nested
// string and array allocations. Safe to pass NULL.
void eclipsa_studio_iamf_probe_free(EclipsaStudioIamfProbeResult* result);

// Full descriptor-OBU dump as JSON, suitable for the Inspector view.
//
// Mirrors the JSON tree the iamf-inspector WASM wrapper emits
// (wasm/iamf_wasm_wrapper.cc): profile, codec configs (Opus / LPCM /
// AAC / FLAC), audio elements (scalable layers, ambisonics mono /
// projection, params), mix presentations (sub-mixes with rendering
// config, mix gains with param defs, layouts with full loudness +
// anchored loudness, tags). Temporal-unit scan is intentionally
// skipped — it walks the full file (~80 s on a 543 MB Opus IAMF)
// and would block the Inspector unacceptably; duration is sourced
// elsewhere from `IamfStreamInterface::GetTotalSamples`.
//
// Returns a heap-allocated NUL-terminated JSON string on success
// (caller frees with `eclipsa_studio_iamf_probe_json_free`). On failure
// returns a NUL-terminated JSON of the form
// `{"ok":false,"error":"..."}`. Returns NULL only when the top-level
// allocation itself failed.
char* eclipsa_studio_iamf_probe_json(const char* path);

// Release a string returned by eclipsa_studio_iamf_probe_json. Safe to pass
// NULL.
void eclipsa_studio_iamf_probe_json_free(char* json);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ECLIPSA_STUDIO_IAMF_PROBE_FFI_H_
