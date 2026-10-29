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

// Limiter delay contract. liboar's limiter (the libiamf reference
// peak limiter: 5 ms look-ahead, parabolic 1 ms attack, 200 ms
// release, hard clip at the ceiling) delays the monitoring output by
// its look-ahead. The delay OAR reports (oar_get_limiter_delay() via
// OarRenderer::limiter_delay()) must match the delay the production
// render path exhibits (measured by pushing an impulse through a
// stereo bed and locating it in the output), at every supported
// sample rate.
//
// What this catches: an oar pin bump changing the delay length (every
// extra millisecond is monitoring latency), the reported value
// drifting from the real one (offline measurement aligns its traces
// on it), a layout rebuild zeroing the delay cache, and the limiter
// no longer holding the -1 dBFS ceiling.
//
// Scope: the limiter's contribution on a loudspeaker passthrough.
// OBR's binaural filters have their own inherent latency, which is
// not pinned here.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"

namespace {

constexpr uint32_t kFrames = 512;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t: stereo
constexpr uint32_t k51Layout = 3;      // oar_layout_t: 5.1
constexpr uint32_t kImpulseFrame = 100;

// Delay bounds, in ms. The libiamf reference limiter's design point is
// 5 ms (its own constant, not ours); anything outside this window
// means the tuning changed and the monitoring latency budget needs
// re-review.
constexpr double kMinMs = 4.5;
constexpr double kMaxMs = 5.5;

// The limiter ceiling (-1 dBFS) as linear amplitude.
const float kCeiling = std::pow(10.0f, -1.0f / 20.0f);  // 0.8913

// Blocks rendered while hunting for the impulse. The delay can push it
// past the first block — 5 ms at 96 kHz is 480 samples, and the impulse
// goes in at kImpulseFrame of a 512-frame block — so probe two and
// report the position on the concatenated output. Every block after the
// first is fed explicit silence: an element that is not re-fed REPEATS
// its previous block, which would put a second impulse in the stream.
constexpr uint32_t kProbeBlocks = 2;

// Renders a single sub-ceiling impulse at kImpulseFrame on both
// channels and returns the impulse's position in the left output
// channel, or -1 if absent. Sub-ceiling passthrough on a stereo bed is
// exact, so the offset from kImpulseFrame is the path's delay.
int measured_impulse_pos(OarRenderer& r) {
  std::vector<float> in(2 * kFrames, 0.0f);
  in[kImpulseFrame] = 0.5f;
  in[kFrames + kImpulseFrame] = 0.5f;
  const std::vector<float> silence(2 * kFrames, 0.0f);
  for (uint32_t b = 0; b < kProbeBlocks; ++b) {
    r.update_element_data(1, b == 0 ? in.data() : silence.data(), 2, kFrames,
                          kFrames);
    const float* out = r.render(kFrames);
    EXPECT_NE(out, nullptr);
    if (!out) return -1;
    for (uint32_t i = 0; i < kFrames; ++i) {
      if (std::fabs(out[i]) > 0.1f) return static_cast<int>(b * kFrames + i);
    }
  }
  return -1;
}

TEST(OarLimiterDelayTest, ReportedMatchesMeasuredAcrossRates) {
  const uint32_t kRates[] = {44100, 48000, 96000};

  std::printf("\n  rate    reported  measured  delay(ms)\n");
  for (const uint32_t rate : kRates) {
    OarRenderer r;
    r.set_no_audio_thread();
    ASSERT_TRUE(r.init(rate, kFrames, kStereoLayout));
    ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));

    const uint32_t reported = r.limiter_delay();
    const int pos = measured_impulse_pos(r);
    ASSERT_GE(pos, 0) << "impulse lost at " << rate << " Hz";
    const int measured = pos - static_cast<int>(kImpulseFrame);
    const double ms = 1000.0 * reported / rate;
    std::printf("  %5u   %8u  %8d  %9.2f\n", rate, reported, measured, ms);

    EXPECT_EQ(measured, static_cast<int>(reported))
        << "reported limiter delay disagrees with the delay the render "
           "path exhibits ("
        << rate << " Hz)";
    EXPECT_GE(ms, kMinMs) << "delay shrank below its design point — attack "
                             "protection may be compromised";
    EXPECT_LE(ms, kMaxMs)
        << "delay grew — monitoring latency budget needs re-review";
  }
  std::fflush(stdout);
}

TEST(OarLimiterDelayTest, DefaultInstanceCarriesTheIamfDelay) {
  // The 5 ms delay is present from the first rendered block.
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.init(48000, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));
  const int pos = measured_impulse_pos(r);
  ASSERT_GE(pos, 0);
  EXPECT_EQ(pos - static_cast<int>(kImpulseFrame),
            static_cast<int>(r.limiter_delay()));
  EXPECT_EQ(r.limiter_delay(), 240u) << "5 ms at 48 kHz";
}

