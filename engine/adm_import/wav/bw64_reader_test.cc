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

// Robustness tests for Bw64Reader::Open against malformed `fmt ` chunks. These
// hand-assemble RIFF/WAVE byte streams so a test can craft headers the writer
// never produces (a float `fmt ` claiming a non-32-bit depth, a truncated
// WAVE_FORMAT_EXTENSIBLE). The valid-file read path is covered by
// wav_roundtrip_test.cc; here we only check that bad headers are rejected and a
// couple of hand-built good ones still open (so a rejection can't be a false
// positive from a broken fixture).

#include "adm_import/wav/bw64_reader.h"

#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "absl/strings/match.h"
#include "gtest/gtest.h"
#include "wav/testing/fixture.h"
#include "wav/types.h"

namespace adm2iamf {
namespace {

namespace wt = wav::testing;
namespace wtf = wav::testing::fixture_internal;

std::string TempPath(const char* name) {
  const char* dir = std::getenv("TEST_TMPDIR");
  return std::string(dir ? dir : "/tmp") + "/" + name;
}

// An EXTENSIBLE tag with a cbSize but no extension payload — 18 bytes, < 40.
std::vector<uint8_t> FmtExtensibleTruncated(uint16_t channels, uint32_t rate,
                                            uint16_t bits) {
  std::vector<uint8_t> b = wt::FmtBodyExtensible(channels, rate, bits, 0);
  b.resize(18);  // cbSize claims an extension that isn't present
  return b;
}

bool WriteRiff(const std::string& path, const std::vector<uint8_t>& fmt_body,
               uint32_t data_bytes) {
  return wt::WriteBytes(path, wt::BuildRawFmtWav(fmt_body, data_bytes));
}

TEST(Bw64ReaderMalformed, RejectsFloatWithNon32BitDepth) {
  const std::string path = TempPath("mf_float16.wav");
  ASSERT_TRUE(WriteRiff(path, wt::FmtBody(3, 2, 48000, 16), 16));
  auto reader = Bw64Reader::Open(path);
  ASSERT_FALSE(reader.ok());
  EXPECT_TRUE(
      absl::StrContains(reader.status().message(), "IEEE-float bit depth"))
      << reader.status();
}

TEST(Bw64ReaderMalformed, RejectsTruncatedExtensibleFmt) {
  const std::string path = TempPath("mf_ext_trunc.wav");
  ASSERT_TRUE(WriteRiff(path, FmtExtensibleTruncated(2, 48000, 24), 12));
  auto reader = Bw64Reader::Open(path);
  ASSERT_FALSE(reader.ok());
  EXPECT_TRUE(
      absl::StrContains(reader.status().message(), "WAVE_FORMAT_EXTENSIBLE"))
      << reader.status();
}

TEST(Bw64ReaderMalformed, RejectsExtensibleFloatWithNon32BitDepth) {
  // EXTENSIBLE resolves to its float sub-format, which then hits the same
  // float-must-be-32-bit guard.
  const std::string path = TempPath("mf_ext_float16.wav");
  ASSERT_TRUE(WriteRiff(path, wt::FmtBodyExtensible(2, 48000, 16, 0x0003), 16));
  auto reader = Bw64Reader::Open(path);
  ASSERT_FALSE(reader.ok());
  EXPECT_TRUE(
      absl::StrContains(reader.status().message(), "IEEE-float bit depth"))
      << reader.status();
}

TEST(Bw64ReaderMalformed, AcceptsValidFloat32) {
  const std::string path = TempPath("mf_float32.wav");
  ASSERT_TRUE(WriteRiff(path, wt::FmtBody(3, 2, 48000, 32), 16));
  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok()) << reader.status();
  EXPECT_TRUE(wav::IsFloatFormat((*reader)->format().format));
  EXPECT_EQ((*reader)->format().bits_per_sample(), 32);
  EXPECT_EQ((*reader)->format().channels, 2);
  EXPECT_EQ((*reader)->num_frames(), 2u);  // 16 bytes / (2ch * 4B)
}

TEST(Bw64ReaderMalformed, AcceptsExtensiblePcm) {
  // A well-formed EXTENSIBLE PCM file resolves to integer PCM and opens.
  const std::string path = TempPath("mf_ext_pcm24.wav");
  ASSERT_TRUE(WriteRiff(path, wt::FmtBodyExtensible(2, 48000, 24, 0x0001), 12));
  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok()) << reader.status();
  EXPECT_FALSE(wav::IsFloatFormat((*reader)->format().format));
  EXPECT_EQ((*reader)->format().bits_per_sample(), 24);
  EXPECT_EQ((*reader)->num_frames(), 2u);  // 12 bytes / (2ch * 3B)
}

