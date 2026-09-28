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

// Limiter THD characterization. Measures the harmonic distortion
// liboar's limiter (the libiamf reference peak limiter) adds to a
// sustained tonal over, through the full production OarRenderer stereo
// path, at several engagement depths, and bounds it at -120 dB re the
// fundamental.
//
// A limiter change in an oar pin bump shows up here as a THD jump. The
// correlation-based THD estimate is delay-agnostic, so the limiter's
// 5 ms delay does not bias it.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"

namespace {

constexpr uint32_t kRate = 48000;
constexpr uint32_t kFrames = 512;
constexpr uint32_t kStereoLayout = 2;
constexpr double kTwoPi = 6.283185307179586476925286766559;
// 10 cycles per 512-frame block — phase-continuous across blocks.
constexpr double kF0 = 937.5;

// Assertion bound (dB re fundamental). Measured 2026-08 on the fork's
// copy of the same law: -128.8..-135.1. The margin absorbs measurement
// noise but not a behavioral regression.
constexpr double kMaxThdDb = -120.0;

// Renders `total_blocks` of a phase-continuous stereo sine at linear
// amplitude `amp` and returns the left-channel output of the last
// `keep_blocks` blocks (limiter env in steady state).
std::vector<float> render_steady(OarRenderer& r, double amp, int total_blocks,
                                 int keep_blocks) {
  std::vector<float> in(2 * kFrames);
  std::vector<float> kept;
  kept.reserve(static_cast<size_t>(keep_blocks) * kFrames);
  uint64_t n = 0;
  for (int b = 0; b < total_blocks; ++b) {
    for (uint32_t f = 0; f < kFrames; ++f, ++n) {
      const float s = static_cast<float>(
          amp * std::sin(kTwoPi * kF0 * static_cast<double>(n) / kRate));
      in[f] = s;
      in[kFrames + f] = s;
    }
    r.update_element_data(1, in.data(), 2, kFrames, kFrames);
    const float* out = r.render(kFrames);
    EXPECT_NE(out, nullptr);
    if (out && b >= total_blocks - keep_blocks) {
      kept.insert(kept.end(), out, out + kFrames);
    }
  }
  return kept;
}

// THD+N in dB relative to the fundamental: correlate out the f0
// component (sin+cos, phase-agnostic), everything left is distortion
// (+ noise).
double thd_db(const std::vector<float>& x) {
  const size_t n = x.size();
  double ss = 0.0;
  double sc = 0.0;
  double total = 0.0;
  for (size_t i = 0; i < n; ++i) {
    const double w = kTwoPi * kF0 * static_cast<double>(i) / kRate;
    ss += x[i] * std::sin(w);
    sc += x[i] * std::cos(w);
    total += static_cast<double>(x[i]) * x[i];
  }
  const double mean_sq = total / static_cast<double>(n);
  const double fund_mean_sq = (ss * ss + sc * sc) * 2.0 /
                              (static_cast<double>(n) * static_cast<double>(n));
  const double resid_mean_sq = mean_sq - fund_mean_sq;
  if (resid_mean_sq <= 0.0 || fund_mean_sq <= 0.0) return -200.0;
  return 10.0 * std::log10(resid_mean_sq / fund_mean_sq);
}

TEST(OarLimiterThdTest, LimiterStaysTransparent) {
  // Over-the-ceiling depths to probe, in dB above the -1 dBFS ceiling.
  const double kOverDb[] = {0.5, 1.0, 2.0, 4.0, 6.0, 9.0};
  const double ceiling = std::pow(10.0, -1.0 / 20.0);

  std::printf("\n  over(dB)  THD+N (dB rel fund)\n");
  for (const double over : kOverDb) {
    const double amp = ceiling * std::pow(10.0, over / 20.0);
    OarRenderer r;
    r.set_no_audio_thread();
    ASSERT_TRUE(r.init(kRate, kFrames, kStereoLayout));
    ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));
    // 64 blocks total, keep the last 32 (~341 ms steady state).
    const std::vector<float> out = render_steady(r, amp, 64, 32);
    ASSERT_EQ(out.size(), 32u * kFrames);
    const double thd = thd_db(out);
    std::printf("  %6.1f    %9.1f\n", over, thd);

    EXPECT_LE(thd, kMaxThdDb) << "limiter no longer transparent at " << over
                              << " dB over — oar DSP regression?";
  }
  std::fflush(stdout);
}

}  // namespace
