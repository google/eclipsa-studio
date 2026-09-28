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

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "meters/meter_state.h"
#include "meters/peak_meter.h"
#include "meters/rms_meter.h"

namespace {

// ── Helpers ───────────────────────────────────────────────────────────────

struct TestBuf {
  static constexpr uint32_t kChannels = 2;
  static constexpr uint32_t kFrames = 1024;

  float storage[kChannels * kFrames] = {};
  AudioBuffer buf{storage, kChannels, kFrames, kFrames};

  void fill_constant(float v) {
    for (uint32_t ch = 0; ch < kChannels; ++ch) {
      float* data = buf.channel(ch);
      for (uint32_t f = 0; f < kFrames; ++f) data[f] = v;
    }
  }

  void fill_sine(float freq_hz, float amplitude, uint32_t sample_rate) {
    const float dt = 1.0f / static_cast<float>(sample_rate);
    for (uint32_t ch = 0; ch < kChannels; ++ch) {
      float* data = buf.channel(ch);
      for (uint32_t f = 0; f < kFrames; ++f) {
        data[f] = amplitude * std::sin(2.0f * 3.14159265f * freq_hz * f * dt);
      }
    }
  }
};

constexpr uint32_t kTestElement = 0;

// ── PeakMeter tests ───────────────────────────────────────────────────────

TEST(PeakMeterTest, KnownPeakValue) {
  TestBuf tb;
  tb.fill_constant(0.5f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  // Linear peak should be 0.5.
  for (uint32_t ch = 0; ch < TestBuf::kChannels; ++ch) {
    EXPECT_NEAR(state.elements[kTestElement].peak[ch], 0.5f, 0.01f);
  }
}

TEST(PeakMeterTest, FullScalePeakIsOne) {
  TestBuf tb;
  tb.fill_constant(1.0f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  for (uint32_t ch = 0; ch < TestBuf::kChannels; ++ch) {
    EXPECT_NEAR(state.elements[kTestElement].peak[ch], 1.0f, 0.01f);
  }
}

TEST(PeakMeterTest, SilenceReportsZero) {
  TestBuf tb;
  tb.fill_constant(0.0f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  for (uint32_t ch = 0; ch < TestBuf::kChannels; ++ch) {
    EXPECT_FLOAT_EQ(state.elements[kTestElement].peak[ch], 0.0f);
  }
}

TEST(PeakMeterTest, ClipFlagSetForOverload) {
  TestBuf tb;
  tb.fill_constant(1.1f);  // Over 0 dBFS.

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  for (uint32_t ch = 0; ch < TestBuf::kChannels; ++ch) {
    EXPECT_EQ(state.elements[kTestElement].clip[ch], 1);
  }
}

TEST(PeakMeterTest, NormalSignalDoesNotClip) {
  TestBuf tb;
  tb.fill_constant(0.9f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  for (uint32_t ch = 0; ch < TestBuf::kChannels; ++ch) {
    EXPECT_EQ(state.elements[kTestElement].clip[ch], 0);
  }
}

TEST(PeakMeterTest, ChannelCountSetCorrectly) {
  TestBuf tb;
  tb.fill_constant(0.5f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  EXPECT_EQ(state.elements[kTestElement].channel_count, TestBuf::kChannels);
}

TEST(PeakMeterTest, PeakHoldRetainsPeak) {
  TestBuf tb;
  tb.fill_constant(0.8f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  EXPECT_NEAR(state.elements[kTestElement].peak_hold[0], 0.8f, 0.01f);

  // Process silence — peak hold should stay at 0.8.
  tb.fill_constant(0.0f);
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);

  EXPECT_NEAR(state.elements[kTestElement].peak_hold[0], 0.8f, 0.01f);
}

TEST(PeakMeterTest, ResetClearsState) {
  TestBuf tb;
  tb.fill_constant(1.0f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);
  EXPECT_NEAR(state.elements[kTestElement].peak[0], 1.0f, 0.01f);

  meter.reset(state, kTestElement);
  EXPECT_FLOAT_EQ(state.elements[kTestElement].peak[0], 0.0f);
  EXPECT_FLOAT_EQ(state.elements[kTestElement].peak_hold[0], 0.0f);
}

TEST(PeakMeterTest, ResetDoesNotTouchClipLatch) {
  // ES-528: overload markers must survive a transport stop. The clip
  // latches are owned by AudioGraph's clip-clear paths
  // (clear_clips_now) — PeakMeter::reset deliberately leaves them
  // alone, and reset_meters(preserve_clips=false) clears them at the
  // graph level.
  TestBuf tb;
  tb.fill_constant(1.1f);

  EclipsaStudioMeterState state{};
  PeakMeter meter;
  meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);
  ASSERT_EQ(static_cast<int>(state.elements[kTestElement].clip[0]), 1);

  meter.reset(state, kTestElement);
  EXPECT_FLOAT_EQ(state.elements[kTestElement].peak[0], 0.0f);
  EXPECT_FLOAT_EQ(state.elements[kTestElement].peak_hold[0], 0.0f);
  EXPECT_EQ(static_cast<int>(state.elements[kTestElement].clip[0]), 1);
}

// ── RmsMeter tests ────────────────────────────────────────────────────────

TEST(RmsMeterTest, SilenceReportsZero) {
  TestBuf tb;
  tb.fill_constant(0.0f);

  EclipsaStudioMeterState state{};
  RmsMeter meter;
  // Process multiple blocks so the EMA can settle.
  for (int i = 0; i < 20; ++i) {
    meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);
  }

  for (uint32_t ch = 0; ch < TestBuf::kChannels; ++ch) {
    EXPECT_NEAR(state.elements[kTestElement].rms[ch], 0.0f, 0.001f);
  }
}

TEST(RmsMeterTest, FullScaleSineRmsNearPointSeven) {
  // A full-scale sine has RMS = 1/sqrt(2) ≈ 0.707.
  TestBuf tb;
  tb.fill_sine(440.0f, 1.0f, 48000u);

  EclipsaStudioMeterState state{};
  RmsMeter meter(300.0f, 48000);

  // Process many blocks so the EMA settles.
  for (int i = 0; i < 100; ++i) {
    meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);
  }

  EXPECT_NEAR(state.elements[kTestElement].rms[0], 0.707f, 0.05f);
}

TEST(RmsMeterTest, HalfAmplitudeSineRmsNearPointThree) {
  // RMS of a 0.5-amplitude sine = 0.5/sqrt(2) ≈ 0.354.
  TestBuf tb;
  tb.fill_sine(440.0f, 0.5f, 48000u);

  EclipsaStudioMeterState state{};
  RmsMeter meter(300.0f, 48000);

  for (int i = 0; i < 100; ++i) {
    meter.process(tb.buf, TestBuf::kFrames, state, kTestElement);
  }

  EXPECT_NEAR(state.elements[kTestElement].rms[0], 0.354f, 0.05f);
}

}  // namespace
