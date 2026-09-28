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

#include "meters/channel_stats.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

// Default EMA time constant — also the energy window, in milliseconds.
constexpr float kStatsTauMsDefault = 50.0f;

// Onset detection: ratio of fast-EMA|x| over slow-EMA|x| triggers an
// onset when it exceeds this, with a refractory/hold window in ms.
constexpr float kOnsetRatio = 2.2f;
constexpr float kOnsetHoldMs = 80.0f;
constexpr float kOnsetFastTauMs = 5.0f;
constexpr float kOnsetSlowTauMs = 150.0f;

// Coherence EMA — longer than energy for stability.
constexpr float kCohTauMs = 80.0f;

// Upper-triangular packed index for (i, j) with i<j and
// N = kStatsCorrMaxChannels.
inline uint32_t pair_index(uint32_t i, uint32_t j) {
  // idx = i*(2N-i-1)/2 + (j-i-1)
  const uint32_t n = kStatsCorrMaxChannels;
  return i * (2 * n - i - 1) / 2 + (j - i - 1);
}

constexpr float kPi = 3.14159265358979f;

// A single non-finite input sample would poison every EMA feedback
// accumulator permanently — NaN is sticky through `s += a*(x-s)` and
// passes std::clamp unchanged into UI-read shared memory. Sanitize at
// the read: treat non-finite input as silence.
inline float finite_or_zero(float x) { return std::isfinite(x) ? x : 0.0f; }

// One-pole EMA coefficient for a given tau in ms at the current sample
// rate. tau=0 → alpha=1 (no smoothing); tau=∞ → alpha=0 (frozen).
inline float alpha_from_tau(float tau_ms, uint32_t sr) {
  if (tau_ms <= 0.0f) return 1.0f;
  const float n = tau_ms * 1e-3f * static_cast<float>(sr);
  return 1.0f - std::exp(-1.0f / n);
}

// 2nd-order Butterworth LPF/HPF coefficients (cascaded to build LR4
// would be more ideal but Butterworth-2 is sufficient for visual
// coherence bands). Formulas from RBJ EQ cookbook.
void make_lpf(float fc, uint32_t sr, float& b0, float& b1, float& b2, float& a1,
              float& a2) {
  const float w0 = 2.0f * kPi * fc / static_cast<float>(sr);
  const float cs = std::cos(w0);
  const float sn = std::sin(w0);
  constexpr float q = 0.70710678f;  // Butterworth
  const float alpha = sn / (2.0f * q);
  const float a0 = 1.0f + alpha;
  b0 = (1.0f - cs) / 2.0f / a0;
  b1 = (1.0f - cs) / a0;
  b2 = (1.0f - cs) / 2.0f / a0;
  a1 = -2.0f * cs / a0;
  a2 = (1.0f - alpha) / a0;
}

void make_hpf(float fc, uint32_t sr, float& b0, float& b1, float& b2, float& a1,
              float& a2) {
  const float w0 = 2.0f * kPi * fc / static_cast<float>(sr);
  const float cs = std::cos(w0);
  const float sn = std::sin(w0);
  constexpr float q = 0.70710678f;
  const float alpha = sn / (2.0f * q);
  const float a0 = 1.0f + alpha;
  b0 = (1.0f + cs) / 2.0f / a0;
  b1 = -(1.0f + cs) / a0;
  b2 = (1.0f + cs) / 2.0f / a0;
  a1 = -2.0f * cs / a0;
  a2 = (1.0f - alpha) / a0;
}

}  // namespace

ChannelStats::ChannelStats() { set_sample_rate(sample_rate_); }

void ChannelStats::set_sample_rate(uint32_t sample_rate) {
  sample_rate_ = sample_rate == 0 ? 48000 : sample_rate;
  recompute_alphas();
  recompute_biquads();
}

void ChannelStats::recompute_alphas() {
  alpha_energy_.store(alpha_from_tau(kStatsTauMsDefault, sample_rate_),
                      std::memory_order_relaxed);
  alpha_onset_fast_.store(alpha_from_tau(kOnsetFastTauMs, sample_rate_),
                          std::memory_order_relaxed);
  alpha_onset_slow_.store(alpha_from_tau(kOnsetSlowTauMs, sample_rate_),
                          std::memory_order_relaxed);
  alpha_coh_.store(alpha_from_tau(kCohTauMs, sample_rate_),
                   std::memory_order_relaxed);
}

