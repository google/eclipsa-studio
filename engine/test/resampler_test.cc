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

#include "dsp/resampler.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"

namespace {

constexpr float kPi = 3.14159265358979323846f;

// Generate a planar sine wave at `freq` Hz into the resampler's input
// buffer at sample rate `rate`, starting at sample-frame `start_frame`.
void fill_sine(AudioBuffer& buf, uint32_t frames, uint32_t channels, float freq,
               float rate, uint64_t start_frame) {
  buf.frames = frames;
  for (uint32_t c = 0; c < channels; ++c) {
    float* dst = buf.channel(c);
    for (uint32_t f = 0; f < frames; ++f) {
      dst[f] = std::sin(2.0f * kPi * freq * (start_frame + f) / rate);
    }
  }
}

// Standalone storage for the output planar AudioBuffer.
struct OutBuf {
  std::vector<float> storage;
  AudioBuffer view{};
  void resize(uint32_t channels, uint32_t capacity_frames) {
    storage.assign(static_cast<size_t>(channels) * capacity_frames, 0.0f);
    view.data = storage.data();
    view.channels = channels;
    view.frames = 0;
    view.capacity_frames = capacity_frames;
  }
};

TEST(ResamplerTest, BadConfigRejected) {
  dsp::Resampler r;
  EXPECT_FALSE(r.init(0, 48000, 2, 512));
  EXPECT_FALSE(r.init(48000, 0, 2, 512));
  EXPECT_FALSE(r.init(48000, 48000, 0, 512));
  EXPECT_FALSE(r.init(48000, 48000, 2, 0));
}

TEST(ResamplerTest, IdentityRatePassesThrough) {
  dsp::Resampler r;
  ASSERT_TRUE(r.init(48000, 48000, 1, 512));

  OutBuf out;
  out.resize(/*channels=*/1, /*capacity_frames=*/512);

  // Feed a few blocks of a 1 kHz sine; every block should produce
  // output once the sinc filter is primed (the priming headroom in
  // required_input() covers the first block too).
  uint64_t in_cursor = 0;
  for (int block = 0; block < 8; ++block) {
    const uint64_t in_needed = r.required_input(512);
    fill_sine(r.input_buffer(), static_cast<uint32_t>(in_needed),
              /*channels=*/1, /*freq=*/1000.0f, /*rate=*/48000.0f, in_cursor);
    in_cursor += in_needed;
    const uint32_t got =
        r.consume(out.view, static_cast<uint32_t>(in_needed), 512);
    EXPECT_GT(got, 0u);
  }
}

TEST(ResamplerTest, UpsampleProducesExpectedOutputCount) {
  // 44.1 → 48 kHz. Each call should produce ~the requested output count.
  dsp::Resampler r;
  ASSERT_TRUE(r.init(44100, 48000, 2, 1024));

  OutBuf out;
  out.resize(2, 1024);

  uint32_t total_out = 0;
  uint64_t in_cursor = 0;
  for (int block = 0; block < 16; ++block) {
    const uint64_t in_needed = r.required_input(1024);
    ASSERT_LE(in_needed, r.input_buffer().capacity_frames);
    fill_sine(r.input_buffer(), static_cast<uint32_t>(in_needed), 2, 440.0f,
              44100.0f, in_cursor);
    in_cursor += in_needed;
    const uint32_t got =
        r.consume(out.view, static_cast<uint32_t>(in_needed), 1024);
    total_out += got;
  }

  // Steady-state: total output should be very close to 16 × 1024.
  // Allow a small tolerance for filter warm-up on the first block.
  EXPECT_GE(total_out, 16u * 1024u - 16u);
  EXPECT_LE(total_out, 16u * 1024u);
}

TEST(ResamplerTest, DownsampleProducesExpectedOutputCount) {
  // 96 → 48 kHz. Required input ≈ 2× output.
  dsp::Resampler r;
  ASSERT_TRUE(r.init(96000, 48000, 1, 512));

  OutBuf out;
  out.resize(1, 512);

  for (int block = 0; block < 8; ++block) {
    const uint64_t in_needed = r.required_input(512);
    // Sanity: at 2:1 downsample, we need around 2× output frames in,
    // plus sinc-filter priming headroom on the first call (the carry
    // brings later calls back near the bare ratio).
    EXPECT_GE(in_needed, 1000u);
    EXPECT_LE(in_needed, 1300u);
    fill_sine(r.input_buffer(), static_cast<uint32_t>(in_needed), 1, 1000.0f,
              96000.0f, 0);
    const uint32_t got =
        r.consume(out.view, static_cast<uint32_t>(in_needed), 512);
    EXPECT_GT(got, 0u);
  }
}

TEST(ResamplerTest, ResetClearsFilterStateBetweenSeeks) {
  // After reset(), the resampler should treat the next input as fresh.
  // We can't directly inspect filter state, but we can confirm
  // consume() still returns the expected number of frames after a
  // reset following several blocks.
  dsp::Resampler r;
  ASSERT_TRUE(r.init(44100, 48000, 1, 512));

  OutBuf out;
  out.resize(1, 512);

  for (int i = 0; i < 4; ++i) {
    const uint64_t in_needed = r.required_input(512);
    fill_sine(r.input_buffer(), static_cast<uint32_t>(in_needed), 1, 440.0f,
              44100.0f, 0);
    r.consume(out.view, static_cast<uint32_t>(in_needed), 512);
  }

  r.reset();

  const uint64_t in_needed = r.required_input(512);
  fill_sine(r.input_buffer(), static_cast<uint32_t>(in_needed), 1, 440.0f,
            44100.0f, 0);
  const uint32_t got =
      r.consume(out.view, static_cast<uint32_t>(in_needed), 512);
  EXPECT_GT(got, 0u);
  EXPECT_LE(got, 512u);
}

// Run `blocks` × `out_block` frames of a sine at `freq` through a
// resampler and return the produced output as one contiguous vector.
std::vector<float> run_sine(dsp::Resampler& r, float freq, float in_rate,
                            uint32_t out_block, int blocks) {
  OutBuf out;
  out.resize(1, out_block);
  std::vector<float> produced;
  uint64_t in_cursor = 0;
  for (int b = 0; b < blocks; ++b) {
    const uint64_t in_needed = r.required_input(out_block);
    fill_sine(r.input_buffer(), static_cast<uint32_t>(in_needed), 1, freq,
              in_rate, in_cursor);
    in_cursor += in_needed;
    const uint32_t got =
        r.consume(out.view, static_cast<uint32_t>(in_needed), out_block);
    const float* ch = out.view.channel(0);
    produced.insert(produced.end(), ch, ch + got);
  }
  return produced;
}

TEST(ResamplerTest, PassbandGainIsUnityAcrossRatePairs) {
  // Regression guard for the class of bug found in the OBR resampler
  // (rate-pair-dependent gain, eclipsa-studio#5): a unit-amplitude
  // 1 kHz tone must come out at unit amplitude at every ratio, on both
  // quality tiers.
  const std::pair<uint32_t, uint32_t> kPairs[] = {
      {44100, 48000}, {48000, 44100}, {96000, 48000}, {192000, 48000}};
  for (const auto quality :
       {dsp::Resampler::Quality::kLive, dsp::Resampler::Quality::kExport}) {
    for (const auto& [in_rate, out_rate] : kPairs) {
      dsp::Resampler r;
      ASSERT_TRUE(r.init(in_rate, out_rate, 1, 512, quality));
      const std::vector<float> y =
          run_sine(r, 1000.0f, static_cast<float>(in_rate), 512, 32);
      ASSERT_GT(y.size(), 4096u);
      // RMS over the back half — well past any filter transient.
      double sum_sq = 0.0;
      const size_t begin = y.size() / 2;
      for (size_t i = begin; i < y.size(); ++i) {
        sum_sq += static_cast<double>(y[i]) * y[i];
      }
      const double amplitude =
          std::sqrt(2.0 * sum_sq / static_cast<double>(y.size() - begin));
      EXPECT_NEAR(1.0, amplitude, 0.02)
          << "gain error at " << in_rate << " -> " << out_rate;
    }
  }
}

TEST(ResamplerTest, UpsampleSuppressesImaging) {
  // 10 kHz at 32 kHz upsampled to 48 kHz puts the first image at
  // 22 kHz, inside the output band. The previous linear resampler left
  // it at about -19 dBFS; the sinc converters must hold it far down.
  dsp::Resampler r;
  ASSERT_TRUE(r.init(32000, 48000, 1, 512));
  const std::vector<float> y = run_sine(r, 10000.0f, 32000.0f, 512, 32);
  ASSERT_GT(y.size(), 4096u);

  // Goertzel magnitude at the image frequency over the back half.
  const size_t begin = y.size() / 2;
  const size_t n = y.size() - begin;
  const double w = 2.0 * kPi * 22000.0 / 48000.0;
  const double coeff = 2.0 * std::cos(w);
  double s0 = 0.0, s1 = 0.0, s2 = 0.0;
  for (size_t i = begin; i < y.size(); ++i) {
    s0 = y[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const double power = (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (0.25 * n * n);
  const double image_db = 10.0 * std::log10(power + 1e-30);
  EXPECT_LT(image_db, -60.0);
}

TEST(ResamplerTest, ShortInputProducesShortOutput) {
  // Hand consume() fewer input frames than required — output should
  // be proportionally smaller and the resampler must not crash or
  // overrun its scratch buffers.
  dsp::Resampler r;
  ASSERT_TRUE(r.init(48000, 48000, 1, 512));

  OutBuf out;
  out.resize(1, 512);

  const uint64_t in_needed = r.required_input(512);
  // Feed only half the required input.
  const uint32_t in_short = static_cast<uint32_t>(in_needed) / 2;
  fill_sine(r.input_buffer(), in_short, 1, 440.0f, 48000.0f, 0);
  const uint32_t got = r.consume(out.view, in_short, 512);
  EXPECT_LE(got, 512u);
}

}  // namespace
