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

// Unit tests for the display-matrix helpers (ES-796): QuarterTurnsClockwise,
// the conversion from av_display_rotation_get() degrees to clockwise
// quarter turns, and IsMirrored.

#include <cmath>
#include <cstdint>
#include <limits>

#include "gtest/gtest.h"
#include "video/rotation.h"

namespace eclipsa_studio::video {
namespace {

TEST(QuarterTurnsClockwiseTest, NoRotation) {
  EXPECT_EQ(QuarterTurnsClockwise(0.0), 0);
  EXPECT_EQ(QuarterTurnsClockwise(-0.0), 0);
}

TEST(QuarterTurnsClockwiseTest, PortraitPhoneRecording) {
  // ffprobe prints "rotation of -90.00 degrees" for a portrait phone clip.
  EXPECT_EQ(QuarterTurnsClockwise(-90.0), 1);
}

TEST(QuarterTurnsClockwiseTest, CounterclockwiseQuarterTurn) {
  EXPECT_EQ(QuarterTurnsClockwise(90.0), 3);
}

TEST(QuarterTurnsClockwiseTest, UpsideDown) {
  EXPECT_EQ(QuarterTurnsClockwise(180.0), 2);
  EXPECT_EQ(QuarterTurnsClockwise(-180.0), 2);
}

TEST(QuarterTurnsClockwiseTest, RoundsToNearestQuarterTurn) {
  // The 16.16 fixed-point matrix gives angles a hair off a multiple of 90.
  EXPECT_EQ(QuarterTurnsClockwise(-89.9999), 1);
  EXPECT_EQ(QuarterTurnsClockwise(-90.0001), 1);
  EXPECT_EQ(QuarterTurnsClockwise(30.0), 0);
  EXPECT_EQ(QuarterTurnsClockwise(-60.0), 1);
  // Halves round away from zero.
  EXPECT_EQ(QuarterTurnsClockwise(45.0), 3);
  EXPECT_EQ(QuarterTurnsClockwise(-45.0), 1);
  EXPECT_EQ(QuarterTurnsClockwise(135.0), 2);
  EXPECT_EQ(QuarterTurnsClockwise(-135.0), 2);
}

TEST(QuarterTurnsClockwiseTest, NonFiniteIsNoRotation) {
  EXPECT_EQ(QuarterTurnsClockwise(std::nan("")), 0);
  EXPECT_EQ(QuarterTurnsClockwise(std::numeric_limits<double>::infinity()), 0);
}

// 16.16 fixed point, as in AV_PKT_DATA_DISPLAYMATRIX.
constexpr int32_t kOne = 1 << 16;
constexpr int32_t kW = 1 << 30;

TEST(IsMirroredTest, RotationsAreNotMirrored) {
  const int32_t identity[9] = {kOne, 0, 0, 0, kOne, 0, 0, 0, kW};
  // The matrix ffprobe reports as "rotation of -90.00 degrees".
  const int32_t portrait[9] = {0, kOne, 0, -kOne, 0, 0, 0, 0, kW};
  const int32_t upside_down[9] = {-kOne, 0, 0, 0, -kOne, 0, 0, 0, kW};
  EXPECT_FALSE(IsMirrored(identity));
  EXPECT_FALSE(IsMirrored(portrait));
  EXPECT_FALSE(IsMirrored(upside_down));
}

TEST(IsMirroredTest, FlipsAreMirrored) {
  const int32_t hflip[9] = {-kOne, 0, 0, 0, kOne, 0, 0, 0, kW};
  const int32_t vflip[9] = {kOne, 0, 0, 0, -kOne, 0, 0, 0, kW};
  const int32_t turn_and_flip[9] = {0, kOne, 0, kOne, 0, 0, 0, 0, kW};
  EXPECT_TRUE(IsMirrored(hflip));
  EXPECT_TRUE(IsMirrored(vflip));
  EXPECT_TRUE(IsMirrored(turn_and_flip));
}

}  // namespace
}  // namespace eclipsa_studio::video
