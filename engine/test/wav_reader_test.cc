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

#include "io/wav_reader.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "test/test_wav_helper.h"
#include "wav/testing/fixture.h"

namespace {

// Write a structurally valid RIFF/WAVE file with an arbitrary fmt tag
// and a zero-filled data chunk (16-bit stereo framing).
bool WriteWavWithFormatTag(const std::string& path, uint16_t format_tag,
                           uint32_t data_bytes = 1024) {
  return wav::testing::WriteBytes(
      path, wav::testing::BuildRawFmtWav(
                wav::testing::FmtBody(format_tag, 2, 48000, 16), data_bytes));
}

class WavReaderTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = test_wav::temp_dir();
    mono_ = dir_ + "/sine_440hz_1ch_48k.wav";
    stereo_ = dir_ + "/sine_440hz_2ch_48k.wav";
    silence_ = dir_ + "/silence_1ch_48k.wav";
    impulse_ = dir_ + "/impulse_1ch_48k.wav";

    ASSERT_TRUE(test_wav::write_sine(mono_, 1, 48000, 16, 440.f, 1.f));
    ASSERT_TRUE(test_wav::write_sine(stereo_, 2, 48000, 16, 440.f, 1.f));
    ASSERT_TRUE(test_wav::write_silence(silence_, 1, 48000, 16, 1.f));
    ASSERT_TRUE(test_wav::write_impulse(impulse_, 48000, 16));
  }

  std::string dir_, mono_, stereo_, silence_, impulse_;
};

// ── open / file info ──────────────────────────────────────────────────────

TEST_F(WavReaderTest, OpensMonoFile) {
  WavReader r;
  EXPECT_TRUE(r.open(mono_.c_str()));
  EXPECT_TRUE(r.is_open());
  EXPECT_EQ(r.channels(), 1u);
  EXPECT_EQ(r.sample_rate(), 48000u);
  EXPECT_EQ(r.bit_depth(), 16u);
  EXPECT_EQ(r.total_frames(), 48000u);
}

TEST_F(WavReaderTest, OpensStereoFile) {
  WavReader r;
  EXPECT_TRUE(r.open(stereo_.c_str()));
  EXPECT_EQ(r.channels(), 2u);
  EXPECT_EQ(r.total_frames(), 48000u);
}

TEST_F(WavReaderTest, OpenNonExistentFileFails) {
  WavReader r;
  EXPECT_FALSE(r.open("/nonexistent/path/file.wav"));
  EXPECT_FALSE(r.is_open());
}

// Issue ES-41: compressed/unsupported format tags must be rejected at
// open, not misread or silently decoded to zero frames.
TEST_F(WavReaderTest, OpenRejectsUnsupportedFormatTags) {
  const struct {
    uint16_t tag;
    const char* name;
  } kUnsupported[] = {
      {0x0002, "ADPCM"}, {0x0006, "A-law"}, {0x0007, "mu-law"},
      {0x0055, "MP3"},   {0x0161, "WMA"},
  };
  for (const auto& fmt : kUnsupported) {
    const std::string path = dir_ + "/badtag.wav";
    ASSERT_TRUE(WriteWavWithFormatTag(path, fmt.tag));
    WavReader r;
    EXPECT_FALSE(r.open(path.c_str())) << fmt.name;
    EXPECT_FALSE(r.is_open()) << fmt.name;
  }
}

TEST_F(WavReaderTest, OpenAcceptsPcmFormatTag) {
  const std::string path = dir_ + "/pcmtag.wav";
  ASSERT_TRUE(WriteWavWithFormatTag(path, 0x0001));
  WavReader r;
  EXPECT_TRUE(r.open(path.c_str()));
  EXPECT_EQ(r.total_frames(), 1024u / 4u);
}

// ── read ──────────────────────────────────────────────────────────────────

