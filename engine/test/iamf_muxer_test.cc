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

// Tests for IamfMuxer::ProbeVideo and for the mux against a container
// whose stts box ends with a zero-duration entry (ES-742). The fixture
// stts_zero_tail_h264.mp4 (engine/tools/generate_stts_fixture.py) has
// the sample table VLC 4.0 writes; GPAC at the pinned commit rejected it
// until engine/deps/gpac/patches/0001-*.patch, so a failure here means
// libgpac was built without the patch.

#include "iamf/iamf_muxer.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "iamf/gpac_system.h"

// gpac last: its headers poison strcpy/strcat with #error macros, which
// breaks any standard header included after them.
#include <gpac/isomedia.h>
#include <gpac/tools.h>

#include "gtest/gtest.h"

namespace {

std::string TempPath(const char* name) {
  const char* base = std::getenv("TEST_TMPDIR");
  std::string dir = base != nullptr ? base : ".";
  return dir + "/" + name;
}

// Same runfiles probe as iamf_playback_session_test.cc.
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
    if (FILE* f = std::fopen(c.c_str(), "rb")) {
      std::fclose(f);
      return c;
    }
  }
  return candidates[0];
}

constexpr const char* kSttsFixture = "stts_zero_tail_h264.mp4";
constexpr const char* kIamfFixture = "noise_3s_stereo_opus.iamf";
// FRAMES in engine/tools/generate_stts_fixture.py.
constexpr u32 kFixtureFrames = 12;

TEST(IamfMuxerProbe, AcceptsZeroDurationSttsTail) {
  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.ProbeVideo(FindFixture(kSttsFixture)), 0);
}

TEST(IamfMuxerProbe, RejectsMissingFile) {
  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.ProbeVideo(TempPath("does_not_exist.mp4")), -3);
}

TEST(IamfMuxerProbe, RejectsEmptyPath) {
  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.ProbeVideo(""), -1);
}

TEST(IamfMuxerProbe, RejectsNonIsobmffFile) {
  // A bare .iamf bitstream is not an ISO media file.
  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.ProbeVideo(FindFixture(kIamfFixture)), -12);
}

TEST(IamfMuxerProbe, RejectsContainerWithoutVideoTrack) {
  // An MP4 with one audio track and no video, written with GPAC's own
  // API (Mux() cannot leave one behind: it removes its output when the
  // video phase fails).
  const std::string path = TempPath("audio_only.mp4");
  {
    eclipsa_studio::GpacSystem gpac;
    ASSERT_TRUE(gpac.ok());
    GF_ISOFile* file = gf_isom_open(path.c_str(), GF_ISOM_OPEN_WRITE, nullptr);
    ASSERT_NE(file, nullptr);
    const u32 track = gf_isom_new_track(file, 0, GF_ISOM_MEDIA_AUDIO, 48000);
    const GF_Err closed = gf_isom_close(file);
    ASSERT_GT(track, 0u);
    ASSERT_EQ(closed, GF_OK);
  }

  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.ProbeVideo(path), -13);
}

TEST(IamfMuxerMux, MuxesZeroDurationSttsTail) {
  eclipsa_studio::IamfMuxer muxer;
  const std::string out = TempPath("stts_zero_tail_muxed.mp4");
  ASSERT_EQ(
      muxer.Mux(FindFixture(kIamfFixture), FindFixture(kSttsFixture), out), 0);

  eclipsa_studio::GpacSystem gpac;
  ASSERT_TRUE(gpac.ok());
  GF_ISOFile* file = gf_isom_open(out.c_str(), GF_ISOM_OPEN_READ, nullptr);
  ASSERT_NE(file, nullptr);
  const u32 track_count = gf_isom_get_track_count(file);
  u32 video = 0;
  for (u32 i = 1; i <= track_count; ++i) {
    if (gf_isom_get_media_type(file, i) == GF_ISOM_MEDIA_VISUAL) video = i;
  }
  const u32 video_samples =
      video == 0 ? 0 : gf_isom_get_sample_count(file, video);
  gf_isom_close(file);
  EXPECT_EQ(track_count, 2u);
  ASSERT_NE(video, 0u);
  EXPECT_EQ(video_samples, kFixtureFrames);
}

TEST(IamfMuxerMux, MuxesAudioOnly) {
  eclipsa_studio::IamfMuxer muxer;
  const std::string out = TempPath("audio_only_muxed.mp4");
  ASSERT_EQ(muxer.MuxAudioOnly(FindFixture(kIamfFixture), out), 0);

  eclipsa_studio::GpacSystem gpac;
  ASSERT_TRUE(gpac.ok());
  GF_ISOFile* file = gf_isom_open(out.c_str(), GF_ISOM_OPEN_READ, nullptr);
  ASSERT_NE(file, nullptr);
  const u32 track_count = gf_isom_get_track_count(file);
  const u32 media_type = track_count == 0 ? 0 : gf_isom_get_media_type(file, 1);
  const u32 samples = track_count == 0 ? 0 : gf_isom_get_sample_count(file, 1);
  gf_isom_close(file);
  EXPECT_EQ(track_count, 1u);
  EXPECT_EQ(media_type, static_cast<u32>(GF_ISOM_MEDIA_AUDIO));
  EXPECT_GT(samples, 0u);
}

TEST(IamfMuxerMux, AudioOnlyRejectsMissingInputAndLeavesNoFile) {
  eclipsa_studio::IamfMuxer muxer;
  const std::string out = TempPath("audio_only_missing.mp4");
  EXPECT_EQ(muxer.MuxAudioOnly(TempPath("does_not_exist.iamf"), out), -2);
  EXPECT_FALSE(std::filesystem::exists(out));
}

// GPAC's IAMF writer rejects a draft profile (iamf_gpac_limits_test pins
// the boundary), which makes the filter session fail: -11, and an earlier
// file at the output path is removed.
TEST(IamfMuxerMux, AudioOnlyMuxFailureRemovesOutput) {
  std::ifstream fixture(FindFixture(kIamfFixture), std::ios::binary);
  std::vector<char> bytes{std::istreambuf_iterator<char>(fixture),
                          std::istreambuf_iterator<char>()};
  // The IA Sequence Header OBU: header 0xF8, size 6, "iamf", then
  // primary_profile and additional_profile.
  ASSERT_GT(bytes.size(), 8u);
  ASSERT_EQ(static_cast<uint8_t>(bytes[0]), 0xF8);
  ASSERT_EQ(std::string(bytes.data() + 2, 4), "iamf");
  bytes[6] = 3;  // Base-Advanced, a v2.0.0 draft profile
  bytes[7] = 3;
  const std::string draft = TempPath("draft_profile.iamf");
  std::ofstream(draft, std::ios::binary)
      .write(bytes.data(), static_cast<std::streamsize>(bytes.size()));

  const std::string out = TempPath("draft_profile.mp4");
  std::ofstream(out) << "earlier file";
  ASSERT_TRUE(std::filesystem::exists(out));

  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.MuxAudioOnly(draft, out), -11);
  EXPECT_FALSE(std::filesystem::exists(out));
}

TEST(IamfMuxerMux, AudioOnlyRejectsEmptyArgument) {
  eclipsa_studio::IamfMuxer muxer;
  EXPECT_EQ(muxer.MuxAudioOnly("", TempPath("unused.mp4")), -1);
  EXPECT_EQ(muxer.MuxAudioOnly(FindFixture(kIamfFixture), ""), -1);
}

}  // namespace
