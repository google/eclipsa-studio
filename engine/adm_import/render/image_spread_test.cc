/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "adm_import/render/image_spread.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>
#include <vector>

#include "adm_import/render/channel_renderer.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

constexpr double kPi = 3.14159265358979323846;

Polar At(float az, float el, float dist) {
  Polar p;
  p.azimuth = az;
  p.elevation = el;
  p.distance = dist;
  return p;
}

float Spread(ImageSpreadMeter& m, float az, float el, float dist) {
  return m.Measure(At(az, el, dist)).rms_deg;
}

// The halo's two half-widths as the preview draws them, in degrees: the
// measured width along the image's widest axis, and that narrowed by the
// measured ratio across it. Keeping the width on the major axis is what
// preserves the property the single number was chosen for -- the edge lands
// on the speakers carrying the image, at an even pair split and at the
// zenith alike.
std::pair<float, float> Axes(ImageSpreadMeter& m, float az, float el,
                             float dist) {
  const ImageSpread s = m.Measure(At(az, el, dist));
  return {s.rms_deg, s.rms_deg * s.ratio};
}

// The same figure computed from a full RenderChannelBed pass: one static
// object at (az, el, dist), steady per-channel gain taken as the mean over
// the last quarter of a 2048-frame render, then the energy-weighted rms
// angle about the energy-vector direction. This is the tie between the
// meter's 64-frame probe blocks and the render the preview describes -- the
// meter is only worth trusting if it reproduces this.
double SpreadFromFullRender(float az, float el, float dist) {
  constexpr int kFrames = 2048;
  ObjectKeyframe k;
  k.start_s = 0;
  k.position.polar = {az, el, dist};
  ObjectSource o;
  o.label = "obj";
  o.track_index = 1;
  o.importance = 10;
  o.timeline = {k};
  Scene scene;
  scene.objects = {o};
  std::vector<std::vector<float>> tracks = {std::vector<float>(kFrames, 1.0f)};

  const Layout& layout = ImportLayout();
  auto out = RenderChannelBed(scene, layout, tracks, 48000, 0, nullptr);
  EXPECT_TRUE(out.ok());
  if (!out.ok()) return 0;

  std::vector<double> g;
  for (const std::vector<float>& ch : *out) {
    double acc = 0;
    for (int n = kFrames - kFrames / 4; n < kFrames; ++n) acc += ch[n];
    g.push_back(acc / (kFrames / 4));
  }

  double energy = 0, ex = 0, ey = 0, ez = 0;
  std::vector<std::vector<double>> dirs;
  for (int ch = 0; ch < layout.num_channels(); ++ch) {
    const Speaker& s = layout.speakers[ch];
    if (s.is_lfe) {
      dirs.push_back({0, 0, 0});
      continue;
    }
    const double a = s.azimuth * kPi / 180.0, e = s.elevation * kPi / 180.0;
    dirs.push_back(
        {std::cos(e) * std::cos(a), std::cos(e) * std::sin(a), std::sin(e)});
    const double p = g[ch] * g[ch];
    energy += p;
    ex += p * dirs[ch][0];
    ey += p * dirs[ch][1];
    ez += p * dirs[ch][2];
  }
  if (energy <= 1e-12) return 0;
  ex /= energy;
  ey /= energy;
  ez /= energy;
  const double mag = std::sqrt(ex * ex + ey * ey + ez * ez);
  if (mag <= 1e-9) return 90.0;
  ex /= mag;
  ey /= mag;
  ez /= mag;
  double acc = 0;
  for (int ch = 0; ch < layout.num_channels(); ++ch) {
    if (layout.speakers[ch].is_lfe) continue;
    double dot = ex * dirs[ch][0] + ey * dirs[ch][1] + ez * dirs[ch][2];
    dot = std::max(-1.0, std::min(1.0, dot));
    const double theta = std::acos(dot) * 180.0 / kPi;
    acc += (g[ch] * g[ch] / energy) * theta * theta;
  }
  return std::sqrt(acc);
}

TEST(ImageSpread, ReproducesTheFullRendersGainVector) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  for (const float az : {0.0f, 22.0f, 60.0f, 135.0f, 180.0f, -75.0f}) {
    for (const float el : {0.0f, 20.0f, 45.0f, 90.0f, -40.0f}) {
      for (const float d : {1.0f, 0.8f, 0.5f, 0.2f, 0.0f}) {
        EXPECT_NEAR(Spread(*m, az, el, d), SpreadFromFullRender(az, el, d),
                    0.05)
            << "az=" << az << " el=" << el << " d=" << d;
      }
    }
  }
}

