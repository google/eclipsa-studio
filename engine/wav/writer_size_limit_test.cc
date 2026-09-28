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
// The RF64/BW64 auto-upgrade path, exercised in milliseconds by lowering
// the 32-bit size ceiling instead of writing > 4 GiB files. The upgraded
// output is a real, valid RF64/BW64 file that round-trips through Reader;
// the raw header bytes are asserted too.

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "wav/reader.h"
#include "wav/testing/fixture.h"
#include "wav/types.h"
#include "wav/writer.h"

namespace wav {
namespace {

namespace wt = wav::testing;

std::vector<uint8_t> ReadAllBytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
}

uint64_t GetU64(const std::vector<uint8_t>& v, size_t off) {
  uint64_t x = 0;
  for (int i = 7; i >= 0; --i) x = (x << 8) | v[off + i];
  return x;
}

uint32_t GetU32(const std::vector<uint8_t>& v, size_t off) {
  uint32_t x = 0;
  for (int i = 3; i >= 0; --i) x = (x << 8) | v[off + i];
  return x;
}

std::vector<std::vector<float>> Ramp(uint16_t channels, uint32_t frames) {
  std::vector<std::vector<float>> in(channels);
  for (uint16_t c = 0; c < channels; ++c) {
    in[c].resize(frames);
    for (uint32_t n = 0; n < frames; ++n) {
      in[c][n] = wt::ExpectedFloat(SampleFormat::kInt16, n, c);
    }
  }
  return in;
}

TEST(WriterSizeLimit, AutoUpgradesToRf64PastTheCeiling) {
  const std::string path = wt::TempDir() + "/upgrade_rf64.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  w->set_size_limit_for_testing(50000);

  const uint32_t kFrames = 48000;  // 96000 data bytes > the test ceiling.
  ASSERT_TRUE(w->PushPlanarFloat(Ramp(1, kFrames)).ok());
  ASSERT_TRUE(w->Finalize().ok());
  EXPECT_EQ(w->container(), Container::kRf64);

  // Raw header: RF64 magic, size field -1, ds64 as the first chunk with
  // exact riff/data/sample counts.
  const auto bytes = ReadAllBytes(path);
  ASSERT_GE(bytes.size(), 48u);
  EXPECT_EQ(std::string(bytes.begin(), bytes.begin() + 4), "RF64");
  EXPECT_EQ(GetU32(bytes, 4), 0xFFFFFFFFu);
  EXPECT_EQ(std::string(bytes.begin() + 12, bytes.begin() + 16), "ds64");
  EXPECT_EQ(GetU32(bytes, 16), 28u);                    // ds64 size.
  EXPECT_EQ(GetU64(bytes, 20), bytes.size() - 8);       // riffSize.
  EXPECT_EQ(GetU64(bytes, 28), uint64_t{kFrames} * 2);  // dataSize.
  EXPECT_EQ(GetU64(bytes, 36), uint64_t{kFrames});      // sampleCount.

  // And it round-trips through the reader as a first-class RF64 file.
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().container, Container::kRf64);
  ASSERT_EQ(r->info().num_frames, uint64_t{kFrames});
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(kFrames - 3, 3, out).ok());
  EXPECT_EQ(out[0][2], wt::ExpectedFloat(SampleFormat::kInt16, kFrames - 1, 0));
}

TEST(WriterSizeLimit, UpgradesToBw64WhenAdmMetadataIsPresent) {
  const std::string path = wt::TempDir() + "/upgrade_bw64.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  opt.metadata.axml = wt::kFixtureAxml();
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  w->set_size_limit_for_testing(50000);

  ASSERT_TRUE(w->PushPlanarFloat(Ramp(1, 48000)).ok());
  ASSERT_TRUE(w->Finalize().ok());
  EXPECT_EQ(w->container(), Container::kBw64);

  const auto bytes = ReadAllBytes(path);
  EXPECT_EQ(std::string(bytes.begin(), bytes.begin() + 4), "BW64");

  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().container, Container::kBw64);
  EXPECT_EQ(r->axml(), wt::kFixtureAxml());
  EXPECT_EQ(r->info().num_frames, 48000u);
}

TEST(WriterSizeLimit, UpgradeAfterAnEarlierRiffFlushRewritesTheHeader) {
  const std::string path = wt::TempDir() + "/upgrade_after_flush.wav";
  WriterOptions opt;
  opt.channels = 1;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  w->set_size_limit_for_testing(50000);

  // First flush lands under the ceiling: still plain RIFF on disk.
  ASSERT_TRUE(w->PushPlanarFloat(Ramp(1, 100)).ok());
  ASSERT_TRUE(w->Flush().ok());
  {
    auto r = Reader::Open(path);
    ASSERT_TRUE(r.ok()) << r.error();
    EXPECT_EQ(r->info().container, Container::kRiff);
    EXPECT_EQ(r->info().num_frames, 100u);
  }

  // Push past the ceiling: JUNK becomes ds64, RIFF becomes RF64.
  ASSERT_TRUE(w->PushPlanarFloat(Ramp(1, 48000)).ok());
  ASSERT_TRUE(w->Finalize().ok());
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();
  EXPECT_EQ(r->info().container, Container::kRf64);
  EXPECT_EQ(r->info().num_frames, 48100u);
  ASSERT_FALSE(r->chunks().empty());
  EXPECT_EQ(r->chunks()[0].id, "ds64");
  // Data across the upgrade boundary is intact.
  std::vector<std::vector<float>> out;
  ASSERT_TRUE(r->ReadPlanarFloat(98, 4, out).ok());
  EXPECT_EQ(out[0][0], wt::ExpectedFloat(SampleFormat::kInt16, 98, 0));
  EXPECT_EQ(out[0][2], wt::ExpectedFloat(SampleFormat::kInt16, 0, 0));
}

TEST(WriterSizeLimit, StaysRiffUnderTheDefaultCeiling) {
  const std::string path = wt::TempDir() + "/stays_riff.wav";
  WriterOptions opt;
  opt.channels = 2;
  opt.sample_rate = 48000;
  opt.format = WriteFormat::kPcm16;
  auto w = Writer::Create(path, opt);
  ASSERT_TRUE(w.ok()) << w.error();
  ASSERT_TRUE(w->PushPlanarFloat(Ramp(2, 1000)).ok());
  ASSERT_TRUE(w->Finalize().ok());
  EXPECT_EQ(w->container(), Container::kRiff);

  const auto bytes = ReadAllBytes(path);
  EXPECT_EQ(std::string(bytes.begin(), bytes.begin() + 4), "RIFF");
  // The 32-bit riff size is real (file size minus the 8-byte prelude), and
  // the placeholder chunk is still JUNK.
  EXPECT_EQ(GetU32(bytes, 4), bytes.size() - 8);
  EXPECT_EQ(std::string(bytes.begin() + 12, bytes.begin() + 16), "JUNK");
}

}  // namespace
}  // namespace wav
