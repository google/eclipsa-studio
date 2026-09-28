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

// Tests for the offline element bounce, focused on the resample stage
// that converts sources to the IAMF target rate.

#include "bounce/element_bouncer.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "io/wav_reader.h"
#include "test/test_wav_helper.h"

namespace {

using eclipsa_studio::ElementBouncer;

// Peak |sample| over `frames` frames starting at `start`.
float PeakAt(WavReader& reader, uint64_t start, uint32_t frames) {
  constexpr uint32_t kCap = 4096;
  static float storage[2 * kCap];
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = reader.channels();
  buf.frames = 0;
  buf.capacity_frames = kCap;
  reader.seek(start);
  const uint32_t got = reader.read(buf, std::min(frames, kCap));
  float peak = 0.0f;
  for (uint32_t ch = 0; ch < buf.channels; ++ch) {
    const float* s = buf.channel(ch);
    for (uint32_t f = 0; f < got; ++f) {
      peak = std::max(peak, std::fabs(s[f]));
    }
  }
  return peak;
}

class ElementBouncerTest : public ::testing::Test {
 protected:
  void SetUp() override { dir_ = test_wav::temp_dir(); }
  std::string dir_;
};

TEST_F(ElementBouncerTest, ResamplesToTargetRate) {
  // 1 s of 440 Hz at 44.1 kHz, bounced to a 48 kHz target: the output
  // must be a 48 kHz WAV of exactly the scaled length, still carrying
  // the sine.
  const std::string src = dir_ + "/bounce_441_1s.wav";
  ASSERT_TRUE(test_wav::write_sine(src, 1, 44100, 16, 440.f, 1.f));

  ElementBouncer::Config cfg;
  cfg.input_wav_path = src;
  cfg.output_wav_path = dir_ + "/bounce_out_48k.wav";
  cfg.output_sample_rate = 48000;
  ASSERT_EQ(ElementBouncer::Bounce(cfg), 0);

  WavReader out;
  ASSERT_TRUE(out.open(cfg.output_wav_path.c_str()));
  EXPECT_EQ(out.sample_rate(), 48000u);
  EXPECT_EQ(out.total_frames(), 48000u);  // 1 s at the target rate
  EXPECT_GT(PeakAt(out, 1000, 4096), 0.5f);
}

TEST_F(ElementBouncerTest, MatchedTargetRateIsPassthrough) {
  const std::string src = dir_ + "/bounce_48_1s.wav";
  ASSERT_TRUE(test_wav::write_sine(src, 1, 48000, 16, 440.f, 1.f));

  ElementBouncer::Config cfg;
  cfg.input_wav_path = src;
  cfg.output_wav_path = dir_ + "/bounce_out_pass.wav";
  cfg.output_sample_rate = 48000;
  ASSERT_EQ(ElementBouncer::Bounce(cfg), 0);

  WavReader out;
  ASSERT_TRUE(out.open(cfg.output_wav_path.c_str()));
  EXPECT_EQ(out.sample_rate(), 48000u);
  EXPECT_EQ(out.total_frames(), 48000u);
  EXPECT_GT(PeakAt(out, 1000, 4096), 0.5f);
}

TEST_F(ElementBouncerTest, PadsAtTargetRate) {
  // pad_to_frames is counted at the OUTPUT rate: a 1 s 44.1 kHz source
  // padded to 96000 target frames yields 1 s of signal + 1 s of
  // silence at 48 kHz.
  const std::string src = dir_ + "/bounce_441_pad.wav";
  ASSERT_TRUE(test_wav::write_sine(src, 1, 44100, 16, 440.f, 1.f));

  ElementBouncer::Config cfg;
  cfg.input_wav_path = src;
  cfg.output_wav_path = dir_ + "/bounce_out_pad.wav";
  cfg.output_sample_rate = 48000;
  cfg.pad_to_frames = 96000;
  ASSERT_EQ(ElementBouncer::Bounce(cfg), 0);

  WavReader out;
  ASSERT_TRUE(out.open(cfg.output_wav_path.c_str()));
  EXPECT_EQ(out.sample_rate(), 48000u);
  EXPECT_EQ(out.total_frames(), 96000u);
  EXPECT_GT(PeakAt(out, 1000, 4096), 0.5f);    // signal region
  EXPECT_LT(PeakAt(out, 60000, 4096), 1e-4f);  // pad region is silence
}

TEST_F(ElementBouncerTest, DrainsSincTailInsteadOfPadding) {
  // Regression for ES-83: at source EOF the bounce must flush the sinc
  // filter's tail (≈3 ms, ratio-stretched) as real audio instead of
  // leaving it to the silence pad. A full-scale tone downsampled
  // 48k -> 44.1k stretches the wing the most, so the dropped tail is the
  // largest. Before the fix the final ~130 output frames were pad zeros;
  // after it they carry the tone.
  const std::string src = dir_ + "/bounce_tail_48k.wav";
  ASSERT_TRUE(test_wav::write_sine(src, 1, 48000, 16, 1000.f, 0.5f));

  ElementBouncer::Config cfg;
  cfg.input_wav_path = src;
  cfg.output_wav_path = dir_ + "/bounce_tail_out.wav";
  cfg.output_sample_rate = 44100;
  ASSERT_EQ(ElementBouncer::Bounce(cfg), 0);

  WavReader out;
  ASSERT_TRUE(out.open(cfg.output_wav_path.c_str()));
  EXPECT_EQ(out.sample_rate(), 44100u);
  // 24000 in-frames * 44100/48000 = 22050; the drain replaces pad
  // content, so the total length is unchanged.
  const uint64_t total = out.total_frames();
  EXPECT_EQ(total, 22050u);
  // The final 64 frames must still carry the tone (peak ~full scale),
  // not the silence the pad would have written.
  EXPECT_GT(PeakAt(out, total - 64, 64), 0.3f);
}

TEST_F(ElementBouncerTest, DrainsSourceShorterThanSincPriming) {
  // Regression for ES-83: a source shorter than the sinc filter's priming
  // length (~143 input frames at SINC_BEST_QUALITY) never produces any
  // output through consume() — the filter swallows it while priming. The
  // bounce must still flush that content out at EOF. Before the fix the
  // early `break` on a zero-output consume() fired before draining ever
  // engaged, so the whole file bounced to silence. 96 frames at 48k
  // (2 ms) is well under the priming length.
  const std::string src = dir_ + "/bounce_short_48k.wav";
  ASSERT_TRUE(test_wav::write_sine(src, 1, 48000, 16, 1000.f, 0.002f));

  ElementBouncer::Config cfg;
  cfg.input_wav_path = src;
  cfg.output_wav_path = dir_ + "/bounce_short_out.wav";
  cfg.output_sample_rate = 44100;
  ASSERT_EQ(ElementBouncer::Bounce(cfg), 0);

  WavReader out;
  ASSERT_TRUE(out.open(cfg.output_wav_path.c_str()));
  EXPECT_EQ(out.sample_rate(), 44100u);
  // 96 in-frames * 44100/48000 ≈ 88 output frames.
  const uint64_t total = out.total_frames();
  EXPECT_EQ(total, 88u);
  // The tone must survive the drain rather than being lost to silence:
  // before the fix the entire output was pad zeros (peak == 0).
  EXPECT_GT(PeakAt(out, 0, static_cast<uint32_t>(total)), 0.3f);
}

TEST_F(ElementBouncerTest, TruncatesAtTargetRate) {
  // pad_to_frames below the scaled source length truncates: 1 s at
  // 44.1 kHz → 48 kHz would be 48000 frames; cap it at 24000.
  const std::string src = dir_ + "/bounce_441_trunc.wav";
  ASSERT_TRUE(test_wav::write_sine(src, 1, 44100, 16, 440.f, 1.f));

  ElementBouncer::Config cfg;
  cfg.input_wav_path = src;
  cfg.output_wav_path = dir_ + "/bounce_out_trunc.wav";
  cfg.output_sample_rate = 48000;
  cfg.pad_to_frames = 24000;
  ASSERT_EQ(ElementBouncer::Bounce(cfg), 0);

  WavReader out;
  ASSERT_TRUE(out.open(cfg.output_wav_path.c_str()));
  EXPECT_EQ(out.total_frames(), 24000u);
  EXPECT_GT(PeakAt(out, 1000, 4096), 0.5f);
}

}  // namespace
