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

// Round-trip tests for IamfDemuxer.
//
// No IAMF-in-MP4 fixture is checked in, so each test builds one on the fly:
// a libgpac filter session muxes a bare `.iamf` fixture into an audio-only
// IAMF-in-ISOBMFF `.mp4` (the inverse of what IamfDemuxer does, and the
// same Phase-1 filter session IamfMuxer uses). The demuxer then extracts
// the `iamf` track back out, and we assert the reconstructed bitstream is
// semantically equivalent to the source — same sample rate, audio-element
// count/shape, and total frame count — which is the export -> QC
// round-trip guarantee ES-36 relies on. Video muxing is a separate, Dart-side
// concern, so these unit tests stay audio-only.

#include "iamf/iamf_demuxer.h"

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "iamf/iamf_demuxer.h"
#include "iamf/iamf_playback_session.h"
#include "iamf/include/iamf_tools/iamf_stream_factory.h"
#include "iamf/include/iamf_tools/iamf_stream_interface.h"
#include "iamf/include/iamf_tools/iamf_tools_api_types.h"
#include "test/iamf_test_mux.h"

namespace {

constexpr char kTwoAeFixture[] = "tones_100ms_3OA_stereo_opus.iamf";
constexpr char kStereoFixture[] = "noise_3s_stereo_opus.iamf";
constexpr char kVideoFixture[] = "stts_zero_tail_h264.mp4";

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

std::vector<uint8_t> LoadFile(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

using iamf_test_mux::MuxIamfToMp4;

std::string TempPath(const char* name) {
  const char* dir = std::getenv("TEST_TMPDIR");
  if (dir == nullptr) dir = "/tmp";
  return std::string(dir) + "/" + name;
}

// Mux `fixture` into a temp .mp4. Returns the .mp4 path, or "" on failure /
// missing fixture (caller skips with GTEST_SKIP).
std::string BuildMp4Fixture(const char* fixture, const char* out_name) {
  const std::string iamf = FindFixture(fixture);
  if (iamf.empty()) return {};
  const std::string mp4 = TempPath(out_name);
  if (!MuxIamfToMp4(iamf, mp4)) return {};
  return mp4;
}

}  // namespace

TEST(IamfDemuxerTest, IsIsoBmffDistinguishesContainers) {
  const std::string mp4 = BuildMp4Fixture(kStereoFixture, "demux_sniff.mp4");
  if (mp4.empty()) GTEST_SKIP() << "fixture missing or mux failed";

  const auto mp4_bytes = LoadFile(mp4);
  ASSERT_FALSE(mp4_bytes.empty());
  EXPECT_TRUE(eclipsa_studio::IamfDemuxer::IsIsoBmff(mp4_bytes.data(),
                                                     mp4_bytes.size()));

  const auto iamf_bytes = LoadFile(FindFixture(kStereoFixture));
  ASSERT_FALSE(iamf_bytes.empty());
  EXPECT_FALSE(eclipsa_studio::IamfDemuxer::IsIsoBmff(iamf_bytes.data(),
                                                      iamf_bytes.size()));

  // Too short to classify.
  const uint8_t tiny[] = {0x00, 0x01, 0x02};
  EXPECT_FALSE(eclipsa_studio::IamfDemuxer::IsIsoBmff(tiny, sizeof(tiny)));
  EXPECT_FALSE(eclipsa_studio::IamfDemuxer::IsIsoBmff(nullptr, 0));
}

TEST(IamfDemuxerTest, DemuxesIamfTrackToBytes) {
  const std::string mp4 = BuildMp4Fixture(kStereoFixture, "demux_bytes.mp4");
  if (mp4.empty()) GTEST_SKIP() << "fixture missing or mux failed";

  eclipsa_studio::IamfDemuxer demuxer;
  std::vector<uint8_t> bytes;
  ASSERT_TRUE(demuxer.DemuxToBytes(mp4, &bytes)) << demuxer.last_error();
  EXPECT_GT(bytes.size(), 0u);
  // The reconstructed bitstream is a bare IAMF stream, not an MP4.
  EXPECT_FALSE(
      eclipsa_studio::IamfDemuxer::IsIsoBmff(bytes.data(), bytes.size()));
}

TEST(IamfDemuxerTest, RejectsNonExistentFile) {
  eclipsa_studio::IamfDemuxer demuxer;
  std::vector<uint8_t> bytes;
  EXPECT_FALSE(demuxer.DemuxToBytes(TempPath("does_not_exist.mp4"), &bytes));
  EXPECT_NE(demuxer.last_error().find("io:"), std::string::npos);
}

TEST(IamfDemuxerTest, RejectsNullOutput) {
  eclipsa_studio::IamfDemuxer demuxer;
  EXPECT_FALSE(demuxer.DemuxToBytes("whatever.mp4", nullptr));
  EXPECT_NE(demuxer.last_error().find("invalid_argument:"), std::string::npos);
}

// The core guarantee: a session opened from the demuxed .mp4 exposes the
// same descriptors and duration as one opened from the source .iamf.
TEST(IamfDemuxerTest, RoundTripPreservesDescriptors) {
  const std::string mp4 = BuildMp4Fixture(kTwoAeFixture, "demux_roundtrip.mp4");
  if (mp4.empty()) GTEST_SKIP() << "fixture missing or mux failed";

  const auto iamf_bytes = LoadFile(FindFixture(kTwoAeFixture));
  ASSERT_FALSE(iamf_bytes.empty());

  // Source: opened directly from the bare .iamf bytes.
  IamfPlaybackSession original;
  ASSERT_TRUE(original.open_from_memory(iamf_bytes.data(), iamf_bytes.size()))
      << original.last_error();
  ASSERT_TRUE(original.wait_for_scan_complete()) << original.last_error();

  // Round-tripped: open() sniffs the .mp4 and demuxes it internally.
  IamfPlaybackSession roundtrip;
  ASSERT_TRUE(roundtrip.open(mp4.c_str())) << roundtrip.last_error();
  ASSERT_TRUE(roundtrip.wait_for_scan_complete()) << roundtrip.last_error();

  EXPECT_EQ(roundtrip.sample_rate(), original.sample_rate());
  ASSERT_EQ(roundtrip.num_audio_elements(), original.num_audio_elements());
  // Same OBUs in, same temporal units out — frame counts must match exactly.
  EXPECT_EQ(roundtrip.total_frames(), original.total_frames());

  // AE stream order is not guaranteed stable across the mux/demux round
  // trip, so match each source AE to the round-tripped one by its id rather
  // than by index.
  for (uint32_t i = 0; i < original.num_audio_elements(); ++i) {
    const auto a = original.ae_info(i);
    bool matched = false;
    for (uint32_t j = 0; j < roundtrip.num_audio_elements(); ++j) {
      const auto b = roundtrip.ae_info(j);
      if (b.audio_element_id != a.audio_element_id) continue;
      matched = true;
      EXPECT_EQ(b.kind, a.kind) << "AE id " << a.audio_element_id;
      EXPECT_EQ(b.num_channels, a.num_channels)
          << "AE id " << a.audio_element_id;
      EXPECT_EQ(b.supported, a.supported) << "AE id " << a.audio_element_id;
      break;
    }
    EXPECT_TRUE(matched) << "source AE id " << a.audio_element_id << " (kind "
                         << a.kind << ", " << a.num_channels
                         << "ch) missing after round trip";
  }
}

// Reading an IamfMp4Source's ranges in order must give exactly the bytes
// DemuxToBytes builds, without copying the samples out of the mapping.
TEST(IamfMp4SourceTest, RangesConcatenateToTheDemuxedBytes) {
  for (const char* fixture : {kStereoFixture, kTwoAeFixture}) {
    SCOPED_TRACE(fixture);
    const std::string mp4 = BuildMp4Fixture(fixture, "mp4_source.mp4");
    if (mp4.empty()) GTEST_SKIP() << "fixture missing or mux failed";

    eclipsa_studio::IamfDemuxer demuxer;
    std::vector<uint8_t> demuxed;
    ASSERT_TRUE(demuxer.DemuxToBytes(mp4, &demuxed)) << demuxer.last_error();

    eclipsa_studio::IamfMp4Source source;
    std::string err;
    ASSERT_TRUE(source.open(mp4, &err)) << err;
    // The descriptor OBUs plus at least one sample range.
    ASSERT_GE(source.segments().size(), 2u);
    std::vector<uint8_t> joined;
    for (const auto& segment : source.segments()) {
      joined.insert(joined.end(), segment.begin(), segment.end());
    }
    EXPECT_EQ(source.size_bytes(), joined.size());
    EXPECT_EQ(joined, demuxed);

    source.close();
    EXPECT_TRUE(source.segments().empty());
    EXPECT_EQ(source.size_bytes(), 0u);
  }
}

// An MP4 with a video track interleaves IAMF samples with video samples,
// so the track is several runs of samples with video bytes between them.
// Decoding the in-place ranges must match decoding the demuxed bytes
// exactly, including read windows that cross from one run to the next.
TEST(IamfMp4SourceTest, InterleavedTrackDecodesLikeDemuxedBytes) {
  const std::string iamf = FindFixture(kStereoFixture);
  const std::string video = FindFixture(kVideoFixture);
  // Both are declared as test data, so a missing one is a build error.
  ASSERT_FALSE(iamf.empty() || video.empty()) << "fixture missing";
  const std::string mp4 = TempPath("mp4_source_av.mp4");
  ASSERT_TRUE(MuxIamfToMp4(iamf, mp4, video));

  eclipsa_studio::IamfDemuxer demuxer;
  std::vector<uint8_t> demuxed;
  ASSERT_TRUE(demuxer.DemuxToBytes(mp4, &demuxed)) << demuxer.last_error();
  eclipsa_studio::IamfMp4Source source;
  std::string err;
  ASSERT_TRUE(source.open(mp4, &err)) << err;
  // Descriptor OBUs plus more than one run of samples.
  EXPECT_GT(source.segments().size(), 2u);
  std::vector<uint8_t> joined;
  for (const auto& segment : source.segments()) {
    joined.insert(joined.end(), segment.begin(), segment.end());
  }
  ASSERT_EQ(joined, demuxed);

  using iamf_tools::api::IamfByteRange;
  using iamf_tools::api::IamfStreamFactory;
  using iamf_tools::api::IamfStreamInterface;
  std::vector<IamfByteRange> ranges;
  for (const auto& segment : source.segments()) {
    ranges.push_back({segment.data(), segment.size()});
  }
  std::unique_ptr<IamfStreamInterface> in_place;
  std::unique_ptr<IamfStreamInterface> from_bytes;
  ASSERT_TRUE(IamfStreamFactory::OpenFromSegments(ranges.data(), ranges.size(),
                                                  {}, in_place)
                  .ok());
  ASSERT_TRUE(IamfStreamFactory::OpenFromBytes(demuxed.data(), demuxed.size(),
                                               {}, from_bytes)
                  .ok());
  int tus = 0;
  while (true) {
    iamf_tools::api::TemporalUnitOutput expected;
    iamf_tools::api::TemporalUnitOutput actual;
    ASSERT_TRUE(from_bytes->NextTemporalUnit(expected).ok());
    ASSERT_TRUE(in_place->NextTemporalUnit(actual).ok());
    ASSERT_EQ(actual.frames_produced, expected.frames_produced);
    if (expected.frames_produced == 0) break;
    ASSERT_EQ(actual.samples_per_ae, expected.samples_per_ae) << "TU " << tus;
    ++tus;
  }
  EXPECT_GT(tus, 0);
}

TEST(IamfMp4SourceTest, RejectsMissingFileAndNonMp4) {
  eclipsa_studio::IamfMp4Source source;
  std::string err;
  EXPECT_FALSE(source.open(TempPath("does_not_exist.mp4"), &err));
  EXPECT_NE(err.find("io:"), std::string::npos) << err;

  const std::string iamf = FindFixture(kStereoFixture);
  if (iamf.empty()) GTEST_SKIP() << "fixture missing";
  err.clear();
  EXPECT_FALSE(source.open(iamf, &err));
  EXPECT_FALSE(err.empty());
  EXPECT_TRUE(source.segments().empty());

  // An MP4 with no IAMF track fails without asking for the demux fallback,
  // which applies only when sample data is stored in another file.
  const std::string video = FindFixture(kVideoFixture);
  ASSERT_FALSE(video.empty()) << "fixture missing";
  bool sample_data_external = true;
  err.clear();
  EXPECT_FALSE(source.open(video, &err, &sample_data_external));
  EXPECT_NE(err.find("unsupported:"), std::string::npos) << err;
  EXPECT_FALSE(sample_data_external);
}

TEST(IamfDemuxerTest, IndexTrackRejectsNullOutput) {
  eclipsa_studio::IamfDemuxer demuxer;
  EXPECT_FALSE(demuxer.IndexTrack("whatever.mp4", nullptr));
  EXPECT_NE(demuxer.last_error().find("invalid_argument:"), std::string::npos);
}

// DemuxToBytes appends; a failed call leaves what was already there.
TEST(IamfDemuxerTest, FailedDemuxLeavesOutputUnchanged) {
  eclipsa_studio::IamfDemuxer demuxer;
  std::vector<uint8_t> bytes = {7, 7, 7};
  EXPECT_FALSE(demuxer.DemuxToBytes(TempPath("does_not_exist.mp4"), &bytes));
  EXPECT_EQ(bytes, (std::vector<uint8_t>{7, 7, 7}));
}