void ChannelStats::recompute_biquads() {
  float b0, b1, b2, a1, a2;
  make_lpf(fc_lo_hz_, sample_rate_, b0, b1, b2, a1, a2);
  for (auto& q : lp_) {
    q.b0 = b0;
    q.b1 = b1;
    q.b2 = b2;
    q.a1 = a1;
    q.a2 = a2;
    q.reset();
  }
  lp_sum_ = {b0, b1, b2, a1, a2, 0, 0};
  make_hpf(fc_hi_hz_, sample_rate_, b0, b1, b2, a1, a2);
  for (auto& q : hp_) {
    q.b0 = b0;
    q.b1 = b1;
    q.b2 = b2;
    q.a1 = a1;
    q.a2 = a2;
    q.reset();
  }
  hp_sum_ = {b0, b1, b2, a1, a2, 0, 0};
}

void ChannelStats::reset() {
  std::memset(energy_, 0, sizeof(energy_));
  std::memset(onset_fast_, 0, sizeof(onset_fast_));
  std::memset(onset_slow_, 0, sizeof(onset_slow_));
  std::memset(onset_hold_, 0, sizeof(onset_hold_));
  std::memset(cxs_lo_, 0, sizeof(cxs_lo_));
  std::memset(cxs_mid_, 0, sizeof(cxs_mid_));
  std::memset(cxs_hi_, 0, sizeof(cxs_hi_));
  std::memset(exx_lo_, 0, sizeof(exx_lo_));
  std::memset(exx_mid_, 0, sizeof(exx_mid_));
  std::memset(exx_hi_, 0, sizeof(exx_hi_));
  std::memset(exy_, 0, sizeof(exy_));
  ess_lo_ = ess_mid_ = ess_hi_ = 0;
  for (auto& q : lp_) q.reset();
  for (auto& q : hp_) q.reset();
  lp_sum_.reset();
  hp_sum_.reset();
}