TEST(OarLimiterDelayTest, DelaySurvivesLayoutRebuild) {
  // create_renderer() writes the delay cache for every new instance.
  // The other writers are set_limiter_enabled() and shutdown_locked(),
  // which zeroes it. This test does not call set_limiter_enabled(), and
  // reaches shutdown_locked() only through init(), before init() builds
  // the first instance. Assert on it BETWEEN the rebuild and the next
  // render, then confirm on the rebuilt instance. The delay is 240 for
  // every instance at 48 kHz, so this catches a zeroed cache, not an
  // unrefreshed one.
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.init(48000, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));
  ASSERT_EQ(r.limiter_delay(), 240u);

  ASSERT_TRUE(r.set_layout(k51Layout));
  ASSERT_TRUE(r.set_layout(kStereoLayout));
  EXPECT_EQ(r.limiter_delay(), 240u) << "rebuilt instance lost the delay";

  const int pos = measured_impulse_pos(r);
  ASSERT_GE(pos, 0);
  EXPECT_EQ(pos - static_cast<int>(kImpulseFrame), 240);
}

TEST(OarLimiterDelayTest, HotInputStaysUnderTheCeiling) {
  // A 1 kHz sine 6 dB over full scale. The GT/LE pair is one pin: GT
  // alone would pass with the limiter disabled, LE alone with a silent
  // output.
  constexpr uint32_t kRate = 48000;
  constexpr float kTwoPi = 6.2831853071795864769f;
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.init(kRate, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));

  std::vector<float> hot(2 * kFrames);
  float peak = 0.0f;
  for (uint32_t b = 0; b < 8; ++b) {
    for (uint32_t f = 0; f < kFrames; ++f) {
      const float s =
          2.0f * std::sin(kTwoPi * 1000.0f *
                          static_cast<float>(b * kFrames + f) / kRate);
      hot[f] = s;
      hot[kFrames + f] = s;
    }
    r.update_element_data(1, hot.data(), 2, kFrames, kFrames);
    const float* out = r.render(kFrames);
    ASSERT_NE(out, nullptr);
    for (uint32_t i = 0; i < kFrames; ++i) {
      peak = std::max(peak, std::fabs(out[i]));
    }
  }
  EXPECT_GT(peak, kCeiling * 0.9f) << "limiter output collapsed";
  EXPECT_LE(peak, kCeiling + 1e-3f)
      << "limiter let a 6 dB over through — is it engaged at all?";
}

// set_limiter_enabled() on a built offline instance: off removes the
// delay from the cache and from the rendered path, on restores both.
TEST(OarLimiterDelayTest, DisabledLimiterAddsNoDelay) {
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.init(48000, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));
  ASSERT_EQ(r.limiter_delay(), 240u);

  ASSERT_TRUE(r.set_limiter_enabled(false));
  EXPECT_EQ(r.limiter_delay(), 0u);
  EXPECT_EQ(measured_impulse_pos(r), static_cast<int>(kImpulseFrame));

  ASSERT_TRUE(r.set_limiter_enabled(true));
  EXPECT_EQ(r.limiter_delay(), 240u);
  EXPECT_EQ(measured_impulse_pos(r), static_cast<int>(kImpulseFrame) + 240);
}

// Set before init(), the setting holds for the instance init() builds
// and for a rebuilt one.
TEST(OarLimiterDelayTest, SettingBeforeInitHoldsAcrossRebuild) {
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.set_limiter_enabled(false));
  ASSERT_TRUE(r.init(48000, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=channel*/ 0, kStereoLayout, 2));
  EXPECT_EQ(r.limiter_delay(), 0u);
  ASSERT_TRUE(r.set_layout(k51Layout));
  ASSERT_TRUE(r.set_layout(kStereoLayout));
  EXPECT_EQ(r.limiter_delay(), 0u);
  EXPECT_EQ(measured_impulse_pos(r), static_cast<int>(kImpulseFrame));
}

// An instance an audio thread may render keeps its limiter: the switch
// is refused before init(), so the instance init() builds is limited,
// and after it.
TEST(OarLimiterDelayTest, LiveInstanceRefusesTheSwitch) {
  OarRenderer r;
  EXPECT_FALSE(r.set_limiter_enabled(false));
  ASSERT_TRUE(r.init(48000, kFrames, kStereoLayout));
  EXPECT_EQ(r.limiter_delay(), 240u);
  EXPECT_FALSE(r.set_limiter_enabled(false));
  EXPECT_EQ(r.limiter_delay(), 240u);
}

}  // namespace