// A source at a speaker angle lands on that speaker alone, so the image has
// no width -- the same case the renderer passes through bit-exact for a bed
// channel. Every 7.1.4 speaker, mid ring and top.
TEST(ImageSpread, ASourceAtASpeakerAngleImagesAsAPoint) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  for (const Speaker& s : ImportLayout().speakers) {
    if (s.is_lfe) continue;
    EXPECT_NEAR(Spread(*m, s.azimuth, s.elevation, 1.0f), 0.0f, 0.05f)
        << s.name;
  }
}

// Halfway between two speakers the pan splits evenly, and the rms angle is
// then exactly the angle to each of them -- half the gap. This is what makes
// the figure readable as the image's angular radius: at an even pair split
// the halo's edge lands on the two speakers carrying it.
//
// The gaps are the mid ring's own: 30 degrees between M+000 and M+030, 60
// between M+030 and M+090, 45 between M+090 and M+135, and 90 across the
// back between M+135 and M-135.
TEST(ImageSpread, AnEvenPairSplitIsTheAngleToEachSpeaker) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  EXPECT_NEAR(Spread(*m, 15.0f, 0, 1.0f), 15.0f, 0.05f);
  EXPECT_NEAR(Spread(*m, 60.0f, 0, 1.0f), 30.0f, 0.05f);
  EXPECT_NEAR(Spread(*m, 112.5f, 0, 1.0f), 22.5f, 0.05f);
  EXPECT_NEAR(Spread(*m, 180.0f, 0, 1.0f), 45.0f, 0.05f);
  // So the layout's own resolution, not the source, sets the floor: a point
  // source panned to the back of a 7.1.4 room images 45 degrees wide however
  // it was authored.
  EXPECT_GT(Spread(*m, 180.0f, 0, 1.0f), Spread(*m, 15.0f, 0, 1.0f));
}

// Distance widens the image rather than moving it: the pan blends DBAP in as
// distance falls, spreading the source over more of its own ring. Measured
// at az 22.5, which sits between M+000 and M+030:
//
//   d     1.0   0.9   0.8   0.7   0.6   0.5   0.4   0.3   0.2   0.1   0.0
//   deg   9.2   9.7  16.0  25.2  38.1  53.8  63.4  71.8  78.6  84.0  88.2
//
// The last figure is the mid ring driven evenly from its centre: with seven
// speakers around the listener the rms angle is 88.2. No cap of that radius
// describes the footprint -- the render drives the whole ring, so the image
// is a band around it. The preview draws a cap anyway and understates it.
TEST(ImageSpread, DistanceWidensTheImageToTheWholeRing) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  EXPECT_NEAR(Spread(*m, 22.5f, 0, 1.0f), 9.2f, 0.1f);
  EXPECT_NEAR(Spread(*m, 22.5f, 0, 0.5f), 53.8f, 0.1f);
  EXPECT_NEAR(Spread(*m, 22.5f, 0, 0.0f), 88.2f, 0.1f);
  float prev = 0;
  for (const float d :
       {0.9f, 0.8f, 0.7f, 0.6f, 0.5f, 0.4f, 0.3f, 0.2f, 0.1f, 0.0f}) {
    const float deg = Spread(*m, 22.5f, 0, d);
    EXPECT_GT(deg, prev) << "d=" << d;
    prev = deg;
  }
}

// Elevation between the rings splits the source across both of them, and
// elevation above the top ring drives that ring alone ever more evenly. At
// the zenith all four top speakers carry it, each 60 degrees away, so that
// is where the figure ends up -- not the 88 of a full mid ring, because the
// top ring subtends less of the sphere.
TEST(ImageSpread, ElevationOffTheRingsWidensTheImage) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  // az 135 is the one azimuth both rings have a speaker at (M+135 and
  // U+135), so each ring images it as a point and everything between the two
  // is a split across them.
  EXPECT_NEAR(Spread(*m, 135.0f, 0, 1.0f), 0.0f, 0.05f);
  EXPECT_NEAR(Spread(*m, 135.0f, 30.0f, 1.0f), 0.0f, 0.05f);
  EXPECT_GT(Spread(*m, 135.0f, 15.0f, 1.0f), 10.0f);
  // Above the top ring, rising to the whole ring at the zenith.
  float prev = 0;
  for (const float el : {40.0f, 50.0f, 60.0f, 70.0f, 80.0f, 90.0f}) {
    const float deg = Spread(*m, 22.5f, el, 1.0f);
    EXPECT_GT(deg, prev) << "el=" << el;
    prev = deg;
  }
  EXPECT_NEAR(Spread(*m, 22.5f, 90.0f, 1.0f), 60.0f, 0.05f);
  EXPECT_NEAR(Spread(*m, 180.0f, 90.0f, 0.3f), 60.0f, 0.05f);
}

