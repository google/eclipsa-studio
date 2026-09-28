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

#ifndef ECLIPSA_STUDIO_METERS_CHANNEL_STATS_H_
#define ECLIPSA_STUDIO_METERS_CHANNEL_STATS_H_

#include <atomic>
#include <cstdint>

#include "graph/audio_buffer.h"
#include "meters/meter_state.h"

/// Per-element channel statistics computed each audio callback.
///
/// Produces the fields in EclipsaStudioMeterData.stats_* — the inputs to the
/// visualizer framework. Held once per ElementChain; allocated on the
/// control thread; process() runs on the audio thread and never allocates.
///
/// Fields computed per call:
///   - stats_energy[c]  short-window linear power (one-pole EMA of x^2)
///   - stats_onset[c]   fast/slow EMA ratio crossed kOnsetRatio recently
///   - stats_coh_{lo,mid,hi}[c]  |γ|² against the element sum in each band
///   - stats_corr[]     upper-triangular Pearson correlation between every
///                      pair up to kStatsCorrMaxChannels
///
/// The class holds internal EMA state between calls; its lifetime spans
/// the whole ElementChain.
class ChannelStats {
 public:
  ChannelStats();

  /// Rebuild internal state for a new sample rate. Control thread only;
  /// must not be called while the audio thread is mid-process.
  void set_sample_rate(uint32_t sample_rate);

  /// Run one process block. Writes stats fields into the element's
  /// MeterData slot. `buffer` is the same post-DSP element buffer the
  /// peak/rms meters read from.
  void process(const AudioBuffer& buffer, uint32_t frames,
               EclipsaStudioMeterState& state, uint32_t element_index);

  /// Reset internal state (used on seek / meter reset).
  void reset();

 private:
  // ── EMA tunables ───────────────────────────────────────────────────
  // Relaxed atomics so control-thread writes (via set_sample_rate) are
  // well-defined per the C++ memory model. No ordering requirement —
  // the audio thread only needs to see "some valid value."
  std::atomic<float> alpha_energy_{0.0f};
  std::atomic<float> alpha_onset_fast_{0.0f};
  std::atomic<float> alpha_onset_slow_{0.0f};
  std::atomic<float> alpha_coh_{0.0f};
  uint32_t sample_rate_ = 48000;

  // ── Per-channel state ──────────────────────────────────────────────
  float energy_[kEclipsaStudioMaxChannelsPerElement] = {};  // E[x^2]
  float onset_fast_[kEclipsaStudioMaxChannelsPerElement] = {};
  float onset_slow_[kEclipsaStudioMaxChannelsPerElement] = {};
  uint32_t onset_hold_[kEclipsaStudioMaxChannelsPerElement] =
      {};  // samples left

  // Per-channel 3-band state: one biquad section per band edge forms
  // 2nd-order Butterworth crossovers. Lo = LP(fc_lo), hi = HP(fc_hi),
  // mid = band between them. Persistent biquad history across blocks.
  struct Biquad {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    float z1 = 0.0f, z2 = 0.0f;
    float process(float x) {
      const float y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
    void reset() { z1 = z2 = 0; }
  };
  Biquad lp_[kEclipsaStudioMaxChannelsPerElement] = {};
  Biquad hp_[kEclipsaStudioMaxChannelsPerElement] = {};
  // Reference (sum) biquad state.
  Biquad lp_sum_ = {};
  Biquad hp_sum_ = {};

  // Band cross-spectral accumulators against the element sum for coherence
  // γ² = |E[X·S*]|² / (E[|X|²]·E[|S|²]). Real signals — cross term is E[X·S].
  float cxs_lo_[kEclipsaStudioMaxChannelsPerElement] = {};
  float cxs_mid_[kEclipsaStudioMaxChannelsPerElement] = {};
  float cxs_hi_[kEclipsaStudioMaxChannelsPerElement] = {};
  float exx_lo_[kEclipsaStudioMaxChannelsPerElement] = {};
  float exx_mid_[kEclipsaStudioMaxChannelsPerElement] = {};
  float exx_hi_[kEclipsaStudioMaxChannelsPerElement] = {};
  float ess_lo_ = 0, ess_mid_ = 0, ess_hi_ = 0;

  // Correlation cross-term EMAs — upper triangular packed layout
  // matching EclipsaStudioMeterData.stats_corr indices. The denominator
  // reuses energy_ (the same aE-smoothed E[x^2]).
  float exy_[kStatsCorrPairs] = {};

  // Cached corner frequencies used by set_sample_rate to update biquads.
  float fc_lo_hz_ = 250.0f;
  float fc_hi_hz_ = 4000.0f;

  void recompute_alphas();
  void recompute_biquads();
};

#endif  // ECLIPSA_STUDIO_METERS_CHANNEL_STATS_H_
