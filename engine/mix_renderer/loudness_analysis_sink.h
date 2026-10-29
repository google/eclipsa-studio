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

#ifndef ECLIPSA_STUDIO_MIX_RENDERER_LOUDNESS_ANALYSIS_SINK_H_
#define ECLIPSA_STUDIO_MIX_RENDERER_LOUDNESS_ANALYSIS_SINK_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

#include "include/ebur128_analyzer.h"
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
/// renumber. Every series steps at [LoudnessAnalysisSink::kTraceStepMs].
/// The analyzer series (0-3) have fewer entries than program-length/step
/// because their first entry lands only once the analysis window fills
/// (400 ms momentary, 3 s the rest); the limiter GR series has no warmup
/// window and runs from t=0 for ceil(program/step) entries.
enum MixTraceSeries : uint8_t {
  kTraceMomentaryLufs = 0,      ///< 400 ms window, ungated (LUFS)
  kTraceShortTermLufs = 1,      ///< 3 s sliding window, ungated (LUFS)
  kTraceShortTermPeakDbfs = 2,  ///< Max sample peak per 3 s window (dBFS)
  kTraceShortTermPsrDb = 3,     ///< Peak minus short-term loudness (dB)
  /// Limiter envelope sampled once per render block (its end-of-block
  /// value), converted to gain reduction (dB, >= 0) and max-reduced
  /// per 100 ms step. Sustained limiting reads accurately; isolated
  /// transients are understated, because each step sees only a few
  /// point samples of the release envelope — resolution is bounded by
  /// the render block size (exact per-sample tracking is ES-541). An
  /// entry > 0 means the unlimited render — what the exported file
  /// ships — exceeds -1 dBFS at or shortly after an engagement near
  /// that step (the release tail smears into the following steps). NO
  /// warmup window: entries from t=0, length = ceil(program/step),
  /// unlike the analyzer series above.
  kTraceLimiterGrDb = 4,
};

/// The measurement half of an offline render: takes the blocks an
/// offline OarRenderer produces and turns them into the loudness result,
/// the trace series and the loudness range. Shared by every offline
/// measurement path (OfflineMixRenderer for session WAV sources, the
/// decoded-IAMF measurer for QC) so their numbers cannot drift.
///
/// The sink does not depend on the source of the element PCM. The
/// caller owns the OarRenderer, feeds it, calls render(), and hands each
/// rendered block to Consume(). The sink handles the limiter's delay:
/// output frame o carries program frame o - delay, and the first `delay`
/// output frames are zero priming, so the caller renders program + delay
/// frames in total, until has_more() returns false (feeding zeros once
/// the program is consumed), and the sink measures only output frames
/// [delay, delay + program), which puts every result on the program
/// timeline.
///
/// Not thread-safe; one instance per render pass. The rendering
/// OarRenderer must outlive Begin()..Finish(): Consume() samples its
/// limiter envelope, which is legal because the caller's loop is the
/// render thread of that offline instance.
class LoudnessAnalysisSink {
 public:
  /// Step between consecutive trace entries, uniform across series.
  static constexpr uint32_t kTraceStepMs = 100;

  LoudnessAnalysisSink();
  ~LoudnessAnalysisSink();

  LoudnessAnalysisSink(const LoudnessAnalysisSink&) = delete;
  LoudnessAnalysisSink& operator=(const LoudnessAnalysisSink&) = delete;

  /// Receives the program frames of each consumed block: frames
  /// [first, first + count) of every channel of `rendered`, which is
  /// planar with stride `stride`. Calls arrive in program order with
  /// `count` > 0, and their counts add up to the program length, so a
  /// tap that appends them gets the render on the program timeline
  /// with the limiter delay removed.
  using ProgramTap = std::function<void(const float* rendered, uint32_t stride,
                                        uint32_t first, uint32_t count)>;

  /// Set or clear (empty function) the tap Consume() calls. It stays set
  /// across Reset() and Begin().
  void SetProgramTap(ProgramTap tap) { program_tap_ = std::move(tap); }

  /// Drop the previous run's series, so the queries below return
  /// nothing until the next Finish(). Begin() calls this; a caller whose
  /// pass fails before Begin() calls it so a failed run never leaves the
  /// previous run's series readable.
  void Reset();

  /// Drop the previous run's series and prepare for a program of
  /// `program_frames` frames rendered by `oar` (already init()-ed for
  /// `layout` at `sample_rate`) in blocks of `buffer_size` frames.
  /// Builds the BS.1770 analyzer with the layout's channel weights
  /// (uniform 1.0 with a warning when the layout has no table). Returns
  /// false when the renderer reports 0 output channels; the caller then
  /// aborts its pass.
  bool Begin(OarRenderer* oar, uint32_t sample_rate, uint32_t buffer_size,
             uint32_t layout, uint64_t program_frames);

  /// Whether the pass still has blocks to render.
  bool has_more() const { return out_done_ < out_end_; }

  /// Consume one rendered block of `buffer_size` frames (planar, stride
  /// `buffer_size`, as OarRenderer::render() returns it). Tracks the
  /// digital peak, feeds the analyzer and folds the limiter envelope into
  /// the GR trace. Call once per render(), in order.
  void Consume(const float* rendered);

  /// Finish the pass after the last Consume(): flushes the trailing GR
  /// bucket and reads the result. The trace and range queries below are
  /// valid from here until the next Begin().
  LoudnessResult Finish();

  /// Number of recorded entries for a series. 0 before Finish() or for an
  /// unknown series id.
  uint32_t TraceLength(uint32_t series) const;

  /// Copy up to `cap` entries of a series into `out`, all in dB and
  /// finite (non-finite analyzer entries over silence clamp to -120).
  /// Returns the number of entries copied (0 before Finish() / unknown
  /// series).
  uint32_t CopyTrace(uint32_t series, float* out, uint32_t cap) const;

  /// EBU TECH 3342 loudness range of the measured program. Returns false
  /// when unavailable (before Finish(), or program too short for a
  /// short-term block). `is_stable` reflects EBU TECH 3341's "stable
  /// after 60 s" criterion; either out pointer may be null.
  bool GetLoudnessRange(float* lra_lu, bool* is_stable) const;

  /// True between a Finish() and the next Begin().
  bool measured() const { return measured_; }

 private:
  OarRenderer* oar_ = nullptr;
  uint32_t sample_rate_ = 48000;
  uint32_t buffer_size_ = 1024;
  uint32_t out_ch_ = 0;
  uint64_t delay_ = 0;
  uint64_t out_end_ = 0;
  uint64_t out_done_ = 0;
  uint64_t step_frames_ = 0;
  uint64_t frames_done_ = 0;
  float gr_bucket_max_ = 0.0f;
  float digital_peak_linear_ = 0.0f;

  // Kept alive after Finish() so the recorded time series
  // (momentary/short-term traces, LRA) stay queryable. Reset in Begin().
  std::unique_ptr<loudness::EbuR128Analyzer> analyzer_;
  // Double-precision scratch for the analyzer and the pointer table it
  // consumes, sized once in Begin().
  std::vector<std::vector<double>> double_buf_;
  std::vector<const double*> ch_ptrs_;
  // Limiter gain reduction (dB, >= 0) per kTraceStepMs step of the last
  // run — kTraceLimiterGrDb. The envelope is sampled once per render
  // block (its end-of-block value), so sustained limiting reads
  // accurately while isolated transients read low — resolution is
  // bounded by the render block size (ES-541).
  std::vector<float> limiter_gr_db_;
  ProgramTap program_tap_;
  bool measured_ = false;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_MIX_RENDERER_LOUDNESS_ANALYSIS_SINK_H_