TEST_F(WavReaderTest, ReadFramesFromMono) {
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));

  // Pre-allocate buffer.
  constexpr uint32_t kCh = 1, kCap = 1024;
  float storage[kCh * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;

  uint32_t got = r.read(buf, kCap);
  EXPECT_EQ(got, kCap);
  EXPECT_EQ(buf.frames, kCap);
  EXPECT_EQ(r.cursor(), static_cast<uint64_t>(kCap));

  // At least one sample should be non-zero (sine wave).
  bool any_nonzero = false;
  for (uint32_t i = 0; i < got; ++i) {
    if (buf.channel(0)[i] != 0.0f) {
      any_nonzero = true;
      break;
    }
  }
  EXPECT_TRUE(any_nonzero);
}

TEST_F(WavReaderTest, ReadLargerThanScratchBatchesCorrectly) {
  // A single read() larger than kMaxScratchFrames (1024) exercises the
  // internal batching loop's destination offsetting — an off-by-one
  // there is audible corruption. Compare against two reference reads.
  constexpr uint32_t kBig = WavReader::kMaxScratchFrames * 2 + 500;
  std::vector<float> big_storage(kBig, 0.0f);
  AudioBuffer big;
  big.data = big_storage.data();
  big.channels = 1;
  big.frames = 0;
  big.capacity_frames = kBig;

  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));
  ASSERT_EQ(r.read(big, kBig), kBig);

  // Reference: the same span read in two chunks by a fresh reader.
  std::vector<float> ref_storage(kBig, 0.0f);
  AudioBuffer ref;
  ref.data = ref_storage.data();
  ref.channels = 1;
  ref.frames = 0;
  ref.capacity_frames = kBig;
  WavReader r2;
  ASSERT_TRUE(r2.open(mono_.c_str()));
  constexpr uint32_t kSplit = 700;
  ASSERT_EQ(r2.read(ref, kSplit), kSplit);
  AudioBuffer rest = ref;
  rest.data = ref_storage.data() + kSplit;
  rest.capacity_frames = kBig - kSplit;
  ASSERT_EQ(r2.read(rest, kBig - kSplit), kBig - kSplit);

  for (uint32_t i = 0; i < kBig; ++i) {
    ASSERT_EQ(big_storage[i], ref_storage[i]) << "frame " << i;
  }
}

TEST_F(WavReaderTest, ReadDropsFileChannelsBeyondDestination) {
  // Stereo file into a mono destination: channel 0 decodes into the
  // buffer, channel 1 lands in scratch and is dropped.
  WavReader r;
  ASSERT_TRUE(r.open(stereo_.c_str()));

  constexpr uint32_t kCap = 256;
  float storage[kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = 1;
  buf.frames = 0;
  buf.capacity_frames = kCap;
  ASSERT_EQ(r.read(buf, kCap), kCap);

  // The mono file carries the identical sine in channel 0.
  WavReader mono_ref;
  ASSERT_TRUE(mono_ref.open(mono_.c_str()));
  float ref_storage[kCap] = {};
  AudioBuffer ref = buf;
  ref.data = ref_storage;
  ASSERT_EQ(mono_ref.read(ref, kCap), kCap);
  for (uint32_t i = 0; i < kCap; ++i) {
    ASSERT_EQ(storage[i], ref_storage[i]) << "frame " << i;
  }
}

TEST_F(WavReaderTest, ReadZeroFillsDestinationChannelsBeyondFile) {
  // Mono file into a stereo destination: channel 1 must come back
  // silent even when the buffer starts out dirty.
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));

  constexpr uint32_t kCh = 2, kCap = 256;
  float storage[kCh * kCap];
  std::fill(storage, storage + kCh * kCap, 0.5f);
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;
  ASSERT_EQ(r.read(buf, kCap), kCap);

  bool ch0_nonzero = false;
  for (uint32_t i = 0; i < kCap; ++i) {
    if (buf.channel(0)[i] != 0.0f) ch0_nonzero = true;
    ASSERT_EQ(buf.channel(1)[i], 0.0f) << "frame " << i;
  }
  EXPECT_TRUE(ch0_nonzero);
}

