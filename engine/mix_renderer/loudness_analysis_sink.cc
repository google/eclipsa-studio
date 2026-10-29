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

#include "mix_renderer/loudness_analysis_sink.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "engine_log.h"
#include "meters/bs1770_weights.h"

namespace eclipsa_studio {

LoudnessAnalysisSink::LoudnessAnalysisSink() = default;

LoudnessAnalysisSink::~LoudnessAnalysisSink() = default;

void LoudnessAnalysisSink::Reset() {
  analyzer_.reset();
  limiter_gr_db_.clear();
  measured_ = false;
  digital_peak_linear_ = 0.0f;
  gr_bucket_max_ = 0.0f;
  frames_done_ = 0;
  out_done_ = 0;
  out_end_ = 0;
}

bool LoudnessAnalysisSink::Begin(OarRenderer* oar, uint32_t sample_rate,
                                 uint32_t buffer_size, uint32_t layout,
                                 uint64_t program_frames) {
  Reset();
  oar_ = oar;
  sample_rate_ = sample_rate;
  buffer_size_ = buffer_size;
  out_ch_ = oar->channel_count();
  if (out_ch_ == 0) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "OAR reports 0 output channels");
    return false;
  }

  // Channel weights mirror iamf-tools' BS.1770 per-layout tables
  // (meters/bs1770_weights.cc). If the layout isn't in the table or the
  // channel count disagrees with the renderer, fall back to uniform 1.0
  // and warn — the measurement will then not match BS.1770-5 for layouts
  // above stereo.
  std::vector<float> weights = Bs1770WeightsForLayout(layout);
  if (weights.size() != out_ch_) {
    char buf[160];
    snprintf(buf, sizeof(buf),
             "No BS.1770 weights for layout=%u (out_ch=%u, table=%zu); "
             "using uniform 1.0 — result will not match broadcast tools",
             layout, out_ch_, weights.size());
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "mix_renderer", buf);
    weights.assign(out_ch_, 1.0f);
  }
  analyzer_ = std::make_unique<loudness::EbuR128Analyzer>(
      static_cast<int32_t>(out_ch_), weights, static_cast<int32_t>(sample_rate),
      /*enable_true_peak_measurement=*/true);

  double_buf_.assign(out_ch_, std::vector<double>(buffer_size, 0.0));
  ch_ptrs_.resize(out_ch_);
  for (uint32_t ch = 0; ch < out_ch_; ++ch) {
    ch_ptrs_[ch] = double_buf_[ch].data();
  }

  // The limiter delays its output by `delay` frames (5 ms); see the
  // class comment for how the pass is extended past the program.
  delay_ = oar->limiter_delay();
  out_end_ = program_frames > 0 ? program_frames + delay_ : 0;

  // Limiter GR trace bookkeeping: one entry per kTraceStepMs, the max
  // gain reduction sampled at the end of each rendered block. Callers
  // reject sample rates below 8000 Hz up front; below 10 Hz this step
  // would truncate to zero frames and the bucket loop in Consume() would
  // never terminate.
  step_frames_ = uint64_t{sample_rate} * kTraceStepMs / 1000;
  return true;
}

void LoudnessAnalysisSink::Consume(const float* rendered) {
  const uint32_t bs = buffer_size_;

  // The block covers output frames [out_done, out_done + bs); the
  // program-aligned part is [lo, hi).
  const uint64_t lo = std::max(out_done_, delay_);
  const uint64_t hi = std::min(out_done_ + bs, out_end_);
  const uint32_t count = hi > lo ? static_cast<uint32_t>(hi - lo) : 0;

  // Blocks wholly inside the priming window carry no program frames.
  // Skipping them also keeps `first` below `bs`: with a delay longer
  // than the block, lo - out_done would point past the channel.
  if (count > 0) {
    const uint32_t first = static_cast<uint32_t>(lo - out_done_);

    // Track digital peak (sample peak, no upsampling). The rendered
    // output is planar with stride `bs` (the render call always uses the
    // full block size); only frames [first, first + count) of each
    // channel are program material.
    for (uint32_t ch = 0; ch < out_ch_; ++ch) {
      const float* ch_data = rendered + ch * bs + first;
      for (uint32_t f = 0; f < count; ++f) {
        const float abs_val = std::fabs(ch_data[f]);
        if (abs_val > digital_peak_linear_) {
          digital_peak_linear_ = abs_val;
        }
      }
    }

    // Convert float → double for loudness analyzer.
    for (uint32_t ch = 0; ch < out_ch_; ++ch) {
      const float* ch_data = rendered + ch * bs + first;
      for (uint32_t f = 0; f < count; ++f) {
        double_buf_[ch][f] = static_cast<double>(ch_data[f]);
      }
    }
    analyzer_->Process(ch_ptrs_.data(), static_cast<int64_t>(count),
                       loudness::EbuR128Analyzer::DOUBLE,
                       loudness::EbuR128Analyzer::PLANAR_NON_CONTIGUOUS);
    if (program_tap_) program_tap_(rendered, bs, first, count);
  }

  // Sample the limiter envelope at block end and fold it into the
  // 100 ms GR trace. gr_bucket_max carries across blocks that span a
  // bucket boundary; the current sample seeds the next bucket so the
  // release tail stays visible. Calling snapshot here is legal: the
  // caller's loop IS the render thread of this offline OAR instance. On
  // the final block the render runs up to `bs - 1` frames past the
  // program end, so the last bucket's sample includes up to ~21 ms of
  // release over that padding. Blocks inside the priming window fold
  // their look-ahead attack into the first bucket.
  oar_->snapshot_limiter_env();
  const double env = oar_->limiter_env();
  const float gr_db = (env > 0.0 && env < 1.0)
                          ? static_cast<float>(-20.0 * std::log10(env))
                          : 0.0f;
  gr_bucket_max_ = std::max(gr_bucket_max_, gr_db);
  frames_done_ += count;
  while (frames_done_ >= (limiter_gr_db_.size() + 1) * step_frames_) {
    limiter_gr_db_.push_back(gr_bucket_max_);
    gr_bucket_max_ = gr_db;
  }

  out_done_ += bs;
}

