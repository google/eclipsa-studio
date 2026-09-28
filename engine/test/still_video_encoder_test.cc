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

// Unit tests for the still→video encoder (ES-192). Feed a synthetic RGBA
// frame through eclipsa_studio::StillVideoEncode and verify the resulting MP4
// with gpac's read API: one visual track, expected dimensions, expected
// frame count/duration, decodable avcC, and survival of the
// eclipsa_studio_iamf_mux stream-copy (the encoder's whole purpose). Runs the
// real OS encoder (VideoToolbox on macOS); on platforms where the stub
// is built, the encode reports unsupported and the container checks are
// skipped.

#include "video/still_video_encoder.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

#include "iamf/iamf_muxer.h"

// gpac last: its headers poison strcpy/strcat with #error macros, which
// breaks any standard header included after them.
#include <gpac/isomedia.h>
#include <gpac/mpeg4_odf.h>
#include <gpac/tools.h>

#include "gtest/gtest.h"

namespace {

// gpac global init/teardown for the read-back checks — same bracket as
// iamf_demuxer_test.cc (an unbracketed user can have the registry torn
// out from under it by a sibling's gf_sys_close).
class StillVideoEncoderTest : public ::testing::Test {
 protected:
  void SetUp() override { gf_sys_init(GF_MemTrackerNone, nullptr); }
  void TearDown() override { gf_sys_close(); }
};

// Closes the GF_ISOFile on scope exit so ASSERT failures don't leak it.
struct IsoCloser {
  GF_ISOFile* file;
  ~IsoCloser() {
    if (file != nullptr) gf_isom_close(file);
  }
};

std::string TempPath(const char* name) {
  const char* base = getenv("TEST_TMPDIR");
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
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

// A w×h gradient so the encoder has real content to compress.
std::vector<uint8_t> MakeFrame(uint32_t w, uint32_t h) {
  std::vector<uint8_t> rgba(static_cast<size_t>(w) * h * 4);
  for (uint32_t y = 0; y < h; ++y) {
    for (uint32_t x = 0; x < w; ++x) {
      uint8_t* px = rgba.data() + (static_cast<size_t>(y) * w + x) * 4;
      px[0] = static_cast<uint8_t>(x * 255 / w);
      px[1] = static_cast<uint8_t>(y * 255 / h);
      px[2] = 128;
      px[3] = 255;
    }
  }
  return rgba;
}

int32_t Encode(const std::vector<uint8_t>& rgba, uint32_t w, uint32_t h,
               uint32_t fps, double seconds, const std::string& out) {
  return eclipsa_studio::StillVideoEncode(rgba.data(), rgba.size(), w, h, fps,
                                          seconds, out.c_str());
}

TEST_F(StillVideoEncoderTest, RejectsBadArguments) {
  const auto rgba = MakeFrame(64, 64);
  const std::string out = TempPath("bad_args.mp4");
  // Runs on every platform: the stub validates before reporting -100.
  EXPECT_EQ(eclipsa_studio::StillVideoEncode(nullptr, rgba.size(), 64, 64, 5,
                                             1.0, out.c_str()),
            -1);
  EXPECT_EQ(Encode(rgba, 0, 64, 5, 1.0, out), -1);
  EXPECT_EQ(Encode(rgba, 63, 64, 5, 1.0, out), -1)
      << "odd width must be rejected (H.264 4:2:0)";
  EXPECT_EQ(Encode(rgba, 64, 63, 5, 1.0, out), -1)
      << "odd height must be rejected (H.264 4:2:0)";
  EXPECT_EQ(Encode(rgba, 64, 64, 0, 1.0, out), -1);
  EXPECT_EQ(Encode(rgba, 64, 64, 5, 0.0, out), -1);
  EXPECT_EQ(Encode(rgba, 64, 64, 5, std::nan(""), out), -1);
  EXPECT_EQ(
      Encode(rgba, 64, 64, 5, std::numeric_limits<double>::infinity(), out),
      -1);
  EXPECT_EQ(Encode(rgba, 64, 64, 5,
                   eclipsa_studio::kStillVideoMaxDurationSeconds * 2, out),
            -1);
  EXPECT_EQ(eclipsa_studio::StillVideoEncode(rgba.data(), rgba.size(), 64, 64,
                                             5, 1.0, nullptr),
            -1);
  // Undersized pixel buffer and oversized dimensions.
  EXPECT_EQ(eclipsa_studio::StillVideoEncode(rgba.data(), 16, 64, 64, 5, 1.0,
                                             out.c_str()),
            -1);
  const uint32_t too_big = eclipsa_studio::kStillVideoMaxDimension + 2;
  EXPECT_EQ(eclipsa_studio::StillVideoEncode(
                rgba.data(), static_cast<uint64_t>(too_big) * too_big * 4,
                too_big, too_big, 5, 1.0, out.c_str()),
            -1);
}

TEST_F(StillVideoEncoderTest, EncodesValidMp4WithExpectedTiming) {
  constexpr uint32_t kW = 128, kH = 72, kFps = 5;
  constexpr double kSeconds = 3.0;
  const auto rgba = MakeFrame(kW, kH);
  const std::string out = TempPath("still.mp4");

  const int32_t rc = Encode(rgba, kW, kH, kFps, kSeconds, out);
  if (rc == -100) {
    GTEST_SKIP() << "no OS encoder on this platform (stub build)";
  }
  ASSERT_EQ(rc, 0);

  IsoCloser iso{gf_isom_open(out.c_str(), GF_ISOM_OPEN_READ, nullptr)};
  ASSERT_NE(iso.file, nullptr) << "output is not a readable ISOBMFF file";
  ASSERT_EQ(gf_isom_get_track_count(iso.file), 1u);
  EXPECT_EQ(gf_isom_get_media_type(iso.file, 1),
            static_cast<u32>(GF_ISOM_MEDIA_VISUAL));

  u32 w = 0, h = 0;
  ASSERT_EQ(gf_isom_get_visual_info(iso.file, 1, 1, &w, &h), GF_OK);
  EXPECT_EQ(w, kW);
  EXPECT_EQ(h, kH);

  const u32 samples = gf_isom_get_sample_count(iso.file, 1);
  EXPECT_EQ(samples, static_cast<u32>(kFps * kSeconds));
  // The media timescale is the encoder's choice (VideoToolbox writes
  // fps, Media Foundation fps*1000) — only the resulting duration in
  // seconds is contractual.
  const u32 timescale = gf_isom_get_media_timescale(iso.file, 1);
  ASSERT_GT(timescale, 0u);
  EXPECT_EQ(gf_isom_get_media_duration(iso.file, 1),
            static_cast<u64>(kSeconds * timescale));

  // The avcC must decode and carry non-empty SPS/PPS — a garbled config
  // still reads as a visual track without this check.
  GF_AVCConfig* avcc = gf_isom_avc_config_get(iso.file, 1, 1);
  ASSERT_NE(avcc, nullptr);
  EXPECT_GE(gf_list_count(avcc->sequenceParameterSets), 1u);
  EXPECT_GE(gf_list_count(avcc->pictureParameterSets), 1u);
  gf_odf_avc_cfg_del(avcc);

  // First sample must be a sync sample (the mux stream-copy and any
  // player seek depend on a leading keyframe).
  GF_ISOSample* first =
      gf_isom_get_sample_info(iso.file, 1, 1, nullptr, nullptr);
  ASSERT_NE(first, nullptr);
  EXPECT_EQ(first->IsRAP, RAP);
  gf_isom_sample_del(&first);
}

TEST_F(StillVideoEncoderTest, SubSecondDurationYieldsAtLeastOneFrame) {
  constexpr uint32_t kW = 64, kH = 64;
  const auto rgba = MakeFrame(kW, kH);
  const std::string out = TempPath("one_frame.mp4");
  const int32_t rc = Encode(rgba, kW, kH, 5, 0.01, out);
  if (rc == -100) {
    GTEST_SKIP() << "no OS encoder on this platform (stub build)";
  }
  ASSERT_EQ(rc, 0);
  IsoCloser iso{gf_isom_open(out.c_str(), GF_ISOM_OPEN_READ, nullptr)};
  ASSERT_NE(iso.file, nullptr);
  EXPECT_GE(gf_isom_get_sample_count(iso.file, 1), 1u);
}

TEST_F(StillVideoEncoderTest, UnwritablePathFailsWithoutLeavingAFile) {
  constexpr uint32_t kW = 64, kH = 64;
  const auto rgba = MakeFrame(kW, kH);
  // A missing directory is not enough — gpac creates intermediate dirs.
  // A regular FILE in a directory position is unwritable everywhere.
  const std::string blocker = TempPath("blocker");
  {
    std::ofstream f(blocker, std::ios::binary);
    ASSERT_TRUE(f.good());
  }
  const std::string out = blocker + "/still.mp4";
  const int32_t rc = Encode(rgba, kW, kH, 5, 1.0, out);
  if (rc == -100) {
    GTEST_SKIP() << "no OS encoder on this platform (stub build)";
  }
  EXPECT_EQ(rc, -4);
  FILE* f = fopen(out.c_str(), "rb");
  EXPECT_EQ(f, nullptr) << "a failed encode must not leave a file behind";
  if (f != nullptr) fclose(f);
}

TEST_F(StillVideoEncoderTest, OutputSurvivesIamfMuxStreamCopy) {
  // The encoder exists to feed eclipsa_studio_iamf_mux's phase-2 stream-copy;
  // prove the full chain on a real (fixture) IAMF bitstream.
  constexpr uint32_t kW = 128, kH = 72;
  const auto rgba = MakeFrame(kW, kH);
  const std::string video = TempPath("mux_video.mp4");
  const std::string muxed = TempPath("muxed.mp4");
  const int32_t rc = Encode(rgba, kW, kH, 5, 2.0, video);
  if (rc == -100) {
    GTEST_SKIP() << "no OS encoder on this platform (stub build)";
  }
  ASSERT_EQ(rc, 0);

  const std::string fixture = FindFixture("sine_128samp_7_1_pcm.iamf");
  ASSERT_FALSE(fixture.empty()) << "IAMF fixture not found in runfiles";
  eclipsa_studio::IamfMuxer muxer;
  ASSERT_EQ(muxer.Mux(fixture, video, muxed), 0);

  IsoCloser iso{gf_isom_open(muxed.c_str(), GF_ISOM_OPEN_READ, nullptr)};
  ASSERT_NE(iso.file, nullptr);
  ASSERT_EQ(gf_isom_get_track_count(iso.file), 2u);
  // One audio (IAMF) track and one visual track, in mux order.
  EXPECT_EQ(gf_isom_get_media_type(iso.file, 1),
            static_cast<u32>(GF_ISOM_MEDIA_AUDIO));
  EXPECT_EQ(gf_isom_get_media_type(iso.file, 2),
            static_cast<u32>(GF_ISOM_MEDIA_VISUAL));
  EXPECT_EQ(gf_isom_get_sample_count(iso.file, 2), 10u);  // 2 s @ 5 fps
}

}  // namespace
