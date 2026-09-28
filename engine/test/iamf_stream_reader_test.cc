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

// Tests for IamfStreamReader against a real iamf-tools fixture.
//
// Fixture: engine/test/fixtures/noise_3s_stereo_opus.iamf — 3 s of
// noise, one stereo channel-based AE, 48 kHz, Opus (960-frame TUs).
// Vendored from iamf-tools upstream; see fixtures/README.md.
//
// The tests deliberately avoid asserting exact TU counts / total frame
// counts — pre-skip / end-trim / trim-adjusted timelines mean the
// upstream contract only guarantees the stream plays back for the
// advertised total-samples count, not any particular TU cadence.

#include "iamf/iamf_stream_reader.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"

namespace {

constexpr uint32_t kExpectedChannels = 2;  // stereo AE
constexpr uint32_t kExpectedSampleRate = 48000;
constexpr uint32_t kMaxFrames = 4096;

// Try candidate paths to find the fixture across bazel runfiles layouts
// and a plain `bazel test` invocation. Returns an empty path if none
// resolves.
std::string FindFixture(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";

  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string(srcdir) + "/eclipsa_studio_engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
      std::string("engine/test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

std::vector<uint8_t> LoadFixture(const char* name) {
  const std::string path = FindFixture(name);
  if (path.empty()) return {};
  std::ifstream in(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

struct ScratchBuffer {
  explicit ScratchBuffer(uint32_t ch) : storage(ch * kMaxFrames, 0.0f) {
    buf.data = storage.data();
    buf.channels = ch;
    buf.capacity_frames = kMaxFrames;
    buf.frames = 0;
  }
  std::vector<float> storage;
  AudioBuffer buf;
};

constexpr char kStereoFixture[] = "noise_3s_stereo_opus.iamf";

TEST(IamfStreamReaderTest, OpensAndReportsDescriptors) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty()) << "fixture missing";

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()))
      << reader.last_error();
  EXPECT_TRUE(reader.is_open());
  EXPECT_EQ(reader.channels(), kExpectedChannels);
  EXPECT_EQ(reader.sample_rate(), kExpectedSampleRate);
  // The fixture file's advertised duration depends on how upstream
  // generated it (trim-adjusted total). Assert it's at least one TU
  // and not absurdly large.
  EXPECT_GT(reader.total_frames(), 960u);
  EXPECT_LT(reader.total_frames(), kExpectedSampleRate * 60u);
  EXPECT_EQ(reader.cursor(), 0u);
}

TEST(IamfStreamReaderTest, RejectsEmptyBuffer) {
  IamfStreamReader reader;
  EXPECT_FALSE(reader.open_from_memory(nullptr, 0));
  EXPECT_FALSE(reader.is_open());
  EXPECT_FALSE(reader.last_error().empty());
  EXPECT_NE(reader.last_error().find("invalid_argument:"), std::string::npos);
}

TEST(IamfStreamReaderTest, RejectsMalformedBuffer) {
  // A handful of random bytes is not a valid IAMF stream.
  const std::vector<uint8_t> garbage = {0xDE, 0xAD, 0xBE, 0xEF,
                                        0xCA, 0xFE, 0xBA, 0xBE};
  IamfStreamReader reader;
  EXPECT_FALSE(reader.open_from_memory(garbage.data(), garbage.size()));
  EXPECT_FALSE(reader.is_open());
  EXPECT_FALSE(reader.last_error().empty());
}

TEST(IamfStreamReaderTest, RejectsOutOfRangeAeIndex) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  // Fixture has one AE; index 99 is out of range.
  EXPECT_FALSE(reader.open_from_memory(bytes.data(), bytes.size(), 99));
  EXPECT_FALSE(reader.is_open());
  EXPECT_NE(reader.last_error().find("invalid_argument:"), std::string::npos);
}

TEST(IamfStreamReaderTest, ReadAcrossTuBoundary) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));

  ScratchBuffer out(kExpectedChannels);
  // Not a round multiple of any likely TU size — forces the reader to
  // span at least two TUs (Opus TUs are 960 frames at 48 kHz).
  const uint32_t kRequest = 1500;
  const uint32_t got = reader.read(out.buf, kRequest);
  EXPECT_EQ(got, kRequest);
  EXPECT_EQ(out.buf.frames, kRequest);
  EXPECT_EQ(reader.cursor(), kRequest);
}

