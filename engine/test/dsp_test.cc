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

#include <cmath>
#include <cstring>

#include "dsp/gain.h"
#include "graph/audio_buffer.h"
#include "gtest/gtest.h"

namespace {

// ── Helpers ───────────────────────────────────────────────────────────────

/// Fill a planar AudioBuffer with a constant value on all channels.
void fill_constant(AudioBuffer& buf, float value) {
  for (uint32_t ch = 0; ch < buf.channels; ++ch) {
    float* data = buf.channel(ch);
    for (uint32_t f = 0; f < buf.capacity_frames; ++f) {
      data[f] = value;
    }
  }
  buf.frames = buf.capacity_frames;
}

/// Compute the peak absolute value across all channels in the buffer.
float peak(const AudioBuffer& buf) {
  float p = 0.0f;
  for (uint32_t ch = 0; ch < buf.channels; ++ch) {
    const float* data = buf.channel(ch);
    for (uint32_t f = 0; f < buf.frames; ++f) {
      float a = std::abs(data[f]);
      if (a > p) p = a;
    }
  }
  return p;
}

// ── Gain tests ────────────────────────────────────────────────────────────

class GainTest : public ::testing::Test {
 protected:
  static constexpr uint32_t kChannels = 2;
  static constexpr uint32_t kFrames = 512;

  float storage_[kChannels * kFrames] = {};
  AudioBuffer buf_{storage_, kChannels, kFrames, kFrames};
};

TEST_F(GainTest, UnityGainLeavesSignalUnchanged) {
  fill_constant(buf_, 0.5f);
  dsp::Gain g;
  g.set_gain_db(0.0f);
  g.reset();  // snap current = target, no smoothing ramp
  g.process(buf_, kFrames);

  // With unity gain and no smoothing ramp, output should equal input.
  for (uint32_t ch = 0; ch < kChannels; ++ch) {
    for (uint32_t f = 0; f < kFrames; ++f) {
      EXPECT_NEAR(buf_.channel(ch)[f], 0.5f, 0.01f);
    }
  }
}

TEST_F(GainTest, SixDbIncreasesAmplitudeByTwo) {
  fill_constant(buf_, 0.25f);
  dsp::Gain g;
  g.set_gain_db(6.0206f);  // +6 dB ≈ ×2
  g.reset();               // snap current = target
  g.process(buf_, kFrames);

  // After smoothing converges (we reset, so current = target immediately).
  float p = peak(buf_);
  EXPECT_NEAR(p, 0.5f, 0.02f);  // 0.25 * 2 = 0.5
}

TEST_F(GainTest, MinusInfinityGainProducesSilence) {
  fill_constant(buf_, 1.0f);
  dsp::Gain g;
  g.set_gain_db(-120.0f);
  g.reset();
  g.process(buf_, kFrames);

  EXPECT_LT(peak(buf_), 1e-4f);
}

TEST_F(GainTest, ZeroInputRemainsZeroUnderAnyGain) {
  fill_constant(buf_, 0.0f);
  dsp::Gain g;
  g.set_gain_db(40.0f);
  g.reset();
  g.process(buf_, kFrames);
  EXPECT_FLOAT_EQ(peak(buf_), 0.0f);
}

}  // namespace
