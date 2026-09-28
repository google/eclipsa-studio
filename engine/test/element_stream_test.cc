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

// ElementStream (bounce/element_stream.h): the streaming core behind
// both the WAV bounce and the IAMF push export (ES-480). These tests pin
// (a) equivalence with ElementBouncer's file output — the two paths must
// stay sample-identical up to output quantization — and (b) pull-size
// independence, so the push exporter's frame-sized pulls see exactly
// what the bounce's 1024-frame loop saw.

#include "bounce/element_stream.h"

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "bounce/element_bouncer.h"
#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "io/wav_reader.h"
#include "test/test_wav_helper.h"

namespace {

using eclipsa_studio::ElementBouncer;
using eclipsa_studio::ElementStream;

// Pulls the whole stream in `chunk`-frame requests, returning planar
// data channel-major.
std::vector<std::vector<float>> PullAll(ElementStream& stream, uint32_t chunk) {
  std::vector<std::vector<float>> out(stream.channels());
  std::vector<float> storage(static_cast<size_t>(stream.channels()) *
                             ElementStream::kMaxPullFrames);
  AudioBuffer buf;
  buf.data = storage.data();
  buf.channels = stream.channels();
  buf.frames = 0;
  buf.capacity_frames = ElementStream::kMaxPullFrames;
  while (true) {
    const uint32_t got = stream.Pull(buf, chunk);
    if (got == 0) break;
    for (uint32_t ch = 0; ch < stream.channels(); ++ch) {
      const float* src = buf.channel(ch);
      out[ch].insert(out[ch].end(), src, src + got);
    }
  }
  return out;
}

// Reads a whole WAV file as planar float via the io adapter.
std::vector<std::vector<float>> ReadAll(const std::string& path,
                                        uint32_t* sample_rate = nullptr) {
  WavReader reader;
  EXPECT_TRUE(reader.open(path.c_str()));
  if (sample_rate != nullptr) *sample_rate = reader.sample_rate();
  std::vector<std::vector<float>> out(reader.channels());
  std::vector<float> storage(static_cast<size_t>(reader.channels()) * 1024);
  AudioBuffer buf;
  buf.data = storage.data();
  buf.channels = reader.channels();
  buf.frames = 0;
  buf.capacity_frames = 1024;
  while (true) {
    const uint32_t got = reader.read(buf, 1024);
    if (got == 0) break;
    for (uint32_t ch = 0; ch < reader.channels(); ++ch) {
      const float* src = buf.channel(ch);
      out[ch].insert(out[ch].end(), src, src + got);
    }
  }
  return out;
}

class ElementStreamTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = test_wav::temp_dir();
    source_ = dir_ + "/stream_src.wav";
    // 4800 frames of 440 Hz stereo at 48 kHz, 16-bit.
    ASSERT_TRUE(test_wav::write_sine_frames(source_, 2, 48000, 16, 440.0f,
                                            kSourceFrames, 0.5f));
  }

  static constexpr int kSourceFrames = 4800;
  std::string dir_, source_;
};

TEST_F(ElementStreamTest, MatchesBouncedFileWithGainRoutingAndPad) {
  // Swap channels, apply gain, pad — the full pipeline minus resampling
  // (which has its own test below).
  ElementBouncer::Config bounce;
  bounce.input_wav_path = source_;
  bounce.output_wav_path = dir_ + "/stream_bounced.wav";
  bounce.gain_db = -6.0f;
  bounce.routing = {1, 0};
  bounce.pad_to_frames = kSourceFrames + 1000;
  ASSERT_EQ(ElementBouncer::Bounce(bounce), 0);
  const auto bounced = ReadAll(bounce.output_wav_path);

  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.gain_db = bounce.gain_db;
  cfg.routing = bounce.routing;
  cfg.pad_to_frames = bounce.pad_to_frames;
  ASSERT_TRUE(stream.Open(cfg));
  EXPECT_EQ(stream.total_frames(), bounce.pad_to_frames);
  const auto streamed = PullAll(stream, 1024);

  ASSERT_EQ(streamed.size(), bounced.size());
  ASSERT_EQ(streamed[0].size(), bounced[0].size());
  // The bounced file went through 16-bit quantization; the stream is the
  // pre-quantization float pipeline. Half an LSB of tolerance.
  constexpr float kTol = 0.5f / 32768.0f;
  for (size_t ch = 0; ch < streamed.size(); ++ch) {
    for (size_t f = 0; f < streamed[ch].size(); ++f) {
      ASSERT_NEAR(streamed[ch][f], bounced[ch][f], kTol)
          << "ch " << ch << " frame " << f;
    }
  }
}

