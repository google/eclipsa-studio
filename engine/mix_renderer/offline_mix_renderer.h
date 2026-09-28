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

#ifndef ECLIPSA_STUDIO_MIX_RENDERER_OFFLINE_MIX_RENDERER_H_
#define ECLIPSA_STUDIO_MIX_RENDERER_OFFLINE_MIX_RENDERER_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

#include "bounce/element_stream.h"
#include "renderer/oar_renderer.h"

namespace eclipsa_studio {

/// Result of an offline loudness measurement.
struct LoudnessResult {
  float integrated_lufs = -120.0f;    ///< BS.1770-4 integrated (LUFS)
  float true_peak_dbtp = -120.0f;     ///< True peak, 4x upsampled (dBTP)
  float digital_peak_dbfs = -120.0f;  ///< Sample peak, no upsampling (dBFS)
};

/// Time-series identifiers for post-measurement trace access. Values are
/// part of the C ABI (eclipsa_studio_mix_renderer_copy_trace) — do not
/// renumber. Every series steps at [OfflineMixRenderer::kTraceStepMs]. The
/// analyzer series (0-3) have fewer entries than program-length/step because
/// their first entry lands only once the analysis window fills (400 ms
/// momentary, 3 s the rest); the limiter GR series has no warmup window
/// and runs from t=0 for ceil(program/step) entries.
enum MixTraceSeries : uint8_t {
  kTraceMomentaryLufs = 0,      ///< 400 ms window, ungated (LUFS)
  kTraceShortTermLufs = 1,      ///< 3 s sliding window, ungated (LUFS)
  kTraceShortTermPeakDbfs = 2,  ///< Max sample peak per 3 s window (dBFS)
  kTraceShortTermPsrDb = 3,     ///< Peak minus short-term loudness (dB)
  /// Limiter envelope sampled once per render block (its end-of-block
  /// value), converted to gain reduction (dB, >= 0) and max-reduced
  /// per 100 ms step. Sustained limiting reads accurately; isolated
  /// transients are understated, because each step sees only a few
  /// point samples of the 50 ms-release envelope — resolution is
  /// bounded by the render block size (exact per-sample tracking is
  /// ES-541). An entry > 0 means the unlimited render — what the
  /// exported file ships — exceeds -1 dBFS at or shortly after an
  /// engagement near that step (the release tail smears into the
  /// following steps). NO warmup window: entries from t=0, length =
  /// ceil(program/step), unlike the analyzer series above.
  kTraceLimiterGrDb = 4,
};

/// Per-element configuration for a mix render.
struct MixElementConfig {
  uint32_t element_id = 0;

  /// Source WAV plus the same pre-gain / routing / pad / rate inputs the
  /// IAMF push export takes — the render streams straight from the
  /// session source, no pre-bounced intermediate.
  ElementStream::Config stream;

  int element_type = 0;      ///< 0=channel, 1=scene, 2=object
  int element_sub_type = 0;  ///< oar_layout_t | oar_hoa_t | num_objects

  /// Declared post-routing channel count. OAR registration needs it at
  /// AddElement() time, before any stream opens; RenderAndMeasure()
  /// fails if the opened stream delivers a different count.
  uint32_t channels = 0;
  float mix_gain_db = 0.0f;
  uint32_t headphones_mode =
      1;  ///< 0=stereo, 1=binaural_world, 2=binaural_head
  uint32_t binaural_profile = 0;  ///< 0=ambient, 1=direct, 2=reverberant