LoudnessResult LoudnessAnalysisSink::Finish() {
  // Flush the trailing partial bucket so the series covers
  // ceil(program/step) entries.
  if (frames_done_ % step_frames_ != 0) {
    limiter_gr_db_.push_back(gr_bucket_max_);
  }

  LoudnessResult result;
  const auto integrated = analyzer_->GetRelativeGatedIntegratedLoudness();
  result.integrated_lufs =
      integrated.has_value() ? static_cast<float>(integrated.value()) : -120.0f;
  result.true_peak_dbtp = static_cast<float>(analyzer_->true_peak_dbfs());
  result.digital_peak_dbfs = (digital_peak_linear_ > 0.0f)
                                 ? 20.0f * std::log10(digital_peak_linear_)
                                 : -120.0f;
  measured_ = true;
  return result;
}

// ── Post-measurement traces ─────────────────────────────────────────────

namespace {

// The analyzer stores short-term peaks as linear magnitudes; every other
// series is already in dB. Convert on the way out so all series reach
// the caller in dB.
float LinearToDbfs(float v) {
  return (v > 0.0f) ? 20.0f * std::log10(v) : -120.0f;
}

const std::vector<float>* SeriesFor(const loudness::EbuR128Analyzer& a,
                                    uint32_t series) {
  switch (series) {
    case kTraceMomentaryLufs:
      return &a.ungated_momentary_lkfs();
    case kTraceShortTermLufs:
      return &a.ungated_short_term_lkfs();
    case kTraceShortTermPeakDbfs:
      return &a.short_term_peaks();
    case kTraceShortTermPsrDb:
      return &a.short_term_psr();
    default:
      return nullptr;
  }
}

}  // namespace

uint32_t LoudnessAnalysisSink::TraceLength(uint32_t series) const {
  if (!measured_) return 0;
  if (series == kTraceLimiterGrDb) {
    return static_cast<uint32_t>(limiter_gr_db_.size());
  }
  const auto* values = SeriesFor(*analyzer_, series);
  return values ? static_cast<uint32_t>(values->size()) : 0;
}

uint32_t LoudnessAnalysisSink::CopyTrace(uint32_t series, float* out,
                                         uint32_t cap) const {
  if (!measured_ || out == nullptr) return 0;
  if (series == kTraceLimiterGrDb) {
    const uint32_t n =
        std::min(cap, static_cast<uint32_t>(limiter_gr_db_.size()));
    std::copy_n(limiter_gr_db_.begin(), n, out);
    return n;
  }
  const auto* values = SeriesFor(*analyzer_, series);
  if (values == nullptr) return 0;
  const uint32_t n = std::min(cap, static_cast<uint32_t>(values->size()));
  const bool linear = series == kTraceShortTermPeakDbfs;
  for (uint32_t i = 0; i < n; ++i) {
    const float v = linear ? LinearToDbfs((*values)[i]) : (*values)[i];
    // The analyzer emits non-finite entries over digital silence (NaN
    // momentary in a padded silence tail, +inf PSR over leading
    // silence). Clamp to the -120 floor so the copied series is always
    // finite: <= -120 uniformly means silence / no data.
    out[i] = std::isfinite(v) ? v : -120.0f;
  }
  return n;
}

bool LoudnessAnalysisSink::GetLoudnessRange(float* lra_lu,
                                            bool* is_stable) const {
  if (!measured_) return false;
  bool stable = false;
  const auto stats = analyzer_->GetLoudnessRangeStats(&stable);
  if (!stats.has_value()) return false;
  if (lra_lu) *lra_lu = stats->loudness_range_lu;
  if (is_stable) *is_stable = stable;
  return true;
}

}  // namespace eclipsa_studio