TEST_F(ElementStreamTest, MatchesBouncedFileWhenResampling) {
  ElementBouncer::Config bounce;
  bounce.input_wav_path = source_;
  bounce.output_wav_path = dir_ + "/stream_bounced_rs.wav";
  bounce.output_sample_rate = 44100;
  ASSERT_EQ(ElementBouncer::Bounce(bounce), 0);
  uint32_t bounced_rate = 0;
  const auto bounced = ReadAll(bounce.output_wav_path, &bounced_rate);
  EXPECT_EQ(bounced_rate, 44100u);

  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.output_sample_rate = 44100;
  ASSERT_TRUE(stream.Open(cfg));
  EXPECT_EQ(stream.sample_rate(), 44100u);
  const auto streamed = PullAll(stream, 1024);

  ASSERT_EQ(streamed[0].size(), bounced[0].size());
  constexpr float kTol = 0.5f / 32768.0f;
  for (size_t ch = 0; ch < streamed.size(); ++ch) {
    for (size_t f = 0; f < streamed[ch].size(); ++f) {
      ASSERT_NEAR(streamed[ch][f], bounced[ch][f], kTol)
          << "ch " << ch << " frame " << f;
    }
  }
}

TEST_F(ElementStreamTest, PullSizeDoesNotChangeOutput) {
  // The push exporter pulls codec-frame-sized blocks (e.g. 960 for
  // Opus); the bounce pulls 1024. Same samples either way — including
  // through a resampler, whose internal carry must not leak into the
  // delivery boundaries.
  ElementStream a;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.output_sample_rate = 44100;
  ASSERT_TRUE(a.Open(cfg));
  const auto big = PullAll(a, 1024);

  ElementStream b;
  ASSERT_TRUE(b.Open(cfg));
  const auto odd = PullAll(b, 313);

  ASSERT_EQ(big[0].size(), odd[0].size());
  for (size_t ch = 0; ch < big.size(); ++ch) {
    for (size_t f = 0; f < big[ch].size(); ++f) {
      ASSERT_EQ(big[ch][f], odd[ch][f]) << "ch " << ch << " frame " << f;
    }
  }
}

TEST_F(ElementStreamTest, TruncatesToPadTarget) {
  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.pad_to_frames = 1000;  // Shorter than the 4800-frame source.
  ASSERT_TRUE(stream.Open(cfg));
  const auto streamed = PullAll(stream, 1024);
  EXPECT_EQ(streamed[0].size(), 1000u);
}

TEST_F(ElementStreamTest, ShortSourceSurvivesResamplerPriming) {
  // ES-83: a source shorter than the sinc filter's priming length must
  // still deliver its audio (drained from the filter), not silence.
  const std::string tiny = dir_ + "/stream_tiny.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(tiny, 1, 48000, 16, 1000.0f,
                                          /*total_frames=*/100, 0.5f));
  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = tiny;
  cfg.output_sample_rate = 44100;
  cfg.pad_to_frames = 256;
  ASSERT_TRUE(stream.Open(cfg));
  const auto streamed = PullAll(stream, 256);
  ASSERT_EQ(streamed[0].size(), 256u);
  double energy = 0.0;
  for (const float s : streamed[0]) energy += static_cast<double>(s) * s;
  EXPECT_GT(energy, 0.01) << "short source resampled to silence (ES-83)";
}

TEST_F(ElementStreamTest, GainInducedClipsAreCountedExactly) {
  // +12 dB on the amp-0.5 sine pushes peaks to ~2.0. The expected count
  // is computed with the same float math the stream applies (per-sample
  // multiply by pow(10, dB/20)), so the comparison is exact.
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.gain_db = 12.0f;

  const auto src = ReadAll(source_);
  const float g = std::pow(10.0f, cfg.gain_db / 20.0f);
  uint64_t expected_count = 0;
  float expected_peak = 0.0f;
  for (const auto& ch : src) {
    for (const float s : ch) {
      const float a = std::fabs(s * g);
      if (a > expected_peak) expected_peak = a;
      if (a > 1.0f) ++expected_count;
    }
  }
  ASSERT_GT(expected_count, 0u) << "fixture no longer clips at +12 dB";

  ElementStream stream;
  ASSERT_TRUE(stream.Open(cfg));
  PullAll(stream, 1024);
  EXPECT_EQ(stream.clipped_samples(), expected_count);
  EXPECT_FLOAT_EQ(stream.peak_linear(), expected_peak);
}