TEST(Bw64Reader, InventoriesExtraChunksSkippingJunk) {
  // A file with a vendor sidecar chunk and a JUNK pad: the sidecar is
  // inventoried by id/size (payload not retained), JUNK is ignored.
  const std::string path = TempPath("extra_chunks.wav");
  std::vector<uint8_t> out;
  auto tag = [&](const char* t) { out.insert(out.end(), t, t + 4); };
  tag("RIFF");
  wtf::AppendU32(out, 0);  // patched below
  tag("WAVE");
  const std::vector<uint8_t> fmt = wt::FmtBody(1, 2, 48000, 16);
  tag("fmt ");
  wtf::AppendU32(out, static_cast<uint32_t>(fmt.size()));
  out.insert(out.end(), fmt.begin(), fmt.end());
  tag("dbmd");
  wtf::AppendU32(out, 6);
  out.insert(out.end(), 6, 0xAB);
  tag("JUNK");
  wtf::AppendU32(out, 4);
  out.insert(out.end(), 4, 0);
  tag("data");
  wtf::AppendU32(out, 8);
  out.insert(out.end(), 8, 0);
  wtf::PutU32At(out, 4, static_cast<uint32_t>(out.size() - 8));
  ASSERT_TRUE(wt::WriteBytes(path, out));
  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok()) << reader.status();
  ASSERT_EQ((*reader)->extra_chunks().size(), 1u);
  EXPECT_EQ((*reader)->extra_chunks()[0].id, "dbmd");
  EXPECT_EQ((*reader)->extra_chunks()[0].bytes, 6u);
  EXPECT_EQ((*reader)->extra_chunks_seen(), 1u);
}

TEST(Bw64Reader, ExtraChunkInventoryIsCappedAndIdsSanitized) {
  // A zero-filled tail parses as one empty chunk per 8 bytes, and a chunk id
  // is four arbitrary bytes. The retained inventory must stay bounded, ids
  // must stay printable (they reach the probe's JSON), and the seen count
  // must stay exact.
  const std::string path = TempPath("extra_chunks_flood.wav");
  std::vector<uint8_t> out;
  auto tag = [&](const char* t) { out.insert(out.end(), t, t + 4); };
  tag("RIFF");
  wtf::AppendU32(out, 0);  // patched below
  tag("WAVE");
  const std::vector<uint8_t> fmt = wt::FmtBody(1, 2, 48000, 16);
  tag("fmt ");
  wtf::AppendU32(out, static_cast<uint32_t>(fmt.size()));
  out.insert(out.end(), fmt.begin(), fmt.end());
  tag("data");
  wtf::AppendU32(out, 8);
  out.insert(out.end(), 8, 0);
  // One chunk whose id carries non-printable and high bytes.
  const uint8_t kOddId[4] = {0x01, 'b', 0xFF, 'd'};
  out.insert(out.end(), kOddId, kOddId + 4);
  wtf::AppendU32(out, 0);
  // A zero-filled tail: 8 bytes per synthesized empty chunk.
  const size_t kTailChunks = Bw64Reader::kMaxExtraChunks * 3;
  out.insert(out.end(), kTailChunks * 8, 0);
  wtf::PutU32At(out, 4, static_cast<uint32_t>(out.size() - 8));
  ASSERT_TRUE(wt::WriteBytes(path, out));
  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok()) << reader.status();
  EXPECT_EQ((*reader)->extra_chunks().size(), Bw64Reader::kMaxExtraChunks);
  EXPECT_GT((*reader)->extra_chunks_seen(), Bw64Reader::kMaxExtraChunks);
  // High/control bytes are replaced, printable ones kept.
  EXPECT_EQ((*reader)->extra_chunks()[0].id, "?b?d");
  for (const auto& c : (*reader)->extra_chunks()) {
    for (const char ch : c.id) {
      EXPECT_GE(static_cast<unsigned char>(ch), 0x20u);
      EXPECT_LT(static_cast<unsigned char>(ch), 0x7Fu);
    }
  }
}

}  // namespace
}  // namespace adm2iamf