  /// Object-based only: polar position per object (index 1 used when
  /// num_objects == 2). REQUIRED for objects to be audible on
  /// loudspeaker layouts — OAR's object-to-loudspeaker renderer stays
  /// silent until positions arrive, so an unpositioned object would
  /// measure as silence. Set via SetObjectPosition().
  uint32_t num_objects = 1;
  float azimuth_deg[2] = {0.0f, 0.0f};
  float elevation_deg[2] = {0.0f, 0.0f};
  float distance[2] = {1.0f, 1.0f};
};

/// Renders a mix presentation at a specific output layout and measures
/// loudness. Uses OarRenderer for spatial rendering and
/// loudness_ebur128 for BS.1770-4 measurement.
///
/// Each instance is standalone (no dependency on the real-time
/// AudioGraph or audio thread). Multiple instances can run
/// concurrently on different threads — pinned by
/// test/offline_mix_concurrency_test.cc under the TSan/ASan CI
/// sweeps. The one forbidden overlap is with the *live* renderer: an
/// offline pass runs only while the audio thread has acknowledged
/// leaving OAR, and the live renderer stays out for the whole pass,
/// because concurrent live and offline use corrupted the heap (ES-44).
///
/// Usage:
///   OfflineMixRenderer r;
///   r.Init(48000, 1024, 8 /* 7.1.4 */);
///   r.AddElement({...});
///   r.SetOutputMixGain(-3.0f);
///   auto result = r.RenderAndMeasure();
class OfflineMixRenderer {
 public:
  OfflineMixRenderer();
  ~OfflineMixRenderer();

  OfflineMixRenderer(const OfflineMixRenderer&) = delete;
  OfflineMixRenderer& operator=(const OfflineMixRenderer&) = delete;

  /// Initialize the renderer for a target layout.
  /// @param layout  oar_layout_t value (2=stereo, 8=7.1.4, 0xFF=binaural, etc.)
  bool Init(uint32_t sample_rate, uint32_t buffer_size, uint32_t layout);

  /// Add an element to the mix.
  bool AddElement(const MixElementConfig& config);

  /// Set an object element's polar position(s) after AddElement().
  /// Returns false for an unknown element id. `count` clamps to [1, 2];
  /// az/el/dist point at `count` values. See MixElementConfig for why
  /// this is required for object-based elements.
  bool SetObjectPosition(uint32_t element_id, uint32_t count,
                         const float* az_deg, const float* el_deg,
                         const float* dist);

  /// Set the output (master) mix gain in dB.
  void SetOutputMixGain(float gain_db);

  /// Run the full render and loudness measurement. Blocking.
  /// Opens an ElementStream per element (gain → routing → resample →
  /// pad, straight from the source WAV), pushes blocks through OAR,
  /// feeds output to the loudness meter, and returns the result.
  ///
  /// Returns nullopt on error (no elements, unreadable source,
  /// channel-count mismatch, renderer failure — specifics in the engine
  /// log). A failed measure must be distinguishable from a legitimately
  /// silent program, which measures -120 LUFS: the default-result
  /// convention this replaces let failures ship -120 into exported
  /// loudness metadata.
  std::optional<LoudnessResult> RenderAndMeasure();

  /// Step between consecutive trace entries, uniform across series.
  static constexpr uint32_t kTraceStepMs = 100;

  /// Number of recorded entries for a series. 0 before RenderAndMeasure()
  /// has succeeded, or for an unknown series id.
  uint32_t TraceLength(uint32_t series) const;

  /// Copy up to `cap` entries of a series into `out`. Returns the number
  /// of entries copied (0 before measurement / unknown series).
  uint32_t CopyTrace(uint32_t series, float* out, uint32_t cap) const;

  /// EBU TECH 3342 loudness range of the measured program. Returns false
  /// when unavailable (before measurement, or program too short for a
  /// short-term block). `is_stable` reflects EBU TECH 3341's "stable
  /// after 60 s" criterion; either out pointer may be null.
  bool GetLoudnessRange(float* lra_lu, bool* is_stable) const;

  /// Signal-overload stats for one element of the measured render,
  /// keyed by the element_id passed to AddElement(). Counted on the
  /// element's own stream output (gain/routing/resample applied) — the
  /// same PCM the IAMF export would encode — NOT on the rendered mix,
  /// so element overs are visible even though the mix output is
  /// limited. |x| strictly > 1.0 counts as clipped (see
  /// ElementStream::clipped_samples()). Returns false before a
  /// successful RenderAndMeasure() or for an unknown id; either out
  /// pointer may be null. Valid until the next measure/destroy, same
  /// contract as the traces.
  bool GetElementClipStats(uint32_t element_id, uint64_t* out_clipped_samples,
                           float* out_peak_linear) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_MIX_RENDERER_OFFLINE_MIX_RENDERER_H_