TEST_F(ElementStreamTest, UnityGainMemcpyBranchCounts) {
  // Unity gain takes the memcpy fast path in Pull(); the scan must
  // still see over-unity samples from a float32 source. Exactly ±1.0
  // is NOT counted (strict >): full-scale integer sources legitimately
  // hit -1.0, and a downstream ±1.0 clamp maps it to itself.
  const std::string hot = dir_ + "/stream_hot_f32.wav";
  const std::vector<float> samples = {0.25f, 1.0f, -1.0f, 1.5f, -2.0f, 0.0f};
  ASSERT_TRUE(test_wav::write_float32_frames(hot, 1, 48000, samples));

  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = hot;
  ASSERT_TRUE(stream.Open(cfg));
  const auto streamed = PullAll(stream, 1024);
  ASSERT_EQ(streamed[0].size(), samples.size());
  EXPECT_EQ(stream.clipped_samples(), 2u);  // 1.5 and -2.0 only.
  EXPECT_FLOAT_EQ(stream.peak_linear(), 2.0f);
}

TEST_F(ElementStreamTest, InRangeSourceCountsZero) {
  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  ASSERT_TRUE(stream.Open(cfg));
  PullAll(stream, 1024);
  EXPECT_EQ(stream.clipped_samples(), 0u);
  EXPECT_GT(stream.peak_linear(), 0.4f);
  EXPECT_LE(stream.peak_linear(), 0.5f);
}

TEST_F(ElementStreamTest, CountersResetOnOpen) {
  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.gain_db = 12.0f;
  ASSERT_TRUE(stream.Open(cfg));
  PullAll(stream, 1024);
  ASSERT_GT(stream.clipped_samples(), 0u);

  cfg.gain_db = 0.0f;
  ASSERT_TRUE(stream.Open(cfg));
  EXPECT_EQ(stream.clipped_samples(), 0u);
  EXPECT_EQ(stream.peak_linear(), 0.0f);
  PullAll(stream, 1024);
  EXPECT_EQ(stream.clipped_samples(), 0u);
}

TEST_F(ElementStreamTest, SilencedChannelsDoNotCount) {
  // Route only ch0 through, silence the other output; the count must
  // equal the single-channel expectation, not double it.
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.gain_db = 12.0f;
  cfg.routing = {0, -1};

  const auto src = ReadAll(source_);
  const float g = std::pow(10.0f, cfg.gain_db / 20.0f);
  uint64_t expected_count = 0;
  for (const float s : src[0]) {
    if (std::fabs(s * g) > 1.0f) ++expected_count;
  }
  ASSERT_GT(expected_count, 0u);

  ElementStream stream;
  ASSERT_TRUE(stream.Open(cfg));
  PullAll(stream, 1024);
  EXPECT_EQ(stream.clipped_samples(), expected_count);
}

TEST_F(ElementStreamTest, RoutingSilencesUnmappedChannels) {
  ElementStream stream;
  ElementStream::Config cfg;
  cfg.input_wav_path = source_;
  cfg.routing = {0, -1, 7};  // ch1 explicit silence, ch2 out of range.
  ASSERT_TRUE(stream.Open(cfg));
  EXPECT_EQ(stream.channels(), 3u);
  const auto streamed = PullAll(stream, 1024);
  double e0 = 0.0, e1 = 0.0, e2 = 0.0;
  for (size_t f = 0; f < streamed[0].size(); ++f) {
    e0 += static_cast<double>(streamed[0][f]) * streamed[0][f];
    e1 += static_cast<double>(streamed[1][f]) * streamed[1][f];
    e2 += static_cast<double>(streamed[2][f]) * streamed[2][f];
  }
  EXPECT_GT(e0, 0.01);
  EXPECT_EQ(e1, 0.0);
  EXPECT_EQ(e2, 0.0);
}

}  // namespace
