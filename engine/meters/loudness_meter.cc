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

#include "meters/loudness_meter.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "engine_log.h"
#include "include/ebur128_analyzer.h"
#include "meters/bs1770_weights.h"

LoudnessMeter::LoudnessMeter(uint32_t sample_rate, uint32_t num_channels,
                             uint32_t layout)
    : sample_rate_(sample_rate), num_channels_(num_channels), layout_(layout) {
  rebuild_analyzer();
}

LoudnessMeter::~LoudnessMeter() = default;

void LoudnessMeter::set_sample_rate(uint32_t sample_rate) {
  sample_rate_ = sample_rate;
  rebuild_analyzer();
}

void LoudnessMeter::reconfigure(uint32_t num_channels, uint32_t layout) {
  num_channels_ = num_channels;
  layout_ = layout;
  rebuild_analyzer();
}

void LoudnessMeter::rebuild_analyzer() {
  // BS.1770 per-channel weights match iamf-tools' per-layout tables (see
  // meters/bs1770_weights.cc). If the layout's weight count doesn't match
  // num_channels_ (unknown layout or caller mismatch), fall back to uniform
  // 1.0 weights and warn.
  std::vector<float> weights = eclipsa_studio::Bs1770WeightsForLayout(layout_);
  if (weights.size() != num_channels_) {
    if (layout_ != 0) {
      char buf[160];
      snprintf(buf, sizeof(buf),
               "No BS.1770 weights for layout=%u (channels=%u, table=%zu); "
               "using uniform 1.0",
               layout_, num_channels_, weights.size());
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "meters", buf);
    }
    weights.assign(num_channels_, 1.0f);
  }

  analyzer_ = std::make_unique<loudness::EbuR128Analyzer>(
      static_cast<int32_t>(num_channels_), weights,
      static_cast<int32_t>(sample_rate_),
      /*enable_true_peak_measurement=*/true);

  // Size the scratch here, on the control thread, so the wrapper does not
  // allocate in process() on the audio thread: one flat planar buffer of
  // kMaxBlockFrames per channel, and a pointer table that points at each
  // channel's plane and does not change until the next rebuild. (The
  // EbuR128Analyzer itself still appends to its per-block history vectors
  // as blocks complete.)
  planar_.assign(static_cast<size_t>(num_channels_) * kMaxBlockFrames, 0.0);
  channel_ptrs_.resize(num_channels_);
  for (uint32_t c = 0; c < num_channels_; ++c) {
    channel_ptrs_[c] =
        planar_.data() + static_cast<size_t>(c) * kMaxBlockFrames;
  }
  mismatch_logged_ = false;
}

void LoudnessMeter::process(const AudioBuffer& buffer, uint32_t frames,
                            EclipsaStudioMeterState& state) {
  if (!analyzer_ || frames == 0 || num_channels_ == 0) return;

  // The analyzer walks exactly num_channels_ channel pointers. A buffer
  // with a different channel count (the renderer's channel count changed
  // and the meter has not been reconfigured for it) must not reach it: a
  // narrower buffer would make the analyzer read past the pointer table.
  // Skip the block, count it, and log the first skip per configuration.
  if (buffer.channels != num_channels_) {
    mismatched_blocks_.fetch_add(1, std::memory_order_relaxed);
    if (!mismatch_logged_) {
      mismatch_logged_ = true;
      char buf[128];
      snprintf(buf, sizeof(buf),
               "loudness meter: skipping %u-channel blocks, configured for "
               "%u channels (layout=%u)",
               buffer.channels, num_channels_, layout_);
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "meters", buf);
    }
    return;
  }

  // Feed the analyzer in chunks of at most kMaxBlockFrames, the capacity of
  // each plane. AudioGraph clamps its blocks to kGraphMaxFrames (4096), so
  // the engine always takes a single chunk.
  for (uint32_t offset = 0; offset < frames; offset += kMaxBlockFrames) {
    const uint32_t n = std::min(kMaxBlockFrames, frames - offset);
    // Convert float planar to double planar for the analyzer.
    for (uint32_t c = 0; c < num_channels_; ++c) {
      const float* src = buffer.channel(c) + offset;
      // channel_ptrs_ is the single source for each plane's offset, set
      // in rebuild_analyzer(); write through it so the converted samples
      // land where the analyzer reads them.
      double* dst = channel_ptrs_[c];
      for (uint32_t f = 0; f < n; ++f) dst[f] = static_cast<double>(src[f]);
    }
    // PLANAR_NON_CONTIGUOUS takes an array of num_channels_ channel
    // pointers, each pointing at `n` samples.
    analyzer_->Process(channel_ptrs_.data(), static_cast<int64_t>(n),
                       loudness::EbuR128Analyzer::DOUBLE,
                       loudness::EbuR128Analyzer::PLANAR_NON_CONTIGUOUS);
  }

  update_state(state);
}

void LoudnessMeter::update_state(EclipsaStudioMeterState& state) const {
  auto& l = state.loudness;

  // ── SPEC values (go into IAMF LoudnessInfo OBU at export time) ────────────

  // Integrated loudness: valid once at least one 400 ms block is accumulated.
  const auto integrated = analyzer_->GetRelativeGatedIntegratedLoudness();
  l.lufs_integrated =
      integrated.has_value() ? static_cast<float>(integrated.value()) : -120.0f;

  // True peak (dBFS, intersample peak, 4x upsampled).
  l.true_peak = static_cast<float>(analyzer_->true_peak_dbfs());

  // ── INFORMATIONAL values (live display only, not embedded in IAMF) ─────────

  // Momentary: latest ungated 400 ms block (LKFS ≈ LUFS for monitoring).
  const auto& mom = analyzer_->ungated_momentary_lkfs();
  l.lufs_momentary = mom.empty() ? -120.0f : static_cast<float>(mom.back());

  // Short-term: latest ungated 3 s block.
  const auto& st = analyzer_->ungated_short_term_lkfs();
  l.lufs_short_term = st.empty() ? -120.0f : static_cast<float>(st.back());
}

void LoudnessMeter::reset() { rebuild_analyzer(); }
