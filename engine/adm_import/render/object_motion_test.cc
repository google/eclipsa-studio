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

#include "adm_import/render/object_motion.h"

#include <cstddef>
#include <cstdint>
#include <vector>

#include "adm_import/scene/scene.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

ObjectKeyframe Kf(double start_s, float az, float gain) {
  ObjectKeyframe k;
  k.start_s = start_s;
  k.position.polar.azimuth = az;
  k.position.polar.elevation = 0.0f;
  k.position.polar.distance = 1.0f;
  k.gain = gain;
  return k;
}

TEST(ActiveKeyframe, PicksLastStartedKeyframe) {
  const std::vector<uint64_t> sf = {0, 100, 200};
  EXPECT_EQ(ActiveKeyframe(sf, 0), size_t{0});
  EXPECT_EQ(ActiveKeyframe(sf, 50), size_t{0});
  EXPECT_EQ(ActiveKeyframe(sf, 100), size_t{1});  // boundary is inclusive
  EXPECT_EQ(ActiveKeyframe(sf, 150), size_t{1});
  EXPECT_EQ(ActiveKeyframe(sf, 200), size_t{2});
  EXPECT_EQ(ActiveKeyframe(sf, 999), size_t{2});
}

TEST(ActiveKeyframe, ClampsToZeroBeforeFirstStart) {
  const std::vector<uint64_t> sf = {50, 100};
  EXPECT_EQ(ActiveKeyframe(sf, 10), size_t{0});
}

TEST(ActiveKeyframe, DuplicateStartsPickLastDuplicate) {
  const std::vector<uint64_t> sf = {0, 100, 100, 200};
  EXPECT_EQ(ActiveKeyframe(sf, 100), size_t{2});
  EXPECT_EQ(ActiveKeyframe(sf, 150), size_t{2});
}

// EvalObjectTimeline exercises the (file-local) shortest-arc LerpAngle.

TEST(EvalObjectTimeline, SnapsOnFirstKeyframe) {
  const std::vector<ObjectKeyframe> tl = {Kf(0.0, 30.0f, 0.8f)};
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 0, 0, 48000);
  EXPECT_FLOAT_EQ(pg.position.polar.azimuth, 30.0f);
  EXPECT_FLOAT_EQ(pg.gain, 0.8f);
}

TEST(EvalObjectTimeline, JumpSnapsWithoutInterpolating) {
  std::vector<ObjectKeyframe> tl = {Kf(0.0, 0.0f, 1.0f), Kf(1.0, 90.0f, 1.0f)};
  tl[1].jump = true;
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 48000, 48000);
  EXPECT_FLOAT_EQ(pg.position.polar.azimuth, 90.0f);
}

TEST(EvalObjectTimeline, InterpolatesAzimuthAndGain) {
  std::vector<ObjectKeyframe> tl = {Kf(0.0, 0.0f, 1.0f), Kf(1.0, 90.0f, 0.0f)};
  tl[1].interp_length_s = 1.0;  // ramp over 1 s
  const auto sf = KeyframeStartFrames(tl, 48000);
  // Half-way through the ramp (start 48000 + 24000 frames).
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 72000, 48000);
  EXPECT_NEAR(pg.position.polar.azimuth, 45.0f, 1e-3);
  EXPECT_NEAR(pg.gain, 0.5f, 1e-4);
}

TEST(EvalObjectTimeline, AntipodalSweepIsDeterministicallyPositive) {
  // 0 -> 180 is the exact tie. The fix pins it to the increasing-azimuth
  // direction, so half-way is +90 (never -90), the same on every run.
  std::vector<ObjectKeyframe> tl = {Kf(0.0, 0.0f, 1.0f), Kf(1.0, 180.0f, 1.0f)};
  tl[1].interp_length_s = 1.0;
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 72000, 48000);
  EXPECT_NEAR(pg.position.polar.azimuth, 90.0f, 1e-3);
}

TEST(EvalObjectTimeline, TakesShortestArcAcrossTheWrap) {
  // -170 -> 170 is a 20-degree arc through +/-180, not 340 the other way.
  std::vector<ObjectKeyframe> tl = {Kf(0.0, -170.0f, 1.0f),
                                    Kf(1.0, 170.0f, 1.0f)};
  tl[1].interp_length_s = 1.0;
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 72000, 48000);
  EXPECT_NEAR(pg.position.polar.azimuth, -180.0f, 1e-3);  // -170 + (-20) * 0.5
}

// Cartesian keyframe helper: a cube-authored block at (x, y, z).
ObjectKeyframe Kc(double start_s, float x, float y, float z, float gain) {
  ObjectKeyframe k;
  k.start_s = start_s;
  k.position.cartesian = true;
  k.position.cube = {x, y, z};
  k.gain = gain;
  return k;
}

TEST(EvalObjectTimeline, CartesianPairsInterpolateLinearlyInCubeSpace) {
  // Left wall -> right wall along the front: the midpoint is the front-centre
  // wall point (0, 1, 0), a straight line in the room. Polar shortest-arc
  // would instead swing the midpoint through the front at full distance.
  std::vector<ObjectKeyframe> tl = {Kc(0.0, -1.0f, 1.0f, 0.0f, 1.0f),
                                    Kc(1.0, 1.0f, 1.0f, 0.0f, 1.0f)};
  tl[1].interp_length_s = 1.0;
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 72000, 48000);
  ASSERT_TRUE(pg.position.cartesian);
  EXPECT_NEAR(pg.position.cube.x, 0.0f, 1e-4);
  EXPECT_NEAR(pg.position.cube.y, 1.0f, 1e-4);
  EXPECT_NEAR(pg.position.cube.z, 0.0f, 1e-4);
}

TEST(EvalObjectTimeline, CartesianJumpSnapsWithoutInterpolating) {
  std::vector<ObjectKeyframe> tl = {Kc(0.0, -1.0f, 1.0f, 0.0f, 1.0f),
                                    Kc(1.0, 1.0f, 1.0f, 0.0f, 1.0f)};
  tl[1].jump = true;
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 48000, 48000);
  ASSERT_TRUE(pg.position.cartesian);
  EXPECT_FLOAT_EQ(pg.position.cube.x, 1.0f);
}

TEST(EvalObjectTimeline, MixedBoundaryInterpolatesInCurrentSystem) {
  // Polar front-centre -> cartesian front-centre wall point. The boundary
  // rule converts the previous polar position into cube space via the fixed
  // section 10 map (az 0, el 0, d 1 -> (0, 1, 0)), so this "motion" is a
  // hold at the front-centre wall point, expressed in cube coordinates.
  std::vector<ObjectKeyframe> tl = {Kf(0.0, 0.0f, 1.0f),
                                    Kc(1.0, 0.0f, 1.0f, 0.0f, 1.0f)};
  tl[1].interp_length_s = 1.0;
  const auto sf = KeyframeStartFrames(tl, 48000);
  const PosGain pg = EvalObjectTimeline(tl, sf, 1, 72000, 48000);
  ASSERT_TRUE(pg.position.cartesian);
  EXPECT_NEAR(pg.position.cube.x, 0.0f, 1e-4);
  EXPECT_NEAR(pg.position.cube.y, 1.0f, 1e-4);
  EXPECT_NEAR(pg.position.cube.z, 0.0f, 1e-4);
}

}  // namespace
}  // namespace adm2iamf
