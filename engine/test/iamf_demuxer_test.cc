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

#include <gpac/filters.h>
#include <gpac/tools.h>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "iamf/iamf_playback_session.h"

namespace {

constexpr char kTwoAeFixture[] = "tones_100ms_3OA_stereo_opus.iamf";
constexpr char kStereoFixture[] = "noise_3s_stereo_opus.iamf";

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

// Mux a bare `.iamf` into an audio-only IAMF-in-ISOBMFF `.mp4` via a libgpac
// filter session — the same Phase-1 path IamfMuxer uses, minus the video
// track. Returns true on success.
bool MuxIamfToMp4(const std::string& input_iamf,
                  const std::string& output_mp4) {
  // Bracket gpac use with gf_sys_init / gf_sys_close, the same as IamfMuxer
  // and IamfDemuxer do. The demuxer's gf_sys_close would otherwise tear the
  // filter registry out from under a later test's mux that had relied on
  // gpac being implicitly initialised.
  if (gf_sys_init(GF_MemTrackerNone, nullptr) != GF_OK) return false;
  GF_Err err = GF_OK;
  bool ok = false;
  GF_FilterSession* session = gf_fs_new_defaults(GF_FilterSessionFlags(0));
  if (session != nullptr) {
    GF_Filter* src =
        gf_fs_load_source(session, input_iamf.c_str(), nullptr, nullptr, &err);
    GF_Filter* dst = nullptr;
    if (err == GF_OK && src != nullptr) {
      dst = gf_fs_load_destination(session, output_mp4.c_str(), nullptr,
                                   nullptr, &err);
    }
    if (err == GF_OK && dst != nullptr) {
      err = gf_fs_run(session);
      if (err >= GF_OK) err = gf_fs_get_last_connect_error(session);
      if (err >= GF_OK) err = gf_fs_get_last_process_error(session);
      ok = err >= GF_OK;
    }
    gf_fs_del(session);
  }
  gf_sys_close();
  return ok;
}

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

// The probe -> session demux handoff that lets QC open parse an
// IAMF-in-MP4 once instead of twice (ES-215).
TEST(IamfDemuxHandoffTest, TakeReturnsStashedBytesOnceForMatchingPath) {
  const std::vector<uint8_t> bytes = {1, 2, 3, 4, 5};
  eclipsa_studio::StashIamfDemux("/tmp/clip.mp4", bytes);

  std::vector<uint8_t> out;
  ASSERT_TRUE(eclipsa_studio::TakeIamfDemux("/tmp/clip.mp4", &out));
  EXPECT_EQ(out, bytes);

  // Single use: the slot is cleared once taken, so the engine session never
  // races a second consumer onto the same stash.
  std::vector<uint8_t> again;
  EXPECT_FALSE(eclipsa_studio::TakeIamfDemux("/tmp/clip.mp4", &again));
  EXPECT_TRUE(again.empty());
}

TEST(IamfDemuxHandoffTest, TakeMissesOnPathMismatchAndLeavesStashIntact) {
  const std::vector<uint8_t> bytes = {9, 8, 7};
  eclipsa_studio::StashIamfDemux("/tmp/a.mp4", bytes);

  std::vector<uint8_t> out;
  EXPECT_FALSE(eclipsa_studio::TakeIamfDemux("/tmp/b.mp4", &out));
  // A non-matching take must not consume the stash — the real consumer can
  // still claim it.
  ASSERT_TRUE(eclipsa_studio::TakeIamfDemux("/tmp/a.mp4", &out));
  EXPECT_EQ(out, bytes);
}

TEST(IamfDemuxHandoffTest, StashOverwritesAndTakeRejectsNullOut) {
  EXPECT_FALSE(eclipsa_studio::TakeIamfDemux("/tmp/x.mp4", nullptr));

  // A fresh stash for the same path replaces the previous bytes (the producer
  // re-parses on every probe, so the latest content always wins).
  eclipsa_studio::StashIamfDemux("/tmp/x.mp4", {1, 1});
  eclipsa_studio::StashIamfDemux("/tmp/x.mp4", {2, 2, 2});
  std::vector<uint8_t> out;
  ASSERT_TRUE(eclipsa_studio::TakeIamfDemux("/tmp/x.mp4", &out));
  EXPECT_EQ(out, (std::vector<uint8_t>{2, 2, 2}));
}