void ChannelStats::process(const AudioBuffer& buffer, uint32_t frames,
                           EclipsaStudioMeterState& state,
                           uint32_t element_index) {
  if (element_index >= kEclipsaStudioMaxElements) return;
  auto& md = state.elements[element_index];
  const uint32_t n_ch =
      std::min<uint32_t>(buffer.channels, kEclipsaStudioMaxChannelsPerElement);
  const uint32_t fr = std::min(frames, buffer.frames);

  // Zero the stats output fields for inactive channel slots — prevents
  // stale values from showing up when channel count shrinks.
  for (uint32_t c = n_ch; c < kEclipsaStudioMaxChannelsPerElement; ++c) {
    md.stats_energy[c] = 0;
    md.stats_coh_lo[c] = md.stats_coh_mid[c] = md.stats_coh_hi[c] = 0;
    md.stats_onset[c] = 0;
  }
  if (n_ch == 0 || fr == 0) return;

  const float aE = alpha_energy_.load(std::memory_order_relaxed);
  const float aF = alpha_onset_fast_.load(std::memory_order_relaxed);
  const float aS = alpha_onset_slow_.load(std::memory_order_relaxed);
  const float aC = alpha_coh_.load(std::memory_order_relaxed);

  const uint32_t n_corr = std::min(n_ch, kStatsCorrMaxChannels);
  const uint32_t onset_hold_samples = static_cast<uint32_t>(
      kOnsetHoldMs * 1e-3f * static_cast<float>(sample_rate_));

  // First pass per frame: compute element sum sample, filter it into
  // three bands, then update per-channel stats. This interleaves
  // channel and sum work so per-sample overhead stays predictable.
  for (uint32_t f = 0; f < fr; ++f) {
    float s_sum = 0.0f;
    for (uint32_t c = 0; c < n_ch; ++c) {
      s_sum += finite_or_zero(buffer.channel(c)[f]);
    }
    const float s_lo = lp_sum_.process(s_sum);
    // HP(fc_lo) of the sum gives "mid+hi"; separate with HP(fc_hi).
    const float s_hi = hp_sum_.process(s_sum);
    const float s_mid = s_sum - s_lo - s_hi;
    ess_lo_ += aC * (s_lo * s_lo - ess_lo_);
    ess_mid_ += aC * (s_mid * s_mid - ess_mid_);
    ess_hi_ += aC * (s_hi * s_hi - ess_hi_);

    for (uint32_t c = 0; c < n_ch; ++c) {
      const float x = finite_or_zero(buffer.channel(c)[f]);
      // Energy EMA on power.
      energy_[c] += aE * (x * x - energy_[c]);
      // Onset — fast/slow EMA of |x|.
      const float ax = std::fabs(x);
      onset_fast_[c] += aF * (ax - onset_fast_[c]);
      onset_slow_[c] += aS * (ax - onset_slow_[c]);
      // Trigger if fast/slow > ratio AND slow is above a noise floor
      // (avoids onsets firing on silence where the ratio is meaningless).
      if (onset_hold_[c] > 0) {
        --onset_hold_[c];
      }
      if (onset_hold_[c] == 0 && onset_slow_[c] > 1e-5f &&
          onset_fast_[c] > kOnsetRatio * onset_slow_[c]) {
        onset_hold_[c] = onset_hold_samples;
      }

      // Band split & coherence accumulators.
      const float x_lo = lp_[c].process(x);
      const float x_hi = hp_[c].process(x);
      const float x_mid = x - x_lo - x_hi;
      cxs_lo_[c] += aC * (x_lo * s_lo - cxs_lo_[c]);
      cxs_mid_[c] += aC * (x_mid * s_mid - cxs_mid_[c]);
      cxs_hi_[c] += aC * (x_hi * s_hi - cxs_hi_[c]);
      exx_lo_[c] += aC * (x_lo * x_lo - exx_lo_[c]);
      exx_mid_[c] += aC * (x_mid * x_mid - exx_mid_[c]);
      exx_hi_[c] += aC * (x_hi * x_hi - exx_hi_[c]);
    }

    // Pairwise correlation accumulators (broadband). Symmetric so we
    // only touch the upper triangle; skip when n_corr <= 1.
    if (n_corr > 1) {
      for (uint32_t i = 0; i < n_corr; ++i) {
        const float xi = finite_or_zero(buffer.channel(i)[f]);
        for (uint32_t j = i + 1; j < n_corr; ++j) {
          const float xj = finite_or_zero(buffer.channel(j)[f]);
          const uint32_t idx = pair_index(i, j);
          exy_[idx] += aE * (xi * xj - exy_[idx]);
        }
      }
    }
  }

  // Publish: linear energy directly; coherence as |γ|²; correlation
  // as ρ = E[xy]/sqrt(E[xx]E[yy]) clamped to [-1, 1].
  constexpr float kEps = 1e-12f;
  for (uint32_t c = 0; c < n_ch; ++c) {
    md.stats_energy[c] = energy_[c];
    md.stats_onset[c] = onset_hold_[c] > 0 ? 1 : 0;
    const float g_lo =
        (cxs_lo_[c] * cxs_lo_[c]) / (exx_lo_[c] * ess_lo_ + kEps);
    const float g_mid =
        (cxs_mid_[c] * cxs_mid_[c]) / (exx_mid_[c] * ess_mid_ + kEps);
    const float g_hi =
        (cxs_hi_[c] * cxs_hi_[c]) / (exx_hi_[c] * ess_hi_ + kEps);
    md.stats_coh_lo[c] = std::clamp(g_lo, 0.0f, 1.0f);
    md.stats_coh_mid[c] = std::clamp(g_mid, 0.0f, 1.0f);
    md.stats_coh_hi[c] = std::clamp(g_hi, 0.0f, 1.0f);
  }
  // Zero correlation entries that involve inactive channels so the
  // reader sees a clean boundary.
  for (uint32_t i = 0; i < kStatsCorrMaxChannels; ++i) {
    for (uint32_t j = i + 1; j < kStatsCorrMaxChannels; ++j) {
      const uint32_t idx = pair_index(i, j);
      if (i >= n_corr || j >= n_corr) {
        md.stats_corr[idx] = 0.0f;
        continue;
      }
      // energy_[] is the same aE-smoothed E[x^2] the correlation
      // denominator needs — no separate accumulator required.
      const float denom = std::sqrt(energy_[i] * energy_[j]) + kEps;
      md.stats_corr[idx] = std::clamp(exy_[idx] / denom, -1.0f, 1.0f);
    }
  }
}