// At d = 0 the pan has collapsed to the whole ring of the source's layer,
// and the azimuth stops reaching the output: every bearing measures the
// same width because every bearing produces the same gain vector. The
// elevation still chooses the ring, so it keeps mattering -- 88.2 for the
// mid ring, 60 for the top one.
//
// This is what a cartesian (0, 0, 0) object converts to: the conversion
// yields azimuth 0, elevation 0, distance 0, and the azimuth there is an
// artefact of the degenerate input rather than a bearing the render uses.
TEST(ImageSpread, ZeroDistanceDiscardsTheAzimuth) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  for (const float az : {0.0f, 30.0f, 90.0f, 135.0f, 180.0f, -45.0f}) {
    EXPECT_NEAR(Spread(*m, az, 0.0f, 0.0f), 88.196f, 0.01f) << "az=" << az;
    // Above the mid ring the top ring is driven instead, again whatever
    // the bearing.
    EXPECT_NEAR(Spread(*m, az, 30.0f, 0.0f), 60.0f, 0.01f) << "az=" << az;
    // Below it the source floors onto the mid ring.
    EXPECT_NEAR(Spread(*m, az, -60.0f, 0.0f), 88.196f, 0.01f) << "az=" << az;
  }
  // Just off zero the bearing is back in play.
  EXPECT_NEAR(Spread(*m, 0.0f, 0.0f, 0.1f), 84.232f, 0.01f);
  EXPECT_NEAR(Spread(*m, 90.0f, 0.0f, 0.1f), 90.070f, 0.01f);
}

// A pan inside one layer has no vertical extent at all, because the speakers
// carrying it share an elevation. This is the ordinary case on 7.1.4 -- a
// front phantom, a rear pan, anything at d < 1 -- and it is why the image is
// a shape rather than a radius: drawn as a circle, every one of these claims
// a vertical smear the render does not produce.
TEST(ImageSpread, APanInsideOneLayerIsFlat) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  for (const float az : {22.5f, 60.0f, 180.0f, -105.0f}) {
    for (const float d : {1.0f, 0.5f, 0.0f}) {
      const ImageSpread s = m->Measure(At(az, 0, d));
      EXPECT_NEAR(s.ratio, 0.0f, 1e-3) << "az=" << az << " d=" << d;
      // Flat means horizontal here: the widest axis lies along the ring.
      EXPECT_NEAR(s.tilt_deg, 0.0f, 0.5f) << "az=" << az << " d=" << d;
    }
  }
  // All of the width is across, none of it up.
  const auto [major, minor] = Axes(*m, 22.5f, 0, 1);
  EXPECT_NEAR(major, 9.17f, 0.05f);
  EXPECT_NEAR(minor, 0.0f, 0.05f);
}

// The same the other way up: M+135 and U+135 share an azimuth, so a source
// between them images as a vertical line and nothing across.
TEST(ImageSpread, APanBetweenTheLayersIsUpright) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  for (const float el : {7.5f, 15.0f, 22.5f}) {
    const ImageSpread s = m->Measure(At(135, el, 1));
    EXPECT_NEAR(s.ratio, 0.0f, 1e-3) << "el=" << el;
    EXPECT_NEAR(s.tilt_deg, 90.0f, 0.5f) << "el=" << el;
  }
  const auto [major, minor] = Axes(*m, 135, 15, 1);
  EXPECT_NEAR(major, 15.0f, 0.05f);
  EXPECT_NEAR(minor, 0.0f, 0.05f);
}

// Only a source driving a whole ring around its own axis is round. At the
// zenith the four top speakers surround the direction evenly, so the two
// axes are equal -- and each is the 60 degrees to a speaker divided by
// root two, the width being shared between them.
TEST(ImageSpread, TheZenithIsRound) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  const ImageSpread s = m->Measure(At(0, 90, 1));
  EXPECT_NEAR(s.rms_deg, 60.0f, 0.05f);
  EXPECT_NEAR(s.ratio, 1.0f, 1e-3);
  const auto [major, minor] = Axes(*m, 0, 90, 1);
  EXPECT_NEAR(major, 60.0f, 0.05f);
  EXPECT_NEAR(minor, major, 0.05f);
}

