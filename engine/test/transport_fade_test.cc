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

// Transport edge fades (ES-530): the fade durations are wall-clock, so
// the ramp shape must survive every sample-rate / buffer-size
// combination — a 64-frame buffer spends more callbacks inside the
// ramp than a 2048-frame one, but the fade takes the same milliseconds
// and stays per-sample continuous across block boundaries. This is the
// pin for that invariance; the audio-thread wiring (pending flag,
// park, quick-resume cancel) is covered in playback_ffi_test.

#include "transport_fade.h"

#include <cmath>
#include <cstdint>
#include <vector>

#include "gtest/gtest.h"

namespace {

constexpr uint32_t kChannels = 2;

// Runs a fade from `start` toward `target` over consecutive blocks of
// constant full-scale input, returning the concatenated channel-0
// output. Stops once the gain reaches the target (plus one settle
// block) or after a generous block cap.
std::vector<float> run_fade(uint32_t rate, uint32_t buffer, float start,
                            float target) {
  const float step_up = transport_fade_step(kTransportFadeInMs, rate);
  const float step_down = transport_fade_step(kTransportFadeOutMs, rate);
  std::vector<float> block(static_cast<size_t>(buffer) * kChannels);
  std::vector<float> sig;
  float gain = start;
  for (int b = 0; b < 4096 && (b == 0 || gain != target); ++b) {
    std::fill(block.begin(), block.end(), 1.0f);
    gain = transport_fade_apply(block.data(), buffer, kChannels, gain, target,
                                step_up, step_down);
    for (uint32_t f = 0; f < buffer; ++f) {
      sig.push_back(block[f * kChannels]);
    }
  }
  return sig;
}

// Index of the first sample at `level` (within eps), or -1.
int settle_index(const std::vector<float>& sig, float level) {
  for (size_t i = 0; i < sig.size(); ++i) {
    if (std::fabs(sig[i] - level) < 1e-6f) return static_cast<int>(i);
  }
  return -1;
}

TEST(TransportFadeTest, ShapeIsInvariantAcrossRatesAndBuffers) {
  const uint32_t kRates[] = {44100, 48000, 96000, 192000};
  const uint32_t kBuffers[] = {64, 128, 512, 1024, 2048, 4096};

  for (const uint32_t rate : kRates) {
    for (const uint32_t buffer : kBuffers) {
      SCOPED_TRACE(testing::Message() << rate << " Hz / " << buffer);

      // Fade-out: full scale ramps to zero in kTransportFadeOutMs of
      // wall clock, regardless of the block size.
      const auto out = run_fade(rate, buffer, 1.0f, 0.0f);
      const int out_expected =
          static_cast<int>(kTransportFadeOutMs * 0.001f * rate);
      const int out_settled = settle_index(out, 0.0f);
      ASSERT_GE(out_settled, 0) << "fade-out never reached silence";
      EXPECT_NEAR(out_settled, out_expected, 2);

      // Fade-in: symmetric, at its own (shorter) duration.
      const auto in = run_fade(rate, buffer, 0.0f, 1.0f);
      const int in_expected =
          static_cast<int>(kTransportFadeInMs * 0.001f * rate);
      const int in_settled = settle_index(in, 1.0f);
      ASSERT_GE(in_settled, 0) << "fade-in never reached unity";
      EXPECT_NEAR(in_settled, in_expected, 2);

      // Continuity: monotonic, and no per-sample jump larger than the
      // step — INCLUDING across block boundaries, where a
      // gain-restart bug would show as a discontinuity.
      const float step = transport_fade_step(kTransportFadeOutMs, rate);
      for (size_t i = 1; i < out.size(); ++i) {
        ASSERT_LE(out[i], out[i - 1] + 1e-6f) << "fade-out not monotonic";
        ASSERT_LE(std::fabs(out[i] - out[i - 1]), step + 1e-6f)
            << "fade-out jump at sample " << i;
      }
      const float step_in = transport_fade_step(kTransportFadeInMs, rate);
      for (size_t i = 1; i < in.size(); ++i) {
        ASSERT_GE(in[i], in[i - 1] - 1e-6f) << "fade-in not monotonic";
        ASSERT_LE(std::fabs(in[i] - in[i - 1]), step_in + 1e-6f)
            << "fade-in jump at sample " << i;
      }
    }
  }
}

TEST(TransportFadeTest, MidFadeReversalRampsBackWithoutJump) {
  // A play() landing mid-fade-out flips the target back to 1: the gain
  // must glide up from wherever it is — no snap in either direction.
  const uint32_t rate = 48000;
  // Shorter than the 480-frame fade-out span, so the block ends
  // mid-ramp.
  const uint32_t buffer = 256;
  const float step_up = transport_fade_step(kTransportFadeInMs, rate);
  const float step_down = transport_fade_step(kTransportFadeOutMs, rate);

  std::vector<float> block(static_cast<size_t>(buffer) * kChannels, 1.0f);
  // Half a fade-out...
  float gain = transport_fade_apply(block.data(), buffer, kChannels, 1.0f, 0.0f,
                                    step_up, step_down);
  ASSERT_GT(gain, 0.0f);
  ASSERT_LT(gain, 1.0f);
  const float mid = gain;

  // ...then reverse toward unity: the first frame continues from
  // `mid`, stepping up by at most step_up.
  std::fill(block.begin(), block.end(), 1.0f);
  gain = transport_fade_apply(block.data(), buffer, kChannels, mid, 1.0f,
                              step_up, step_down);
  EXPECT_NEAR(block[0], mid + step_up, 1e-6f);
  EXPECT_GT(gain, mid);
}

TEST(TransportFadeTest, UnityIsAPassthrough) {
  // Steady playback must not be touched: at gain == target == 1 every
  // sample passes bit-exact (the caller skips the call entirely, but
  // the helper must also be safe if it doesn't).
  std::vector<float> block(512 * kChannels, 0.7654321f);
  const float gain = transport_fade_apply(block.data(), 512, kChannels, 1.0f,
                                          1.0f, 0.01f, 0.01f);
  EXPECT_EQ(gain, 1.0f);
  for (const float s : block) {
    EXPECT_EQ(s, 0.7654321f);
  }
}

}  // namespace