TEST(IamfStreamReaderTest, ProducesSomeNonZeroSamples) {
  // The fixture is noise, not silence; at least some samples must be
  // non-zero within the first buffer-full.
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));

  ScratchBuffer out(kExpectedChannels);
  const uint32_t got = reader.read(out.buf, 2048);
  ASSERT_GT(got, 0u);
  bool any_non_zero = false;
  for (uint32_t c = 0; c < kExpectedChannels && !any_non_zero; ++c) {
    for (uint32_t f = 0; f < got; ++f) {
      if (out.buf.channel(c)[f] != 0.0f) {
        any_non_zero = true;
        break;
      }
    }
  }
  EXPECT_TRUE(any_non_zero) << "decoded noise fixture produced all-zero output";
}

TEST(IamfStreamReaderTest, ReadsUpToTotalFramesThenEof) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));
  const uint64_t total = reader.total_frames();

  ScratchBuffer out(kExpectedChannels);
  uint64_t total_got = 0;
  for (int i = 0; i < 10000; ++i) {  // safety bound
    const uint32_t got = reader.read(out.buf, kMaxFrames);
    if (got == 0) break;
    total_got += got;
  }
  EXPECT_EQ(total_got, total);
  EXPECT_EQ(reader.cursor(), total);
  // Past EOF returns 0.
  EXPECT_EQ(reader.read(out.buf, kMaxFrames), 0u);
}

TEST(IamfStreamReaderTest, SeekInvalidatesTuCacheAndResetsCursor) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));
  const uint64_t total = reader.total_frames();
  ASSERT_GT(total, 2000u);

  ScratchBuffer out(kExpectedChannels);
  ASSERT_EQ(reader.read(out.buf, 500), 500u);
  EXPECT_EQ(reader.cursor(), 500u);

  // Seek somewhere past the first TU boundary but inside the fixture.
  const uint64_t kTarget = total / 2;
  ASSERT_TRUE(reader.seek(kTarget)) << reader.last_error();
  EXPECT_EQ(reader.cursor(), kTarget);

  const uint32_t want = 512;
  const uint32_t got = reader.read(out.buf, want);
  // Reader must succeed and not overshoot EOF.
  EXPECT_GT(got, 0u);
  EXPECT_LE(got, want);
  EXPECT_EQ(reader.cursor(), kTarget + got);
}

TEST(IamfStreamReaderTest, SeekPastEndClampsToTotal) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));
  const uint64_t total = reader.total_frames();

  // Upstream returns invalid_argument for sample_pos >= total. The
  // reader clamps to total before calling, which upstream may still
  // reject — accept either outcome and verify cursor state.
  const bool seek_ok = reader.seek(total + 100000);
  if (seek_ok) {
    EXPECT_EQ(reader.cursor(), total);
    ScratchBuffer out(kExpectedChannels);
    EXPECT_EQ(reader.read(out.buf, 1024), 0u);
  } else {
    EXPECT_FALSE(reader.last_error().empty());
  }
}

TEST(IamfStreamReaderTest, CloseAfterOpenIsSafe) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));
  reader.close();
  EXPECT_FALSE(reader.is_open());
  EXPECT_EQ(reader.channels(), 0u);
  EXPECT_EQ(reader.total_frames(), 0u);

  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));
  EXPECT_TRUE(reader.is_open());
}

TEST(IamfStreamReaderTest, ExtraOutputChannelsAreSilenced) {
  const auto bytes = LoadFixture(kStereoFixture);
  ASSERT_FALSE(bytes.empty());

  IamfStreamReader reader;
  ASSERT_TRUE(reader.open_from_memory(bytes.data(), bytes.size()));

  ScratchBuffer out(4);
  // Pre-poison storage so we can detect any write.
  for (uint32_t c = 0; c < out.buf.channels; ++c) {
    for (uint32_t f = 0; f < kMaxFrames; ++f) {
      out.buf.channel(c)[f] = 0.5f;
    }
  }
  const uint32_t got = reader.read(out.buf, 128);
  ASSERT_EQ(got, 128u);
  for (uint32_t c = kExpectedChannels; c < 4; ++c) {
    for (uint32_t f = 0; f < got; ++f) {
      ASSERT_EQ(out.buf.channel(c)[f], 0.0f)
          << "extra channel not silenced at ch=" << c << " f=" << f;
    }
  }
}

}  // namespace