// Between those extremes the image is an ellipse with a real tilt. A source
// off both a speaker and a layer is split four ways, and the axes come out
// unequal without either collapsing.
TEST(ImageSpread, AnOffAxisSourceIsAnEllipse) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  const ImageSpread s = m->Measure(At(90, 15, 1));
  EXPECT_NEAR(s.rms_deg, 32.67f, 0.05f);
  EXPECT_GT(s.ratio, 0.4f);
  EXPECT_LT(s.ratio, 0.9f);
  const auto [major, minor] = Axes(*m, 90, 15, 1);
  EXPECT_NEAR(major, s.rms_deg, 0.01f);
  EXPECT_LT(minor, major);
  EXPECT_GT(minor, 0.4f * major);
}

// What a cartesian (0, 0, 0) object actually drives. Every one of the mid
// ring's seven speakers carries exactly 1/sqrt(7), the rears at +/-135
// included, and the top ring and LFE are silent. So the render's footprint
// is the whole horizontal ring at one level, and the preview's halo -- a
// cap of the measured 88.2 degrees, centred on the azimuth the conversion
// invented -- reaches only +/-88.2 and misses the rears entirely. No cap
// radius fixes that; the footprint is a band, not a patch.
TEST(ImageSpread, TheRoomCentreDrivesTheWholeMidRingEqually) {
  constexpr int kFrames = 2048;
  ObjectKeyframe k;
  k.start_s = 0;
  k.position.polar = {0.0f, 0.0f, 0.0f};
  ObjectSource o;
  o.label = "centre";
  o.track_index = 1;
  o.importance = 10;
  o.timeline = {k};
  Scene scene;
  scene.objects = {o};
  std::vector<std::vector<float>> tracks = {std::vector<float>(kFrames, 1.0f)};

  const Layout& layout = ImportLayout();
  auto out = RenderChannelBed(scene, layout, tracks, 48000, 0, nullptr);
  ASSERT_TRUE(out.ok());
  const float kEven = 1.0f / std::sqrt(7.0f);
  for (int ch = 0; ch < layout.num_channels(); ++ch) {
    double acc = 0;
    for (int n = kFrames - kFrames / 4; n < kFrames; ++n) acc += (*out)[ch][n];
    const double g = acc / (kFrames / 4);
    const Speaker& s = layout.speakers[ch];
    const bool mid = !s.is_lfe && std::abs(s.elevation) < 0.5f;
    EXPECT_NEAR(g, mid ? kEven : 0.0f, 1e-4)
        << "ch=" << ch << " az=" << s.azimuth << " el=" << s.elevation;
  }
}

// How strongly the gains agree on a direction. Two speakers sharing a
// source agree almost completely; the zenith's four top speakers agree
// half; the whole mid ring driven equally barely agrees at all, and the
// centre reported there is an artefact rather than a direction. The
// preview draws the last case as a band around the ring instead of a patch
// centred on that artefact.
TEST(ImageSpread, FocusFallsAsTheGainsStopAgreeingOnADirection) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  EXPECT_NEAR(m->Measure(At(0, 0, 1)).focus, 1.0f, 1e-3);
  EXPECT_GT(m->Measure(At(22.5f, 0, 1)).focus, 0.98f);
  EXPECT_NEAR(m->Measure(At(0, 90, 1)).focus, 0.5f, 0.01f);
  EXPECT_NEAR(m->Measure(At(22.5f, 0, 0.5f)).focus, 0.71f, 0.02f);
  // The room centre: no direction is favoured, and every bearing gives the
  // same figure because the azimuth no longer reaches the output.
  for (const float az : {0.0f, 90.0f, 180.0f}) {
    EXPECT_NEAR(m->Measure(At(az, 0, 0)).focus, 0.188f, 0.01f) << "az=" << az;
  }
}

// Below the mid ring 7.1.4 has no speakers, so the render collapses the
// source onto that ring and widens it the way distance does -- the gain
// calculator scales distance by cos(elevation) once a source leaves the
// layer range. A source under the floor is therefore diffuse, not a point
// at 0 degrees, which is what the preview's mark says by carrying a halo at
// the elevation it was clamped to.
TEST(ImageSpread, BelowTheMidRingWidensTheImageToo) {
  auto m = ImageSpreadMeter::Create(ImportLayout());
  ASSERT_NE(m, nullptr);
  EXPECT_LT(Spread(*m, 15.0f, -10.0f, 1.0f), 20.0f);
  EXPECT_GT(Spread(*m, 15.0f, -60.0f, 1.0f), 45.0f);
  EXPECT_NEAR(Spread(*m, 15.0f, -90.0f, 1.0f), 88.2f, 0.1f);
}

}  // namespace
}  // namespace adm2iamf
