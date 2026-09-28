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

#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "absl/status/statusor.h"
#include "adm_import/wav/bw64_reader.h"
#include "adm_import/wav/wav_writer.h"
#include "gtest/gtest.h"
#include "wav/types.h"

namespace adm2iamf {
namespace {

std::string TempPath(const char* name) {
  const char* dir = std::getenv("TEST_TMPDIR");
  return std::string(dir ? dir : "/tmp") + "/" + name;
}

// Build a few channels of distinct ramps so a channel swap would be caught.
std::vector<std::vector<float>> MakePlanar(int channels, int frames) {
  std::vector<std::vector<float>> planar(channels,
                                         std::vector<float>(frames, 0.0f));
  for (int c = 0; c < channels; ++c) {
    for (int n = 0; n < frames; ++n) {
      planar[c][n] = std::sin(0.01f * n + c) * (0.5f + 0.1f * c);
    }
  }
  return planar;
}

TEST(WavRoundTrip, Float32PreservesSamplesAndShape) {
  const int kChannels = 6, kFrames = 480;
  const auto planar = MakePlanar(kChannels, kFrames);
  const std::string path = TempPath("rt_f32.wav");
  ASSERT_TRUE(WriteWavPlanar(path, planar, 48000, WavEncoding::kFloat32).ok());

  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok()) << reader.status();
  EXPECT_EQ((*reader)->format().channels, kChannels);
  EXPECT_EQ((*reader)->format().sample_rate, 48000u);
  EXPECT_TRUE(wav::IsFloatFormat((*reader)->format().format));
  EXPECT_EQ((*reader)->num_frames(), static_cast<uint64_t>(kFrames));

  std::vector<std::vector<float>> got;
  auto n = (*reader)->ReadPlanarFloat(0, kFrames, got);
  ASSERT_TRUE(n.ok()) << n.status();
  EXPECT_EQ(*n, static_cast<uint64_t>(kFrames));
  for (int c = 0; c < kChannels; ++c) {
    for (int i = 0; i < kFrames; ++i) {
      EXPECT_NEAR(got[c][i], planar[c][i], 1e-6f) << "c=" << c << " i=" << i;
    }
  }
}

TEST(WavRoundTrip, Pcm24RoundTripsWithinQuantStep) {
  const int kChannels = 3, kFrames = 256;
  const auto planar = MakePlanar(kChannels, kFrames);
  const std::string path = TempPath("rt_p24.wav");
  ASSERT_TRUE(WriteWavPlanar(path, planar, 48000, WavEncoding::kPcm24).ok());

  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok()) << reader.status();
  EXPECT_EQ((*reader)->format().bits_per_sample(), 24);
  EXPECT_FALSE(wav::IsFloatFormat((*reader)->format().format));

  std::vector<std::vector<float>> got;
  ASSERT_TRUE((*reader)->ReadPlanarFloat(0, kFrames, got).ok());
  for (int c = 0; c < kChannels; ++c) {
    for (int i = 0; i < kFrames; ++i) {
      EXPECT_NEAR(got[c][i], planar[c][i], 1.0f / 8388608.0f * 2)
          << "c=" << c << " i=" << i;
    }
  }
}

TEST(WavReader, PartialReadAtTailClampsCount) {
  const auto planar = MakePlanar(2, 100);
  const std::string path = TempPath("rt_tail.wav");
  ASSERT_TRUE(WriteWavPlanar(path, planar, 48000).ok());
  auto reader = Bw64Reader::Open(path);
  ASSERT_TRUE(reader.ok());

  std::vector<std::vector<float>> got;
  auto n = (*reader)->ReadPlanarFloat(90, 50, got);  // only 10 remain
  ASSERT_TRUE(n.ok());
  EXPECT_EQ(*n, 10u);
  EXPECT_EQ(got[0].size(), 10u);
}

}  // namespace
}  // namespace adm2iamf