TEST_F(WavReaderTest, ReadFromSilenceFileYieldsZeros) {
  WavReader r;
  ASSERT_TRUE(r.open(silence_.c_str()));

  constexpr uint32_t kCh = 1, kCap = 512;
  float storage[kCh * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;

  uint32_t got = r.read(buf, kCap);
  EXPECT_GT(got, 0u);
  for (uint32_t i = 0; i < got; ++i) {
    EXPECT_FLOAT_EQ(buf.channel(0)[i], 0.0f);
  }
}

TEST_F(WavReaderTest, ReadImpulseFileFirstSampleIsNonZero) {
  WavReader r;
  ASSERT_TRUE(r.open(impulse_.c_str()));

  constexpr uint32_t kCh = 1, kCap = 64;
  float storage[kCh * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;

  uint32_t got = r.read(buf, kCap);
  EXPECT_GT(got, 0u);

  // First sample should be close to +1.0 (32767/32768).
  EXPECT_GT(buf.channel(0)[0], 0.9f);

  // Remaining samples should be zero.
  for (uint32_t i = 1; i < got; ++i) {
    EXPECT_FLOAT_EQ(buf.channel(0)[i], 0.0f);
  }
}

// ── seek ──────────────────────────────────────────────────────────────────

TEST_F(WavReaderTest, SeekUpdatesPosition) {
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));
  EXPECT_TRUE(r.seek(24000));
  EXPECT_EQ(r.cursor(), 24000u);
}

TEST_F(WavReaderTest, SeekAndReadAfterSeek) {
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));

  // Seek to halfway point.
  ASSERT_TRUE(r.seek(24000));

  constexpr uint32_t kCh = 1, kCap = 256;
  float storage[kCh * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;

  uint32_t got = r.read(buf, kCap);
  EXPECT_EQ(got, kCap);
  EXPECT_EQ(r.cursor(), 24000u + kCap);
}

TEST_F(WavReaderTest, ReadAtEofReturnsZero) {
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));
  ASSERT_TRUE(r.seek(r.total_frames()));

  constexpr uint32_t kCh = 1, kCap = 256;
  float storage[kCh * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;

  uint32_t got = r.read(buf, kCap);
  EXPECT_EQ(got, 0u);
}

// Regression: every read() exit must publish out_buffer.frames, including
// the zero-request and at-EOF early returns. The resample path in
// AudioGraph::process consumes rin.frames after the read; a stale count
// from the previous read re-feeds already-consumed samples into the
// resampler — an audible click per occurrence (the 96 kHz device /
// 48 kHz file regression).
TEST_F(WavReaderTest, ReadEarlyReturnsResetBufferFrames) {
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));

  constexpr uint32_t kCh = 1, kCap = 256;
  float storage[kCh * kCap] = {};
  AudioBuffer buf;
  buf.data = storage;
  buf.channels = kCh;
  buf.frames = 0;
  buf.capacity_frames = kCap;

  // Seed a stale non-zero count with a normal read.
  ASSERT_GT(r.read(buf, kCap), 0u);
  ASSERT_EQ(buf.frames, kCap);

  // Zero-frame request: count must reset, not stay stale.
  EXPECT_EQ(r.read(buf, 0), 0u);
  EXPECT_EQ(buf.frames, 0u);

  // At EOF: same contract.
  buf.frames = kCap;
  ASSERT_TRUE(r.seek(r.total_frames()));
  EXPECT_EQ(r.read(buf, kCap), 0u);
  EXPECT_EQ(buf.frames, 0u);

  // Closed reader: same contract.
  buf.frames = kCap;
  r.close();
  EXPECT_EQ(r.read(buf, kCap), 0u);
  EXPECT_EQ(buf.frames, 0u);
}

// ── close ────────────────────────────────────────────────────────────────

TEST_F(WavReaderTest, CloseAndReopenWorks) {
  WavReader r;
  ASSERT_TRUE(r.open(mono_.c_str()));
  r.close();
  EXPECT_FALSE(r.is_open());
  EXPECT_TRUE(r.open(stereo_.c_str()));
  EXPECT_EQ(r.channels(), 2u);
}

}  // namespace
