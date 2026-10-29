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

//
// The conformance matrix: every container × sample format × fmt variant ×
// channel count is generated as a fixture and must open with exactly the
// declared properties and decode sample-exactly against the reference ramp,
// in both delivery conventions. Plus ds64 placement, ranged reads, metadata
// extraction and the chunk inventory.

#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "wav/reader.h"
#include "wav/testing/fixture.h"
#include "wav/types.h"

namespace wav {
namespace {

namespace wt = wav::testing;

const Container kContainers[] = {Container::kRiff, Container::kRf64,
                                 Container::kBw64};
const SampleFormat kFormats[] = {
    SampleFormat::kUint8, SampleFormat::kInt16,   SampleFormat::kInt24,
    SampleFormat::kInt32, SampleFormat::kFloat32, SampleFormat::kFloat64};
const uint16_t kChannelCounts[] = {1, 2, 16, 32, 33};

const char* ContainerName(Container c) {
  switch (c) {
    case Container::kRiff:
      return "riff";
    case Container::kRf64:
      return "rf64";
    case Container::kBw64:
      return "bw64";
  }
  return "?";
}

// Compares a planar float decode against the reference ramp. Reports only
// the first mismatch to keep failure logs readable.
::testing::AssertionResult FloatDecodeMatches(
    const std::vector<std::vector<float>>& got, SampleFormat format,
    uint64_t start_frame, uint64_t frames, uint16_t channels) {
  if (got.size() != channels) {
    return ::testing::AssertionFailure()
           << "channel count " << got.size() << " != " << channels;
  }
  for (uint16_t c = 0; c < channels; ++c) {
    if (got[c].size() != frames) {
      return ::testing::AssertionFailure()
             << "channel " << c << " has " << got[c].size() << " frames, want "
             << frames;
    }
    for (uint64_t n = 0; n < frames; ++n) {
      const float want = wt::ExpectedFloat(format, start_frame + n, c);
      if (got[c][n] != want) {
        return ::testing::AssertionFailure()
               << "sample mismatch at frame " << (start_frame + n)
               << " channel " << c << ": got " << got[c][n] << ", want "
               << want;
      }
    }
  }
  return ::testing::AssertionSuccess();
}

::testing::AssertionResult LjDecodeMatches(
    const std::vector<std::vector<int32_t>>& got, SampleFormat format,
    uint64_t start_frame, uint64_t frames, uint16_t channels) {
  if (got.size() != channels) {
    return ::testing::AssertionFailure()
           << "channel count " << got.size() << " != " << channels;
  }
  for (uint16_t c = 0; c < channels; ++c) {
    if (got[c].size() != frames) {
      return ::testing::AssertionFailure()
             << "channel " << c << " has " << got[c].size() << " frames, want "
             << frames;
    }
    for (uint64_t n = 0; n < frames; ++n) {
      const int32_t want = wt::ExpectedInt32Lj(format, start_frame + n, c);
      if (got[c][n] != want) {
        return ::testing::AssertionFailure()
               << "sample mismatch at frame " << (start_frame + n)
               << " channel " << c << ": got " << got[c][n] << ", want "
               << want;
      }
    }
  }
  return ::testing::AssertionSuccess();
}

// 48 frames fit in one decode tile of 256 frames; 600 cross two full tiles
// and end in a partial one.
TEST(ReaderMatrix, AcceptsAndDecodesEveryCell) {
  int idx = 0;
  for (const uint32_t frames : {48u, 600u}) {
    for (const Container container : kContainers) {
      for (const SampleFormat format : kFormats) {
        for (const bool extensible : {false, true}) {
          for (const uint16_t channels : kChannelCounts) {
            SCOPED_TRACE(std::string(ContainerName(container)) + "/" +
                         SampleFormatName(format) +
                         (extensible ? "/ext" : "/plain") + "/" +
                         std::to_string(channels) + "ch");
            wt::FixtureSpec spec;
            spec.container = container;
            spec.format = format;
            spec.extensible = extensible;
            spec.channels = channels;
            spec.num_frames = frames;
            const std::string path =
                wt::WriteFixture("matrix_" + std::to_string(idx++), spec);

            auto r = Reader::Open(path);
            ASSERT_TRUE(r.ok()) << r.error();
            const Info& info = r->info();
            EXPECT_EQ(info.container, container);
            EXPECT_EQ(info.format, format);
            EXPECT_EQ(info.channels, channels);
            EXPECT_EQ(info.sample_rate, 48000u);
            EXPECT_EQ(info.num_frames, frames);
            EXPECT_EQ(info.extensible, extensible);
            EXPECT_EQ(info.channel_mask,
                      extensible ? wt::FixtureChannelMask(channels) : 0u);
            EXPECT_EQ(info.valid_bits, extensible ? BitsPerSample(format) : 0);

            std::vector<std::vector<float>> f;
            auto nf = r->ReadPlanarFloat(0, frames, f);
            ASSERT_TRUE(nf.ok()) << nf.error();
            ASSERT_EQ(*nf, frames);
            EXPECT_TRUE(FloatDecodeMatches(f, format, 0, frames, channels));

            std::vector<std::vector<int32_t>> lj;
            auto nl = r->ReadPlanarInt32LeftJustified(0, frames, lj);
            ASSERT_TRUE(nl.ok()) << nl.error();
            ASSERT_EQ(*nl, frames);
            EXPECT_TRUE(LjDecodeMatches(lj, format, 0, frames, channels));
          }
        }
      }
    }
  }
}

// Ranged reads that start inside a decode tile and cross tile boundaries
// decode the same samples as a read from frame 0.
TEST(ReaderMatrix, RangedReadsAcrossDecodeTilesAreExact) {
  int idx = 0;
  for (const SampleFormat format : kFormats) {
    SCOPED_TRACE(SampleFormatName(format));
    wt::FixtureSpec spec;
    spec.format = format;
    spec.channels = 3;
    spec.num_frames = 600;
    const std::string path =
        wt::WriteFixture("tiles_" + std::to_string(idx++), spec);
    auto r = Reader::Open(path);
    ASSERT_TRUE(r.ok()) << r.error();

    for (const auto& [start, count] : {std::pair<uint64_t, uint64_t>{300, 300},
                                       std::pair<uint64_t, uint64_t>{100, 400},
                                       std::pair<uint64_t, uint64_t>{255, 2}}) {
      SCOPED_TRACE("start " + std::to_string(start) + " count " +
                   std::to_string(count));
      std::vector<std::vector<float>> f;
      auto nf = r->ReadPlanarFloat(start, count, f);
      ASSERT_TRUE(nf.ok()) << nf.error();
      ASSERT_EQ(*nf, count);
      EXPECT_TRUE(FloatDecodeMatches(f, format, start, count, 3));

      std::vector<std::vector<int32_t>> lj;
      auto nl = r->ReadPlanarInt32LeftJustified(start, count, lj);
      ASSERT_TRUE(nl.ok()) << nl.error();
      ASSERT_EQ(*nl, count);
      EXPECT_TRUE(LjDecodeMatches(lj, format, start, count, 3));
    }
  }
}

TEST(ReaderMatrix, RangedReadsAreExactAndClipped) {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kInt24;
  spec.channels = 2;
  spec.num_frames = 48;
  const std::string path = wt::WriteFixture("ranged", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();

  std::vector<std::vector<float>> f;
  auto n = r->ReadPlanarFloat(17, 19, f);
  ASSERT_TRUE(n.ok()) << n.error();
  ASSERT_EQ(*n, 19u);
  EXPECT_TRUE(FloatDecodeMatches(f, spec.format, 17, 19, 2));

  // Reads past the tail clip to what exists.
  n = r->ReadPlanarFloat(40, 100, f);
  ASSERT_TRUE(n.ok());
  ASSERT_EQ(*n, 8u);
  EXPECT_TRUE(FloatDecodeMatches(f, spec.format, 40, 8, 2));

  // Reads at or beyond the end return zero frames, channels intact.
  n = r->ReadPlanarFloat(48, 10, f);
  ASSERT_TRUE(n.ok());
  EXPECT_EQ(*n, 0u);
  EXPECT_EQ(f.size(), 2u);
  EXPECT_TRUE(f[0].empty());
  n = r->ReadPlanarFloat(1000, 5, f);
  ASSERT_TRUE(n.ok());
  EXPECT_EQ(*n, 0u);
}

TEST(ReaderMatrix, Ds64AnywhereBeforeDataIsAccepted) {
  wt::FixtureSpec spec;
  spec.container = Container::kRf64;
  spec.format = SampleFormat::kInt16;
  spec.channels = 2;
  spec.ds64 = wt::FixtureSpec::Ds64Mode::kLate;
  const std::string path = wt::WriteFixture("ds64_late", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().num_frames, 48u);
  std::vector<std::vector<float>> f;
  auto n = r->ReadPlanarFloat(0, 48, f);
  ASSERT_TRUE(n.ok());
  EXPECT_TRUE(FloatDecodeMatches(f, spec.format, 0, 48, 2));
}

TEST(ReaderMatrix, Bw64WithRealSizesAndNoDs64IsAccepted) {
  // BW64 files under 4 GiB may carry ordinary 32-bit sizes and no ds64.
  wt::FixtureSpec spec;
  spec.container = Container::kBw64;
  spec.format = SampleFormat::kFloat32;
  spec.channels = 1;
  spec.ds64 = wt::FixtureSpec::Ds64Mode::kNone;
  const std::string path = wt::WriteFixture("bw64_no_ds64", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().container, Container::kBw64);
  EXPECT_EQ(r->info().num_frames, 48u);
}

TEST(ReaderMatrix, MetadataChunksAreCapturedVerbatim) {
  wt::FixtureSpec spec;
  spec.container = Container::kBw64;
  spec.format = SampleFormat::kInt24;
  spec.channels = 4;
  spec.include_axml = true;
  spec.include_chna = true;
  spec.include_bext = true;
  const std::string path = wt::WriteFixture("metadata", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->axml(), wt::kFixtureAxml());
  EXPECT_EQ(r->chna(), wt::FixtureChna());
  EXPECT_EQ(r->bext(), wt::FixtureBext());
  const Metadata md = r->metadata();
  EXPECT_EQ(md.axml, wt::kFixtureAxml());
  EXPECT_FALSE(md.empty());
}

TEST(ReaderMatrix, ChunkInventoryListsEveryChunkInFileOrder) {
  wt::FixtureSpec spec;
  spec.container = Container::kBw64;
  spec.channels = 2;
  spec.include_extra_chunk = true;  // Odd-sized "dbmd" — exercises padding.
  spec.include_axml = true;
  const std::string path = wt::WriteFixture("inventory", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();

  ASSERT_EQ(r->chunks_seen(), 5u);
  ASSERT_EQ(r->chunks().size(), 5u);
  EXPECT_EQ(r->chunks()[0].id, "ds64");
  EXPECT_EQ(r->chunks()[1].id, "dbmd");
  EXPECT_EQ(r->chunks()[1].size, 7u);
  EXPECT_EQ(r->chunks()[2].id, "axml");
  EXPECT_EQ(r->chunks()[3].id, "fmt ");
  EXPECT_EQ(r->chunks()[4].id, "data");
  // The inventoried data size is the resolved (ds64) size, not 0xFFFFFFFF.
  EXPECT_EQ(r->chunks()[4].size, 48u * 2u * 2u);
}

TEST(ReaderMatrix, OddSizedDataChunkIsAccepted) {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kUint8;
  spec.channels = 1;
  spec.num_frames = 49;  // 49 bytes of data — odd, followed by a pad byte.
  const std::string path = wt::WriteFixture("odd_data", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  ASSERT_EQ(r->info().num_frames, 49u);
  std::vector<std::vector<float>> f;
  auto n = r->ReadPlanarFloat(0, 49, f);
  ASSERT_TRUE(n.ok());
  EXPECT_TRUE(FloatDecodeMatches(f, spec.format, 0, 49, 1));
}

// Overwrites the sample at (frame, ch=0) of a mono fixture's data payload.
template <typename T>
void PatchSample(wt::FixtureFile& f, uint64_t frame, T value) {
  uint8_t bytes[sizeof(T)];
  std::memcpy(bytes, &value, sizeof(T));  // Little-endian host assumed (CI).
  for (size_t i = 0; i < sizeof(T); ++i) {
    f.bytes[f.data_payload_offset + frame * sizeof(T) + i] = bytes[i];
  }
}

TEST(ReaderMatrix, ExtremeFloat32SamplesStayFiniteWithHeadroom) {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kFloat32;
  spec.channels = 1;
  spec.num_frames = 8;
  auto f = wt::BuildFixture(spec);
  const float kInf = std::numeric_limits<float>::infinity();
  const float values[8] = {std::numeric_limits<float>::quiet_NaN(),
                           kInf,
                           -kInf,
                           2.0f,
                           -2.0f,
                           1.0f,
                           -1.0f,
                           0.25f};
  for (uint64_t n = 0; n < 8; ++n) PatchSample(f, n, values[n]);
  const std::string path = wt::TempDir() + "/extreme_f32.wav";
  ASSERT_TRUE(wt::WriteBytes(path, f.bytes));

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(0, 8, out).ok());
  // Headroom passes through (2.0 stays 2.0); non-finite values are
  // sanitized: NaN → 0, ±inf → ±FLT_MAX.
  const float kFMax = std::numeric_limits<float>::max();
  const float want[8] = {0.0f, kFMax, -kFMax, 2.0f, -2.0f, 1.0f, -1.0f, 0.25f};
  for (int n = 0; n < 8; ++n) EXPECT_EQ(out[0][n], want[n]) << n;

  std::vector<std::vector<int32_t>> lj;
  ASSERT_TRUE(r->ReadPlanarInt32LeftJustified(0, 8, lj).ok());
  const int32_t kMin = std::numeric_limits<int32_t>::min();
  const int32_t kMax = std::numeric_limits<int32_t>::max();
  const int32_t want_lj[8] = {0, kMax, kMin, kMax, kMin, kMax, kMin, 1 << 29};
  for (int n = 0; n < 8; ++n) EXPECT_EQ(lj[0][n], want_lj[n]) << n;
}

TEST(ReaderMatrix, ExtremeFloat64SamplesSurviveNarrowing) {
  // 1e300 exceeds FLT_MAX: a bare double → float cast would be undefined
  // behavior; the sanitized delivery saturates to ±FLT_MAX instead.
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kFloat64;
  spec.channels = 1;
  spec.num_frames = 4;
  auto f = wt::BuildFixture(spec);
  const double values[4] = {1e300, -1e300,
                            std::numeric_limits<double>::quiet_NaN(), 0.5};
  for (uint64_t n = 0; n < 4; ++n) PatchSample(f, n, values[n]);
  const std::string path = wt::TempDir() + "/extreme_f64.wav";
  ASSERT_TRUE(wt::WriteBytes(path, f.bytes));

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(0, 4, out).ok());
  EXPECT_EQ(out[0][0], std::numeric_limits<float>::max());
  EXPECT_EQ(out[0][1], std::numeric_limits<float>::lowest());
  EXPECT_EQ(out[0][2], 0.0f);
  EXPECT_EQ(out[0][3], 0.5f);

  std::vector<std::vector<int32_t>> lj;
  ASSERT_TRUE(r->ReadPlanarInt32LeftJustified(0, 4, lj).ok());
  EXPECT_EQ(lj[0][0], std::numeric_limits<int32_t>::max());
  EXPECT_EQ(lj[0][1], std::numeric_limits<int32_t>::min());
  EXPECT_EQ(lj[0][2], 0);
  EXPECT_EQ(lj[0][3], 1 << 30);
}

TEST(ReaderMatrix, FullScaleIntegerCodesDecodeExactly) {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kInt16;
  spec.channels = 1;
  spec.num_frames = 4;
  auto f = wt::BuildFixture(spec);
  const int16_t codes[4] = {std::numeric_limits<int16_t>::min(),
                            std::numeric_limits<int16_t>::max(), -1, 0};
  for (uint64_t n = 0; n < 4; ++n) PatchSample(f, n, codes[n]);
  const std::string path = wt::TempDir() + "/fullscale_s16.wav";
  ASSERT_TRUE(wt::WriteBytes(path, f.bytes));

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(0, 4, out).ok());
  EXPECT_EQ(out[0][0], -1.0f);
  EXPECT_EQ(out[0][1], 32767.0f / 32768.0f);
  EXPECT_EQ(out[0][2], -1.0f / 32768.0f);
  EXPECT_EQ(out[0][3], 0.0f);

  std::vector<std::vector<int32_t>> lj;
  ASSERT_TRUE(r->ReadPlanarInt32LeftJustified(0, 4, lj).ok());
  EXPECT_EQ(lj[0][0], std::numeric_limits<int32_t>::min());
  EXPECT_EQ(lj[0][1], 32767 << 16);
  EXPECT_EQ(lj[0][2], -65536);
  EXPECT_EQ(lj[0][3], 0);
}

TEST(ReaderMatrix, NonAllocatingReadMatchesAllocatingRead) {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kInt24;
  spec.channels = 3;
  spec.num_frames = 48;
  const std::string path = wt::WriteFixture("into_read", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  r->ReserveReadScratch(16);

  float ch0[16], ch1[16], ch2[16];
  float* dsts[3] = {ch0, ch1, ch2};
  auto n = r->ReadPlanarFloatInto(10, 16, dsts);
  ASSERT_TRUE(n.ok()) << n.error();
  ASSERT_EQ(*n, 16u);
  for (uint16_t c = 0; c < 3; ++c) {
    for (uint32_t i = 0; i < 16; ++i) {
      EXPECT_EQ(dsts[c][i], wt::ExpectedFloat(spec.format, 10 + i, c))
          << "frame " << (10 + i) << " channel " << c;
    }
  }

  // Tail clipping matches the allocating API: 8 frames remain at 40.
  n = r->ReadPlanarFloatInto(40, 16, dsts);
  ASSERT_TRUE(n.ok());
  EXPECT_EQ(*n, 8u);
  n = r->ReadPlanarFloatInto(48, 16, dsts);
  ASSERT_TRUE(n.ok());
  EXPECT_EQ(*n, 0u);
}

TEST(ReaderMatrix, ZeroFrameDataChunkIsAccepted) {
  wt::FixtureSpec spec;
  spec.num_frames = 0;
  const std::string path = wt::WriteFixture("zero_frames", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().num_frames, 0u);
  std::vector<std::vector<float>> f;
  auto n = r->ReadPlanarFloat(0, 16, f);
  ASSERT_TRUE(n.ok());
  EXPECT_EQ(*n, 0u);
}

}  // namespace
}  // namespace wav
