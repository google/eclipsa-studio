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

#include "adm_import/render/channel_renderer.h"

#include <cmath>
#include <cstdint>
#include <vector>

#include "absl/status/status.h"
#include "adm_import/render/render_progress.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

constexpr int kFrames = 2048;  // >=2 OLR blocks so panning settles.

std::vector<float> Dc(float v) { return std::vector<float>(kFrames, v); }

// Steady-state gain of a channel: mean over the last quarter.
double SteadyGain(const std::vector<float>& ch) {
  const int lo = kFrames - kFrames / 4;
  double acc = 0;
  for (int n = lo; n < kFrames; ++n) acc += ch[n];
  return acc / (kFrames - lo);
}

Source Spk(float az, float el, int track, bool lfe = false) {
  Source s;
  s.position = {az, el, 1.0f};
  s.track_index = track;
  s.is_lfe = lfe;
  return s;
}

// A 7.1.2 bed authored at top-FRONT (U+045) lands bit-exact on its 7.1.4
// channels; the rear-top pair stays silent.
TEST(ChannelRenderer, SevenOneTwoToSevenOneFourIsExactPassthrough) {
  const Layout* l714 = &ImportLayout();
  ASSERT_NE(l714, nullptr);

  // Sources mirror the 7.1.2 channel order; distinct DC per track.
  Scene scene;
  scene.sources = {
      Spk(30, 0, 1),  Spk(-30, 0, 2),
      Spk(0, 0, 3),   Spk(0, 0, 4, /*lfe=*/true),
      Spk(90, 0, 5),  Spk(-90, 0, 6),
      Spk(135, 0, 7), Spk(-135, 0, 8),
      Spk(45, 30, 9), Spk(-45, 30, 10),
  };
  std::vector<std::vector<float>> tracks;
  for (int i = 0; i < 10; ++i) tracks.push_back(Dc(0.1f * (i + 1)));

  RenderStats stats;
  auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, &stats);
  ASSERT_TRUE(out.ok()) << out.status();
  EXPECT_EQ(stats.passthrough, 9);
  EXPECT_EQ(stats.lfe, 1);
  EXPECT_EQ(stats.olr, 0);

  // Each 7.1.4 ear/LFE/top-front channel equals its source, exactly.
  const float kExpect[12] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f,
                             0.7f, 0.8f, 0.9f, 1.0f, 0.0f, 0.0f};
  for (int ch = 0; ch < 12; ++ch) {
    EXPECT_NEAR((*out)[ch][0], kExpect[ch], 1e-6f) << "ch=" << ch;
    EXPECT_NEAR((*out)[ch][kFrames - 1], kExpect[ch], 1e-6f) << "ch=" << ch;
  }
}

// A top-middle source (U+090) into 7.1.4 (no U+090 speaker) phantom-splits
// across the left top-front/top-back pair via OLR -- not a copy.
TEST(ChannelRenderer, TopMiddleSourcePhantomSplitsAcrossTops) {
  const Layout* l714 = &ImportLayout();
  Scene scene;
  scene.sources = {Spk(90, 30, 1)};  // U+090, between U+045 and U+135.
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};

  RenderStats stats;
  auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, &stats);
  ASSERT_TRUE(out.ok()) << out.status();
  EXPECT_EQ(stats.olr, 1);

  const double tf = SteadyGain((*out)[8]);   // U+045 (left top-front)
  const double tb = SteadyGain((*out)[10]);  // U+135 (left top-back)
  const double rtf = SteadyGain((*out)[9]);  // U-045 (right top-front)
  double ear = 0;
  for (int ch = 0; ch < 8; ++ch) ear += std::fabs(SteadyGain((*out)[ch]));

  EXPECT_GT(tf, 0.05);  // Splits onto both left tops...
  EXPECT_GT(tb, 0.05);
  EXPECT_LT(std::fabs(rtf), 0.05);  // ...not the opposite side...
  EXPECT_LT(ear, 0.10);             // ...and barely touches ear level.
  // Left-top energy dominates the whole render.
  double total = 0;
  for (const auto& ch : *out) {
    double g = SteadyGain(ch);
    total += g * g;
  }
  EXPECT_GT(tf * tf + tb * tb, 0.5 * total);
}

ObjectKeyframe Kf(double start_s, float az, float el, float dist,
                  bool jump = false) {
  ObjectKeyframe k;
  k.start_s = start_s;
  k.position.polar = {az, el, dist};
  k.jump = jump;
  return k;
}

// A cartesian-authored keyframe at cube position (x, y, z).
ObjectKeyframe Kc(double start_s, float x, float y, float z) {
  ObjectKeyframe k;
  k.start_s = start_s;
  k.position.cartesian = true;
  k.position.cube = {x, y, z};
  return k;
}

ObjectSource Obj(int track, int importance, std::vector<ObjectKeyframe> kfs) {
  ObjectSource o;
  o.label = "obj";
  o.track_index = track;
  o.importance = importance;
  o.timeline = std::move(kfs);
  return o;
}

double MeanRange(const std::vector<float>& ch, int lo, int hi) {
  double acc = 0;
  for (int n = lo; n < hi; ++n) acc += ch[n];
  return acc / (hi - lo);
}

// How many speakers the image is spread over: the inverse participation
// ratio 1 / sum(p_i^2) of the normalized energy split p_i = g_i^2 / sum g^2.
// 1.0 when one speaker carries everything, N when N share it equally. The
// tests below use it to pin what distance and elevation do to the pan; the
// angular width the preview draws is a different figure, measured in
// image_spread_test.cc.
double EffectiveSpeakers(const std::vector<std::vector<float>>& out) {
  double e = 0;
  std::vector<double> g;
  g.reserve(out.size());
  for (const auto& ch : out) {
    const double v = SteadyGain(ch);
    g.push_back(v);
    e += v * v;
  }
  if (e <= 1e-12) return 0;
  double s = 0;
  for (const double v : g) {
    const double p = v * v / e;
    s += p * p;
  }
  return 1.0 / s;
}

// Renders one static object and returns its steady per-channel gains.
std::vector<double> ObjectGains(float az, float el, float dist) {
  const Layout* l714 = &ImportLayout();
  Scene scene;
  scene.objects = {Obj(1, 10, {Kf(0, az, el, dist)})};
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};
  auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr);
  EXPECT_TRUE(out.ok());
  if (!out.ok()) return {};
  std::vector<double> g;
  for (const auto& ch : *out) g.push_back(SteadyGain(ch));
  return g;
}

double ObjectEffectiveSpeakers(float az, float el, float dist) {
  const Layout* l714 = &ImportLayout();
  Scene scene;
  scene.objects = {Obj(1, 10, {Kf(0, az, el, dist)})};
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};
  auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr);
  EXPECT_TRUE(out.ok());
  if (!out.ok()) return 0;
  return EffectiveSpeakers(*out);
}

// A static object at a speaker angle renders through OLR (never passthrough)
// and lands ~coincident on that speaker.
TEST(ChannelRenderer, StaticObjectRendersThroughOlr) {
  const Layout* l714 = &ImportLayout();
  Scene scene;
  scene.objects = {Obj(1, 10, {Kf(0, 90, 0, 1.0f)})};  // az 90 == Lss
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};

  RenderStats stats;
  auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, &stats);
  ASSERT_TRUE(out.ok()) << out.status();
  EXPECT_EQ(stats.objects, 1);
  EXPECT_GT(SteadyGain((*out)[4]), 0.9);  // Lss carries it.
}

// A moving object: az +90 in block 0, then a jump to az -90 -- energy moves
// Lss -> Rss as the timeline advances (allowing for OLR's transition ramp).
TEST(ChannelRenderer, ObjectFollowsItsTimeline) {
  const Layout* l714 = &ImportLayout();
  const int kN = 8192;
  Scene scene;
  scene.objects = {
      Obj(1, 10, {Kf(0, 90, 0, 1.0f), Kf(0.02, -90, 0, 1.0f, /*jump=*/true)})};
  std::vector<std::vector<float>> tracks = {std::vector<float>(kN, 1.0f)};

  auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr);
  ASSERT_TRUE(out.ok()) << out.status();
  // Block 0 settled (768..1023): on Lss (ch4), not Rss (ch5).
  EXPECT_GT(MeanRange((*out)[4], 768, 1024), 0.8);
  EXPECT_LT(MeanRange((*out)[5], 768, 1024), 0.1);
  // Fully settled after the jump (kN-256..kN): on Rss (ch5), not Lss (ch4).
  EXPECT_GT(MeanRange((*out)[5], kN - 256, kN), 0.8);
  EXPECT_LT(MeanRange((*out)[4], kN - 256, kN), 0.1);
}

// Objects below the importance floor are dropped, leaving silence.
TEST(ChannelRenderer, ImportanceFilterDropsLowObjects) {
  const Layout* l714 = &ImportLayout();
  Scene scene;
  scene.objects = {Obj(1, 5, {Kf(0, 0, 0, 1.0f)})};
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};

  RenderStats stats;
  auto out = RenderChannelBed(scene, *l714, tracks, 48000,
                              /*importance_threshold=*/8, &stats);
  ASSERT_TRUE(out.ok());
  EXPECT_EQ(stats.objects, 0);
  EXPECT_EQ(stats.objects_dropped, 1);
  for (const auto& ch : *out) EXPECT_NEAR(ch[1000], 0.0f, 1e-6f);
}

// Regression guard (research §7.3.1): distance changes spread, NOT broadband
// level. An object at d=0.5 must not be ~+6 dB louder than at d=1 (the
// iamf-tools panner's 1/d bug); total energy stays within ~3 dB.
TEST(ChannelRenderer, DistanceDoesNotBoostLevel) {
  const Layout* l714 = &ImportLayout();
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};

  auto energy = [&](float dist) {
    Scene scene;
    scene.objects = {Obj(1, 10, {Kf(0, 22, 5, dist)})};  // off-speaker angle
    auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr);
    EXPECT_TRUE(out.ok());
    double e = 0;
    for (const auto& ch : *out) {
      double g = SteadyGain(ch);
      e += g * g;
    }
    return e;
  };
  const double e1 = energy(1.0f);
  const double e_half = energy(0.5f);
  ASSERT_GT(e1, 1e-6);
  const double ratio = e_half / e1;
  EXPECT_LT(ratio, 2.0) << "d=0.5 boosted by ~" << 10 * std::log10(ratio)
                        << " dB (1/d bug?)";
  EXPECT_GT(ratio, 0.5);
}

// What distance *does* do, measured rather than read off the fork: at d = 1
// the pan is pure VBAP, so only the two mid-ring speakers bracketing the
// source carry gain. Channel order is M+030, M-030, M+000, LFE, M+090,
// M-090, M+135, M-135, U+045, U-045, U+135, U-135; az 22 sits between
// M+000 and M+030.
TEST(ChannelRenderer, DistanceOneIsPureVbap) {
  const std::vector<double> g = ObjectGains(22, 0, 1.0f);
  ASSERT_EQ(g.size(), 12u);
  EXPECT_GT(g[0], 0.1) << "M+030 should bracket az 22";
  EXPECT_GT(g[2], 0.1) << "M+000 should bracket az 22";
  for (int ch : {1, 4, 5, 6, 7, 8, 9, 10, 11}) {
    EXPECT_LT(std::abs(g[ch]), 0.02) << "ch=" << ch << " must stay silent";
  }
  EXPECT_LT(ObjectEffectiveSpeakers(22, 0, 1.0f), 2.2);
}

// Below d = 1 the pan blends DBAP in, spreading the image over more speakers
// of the source's own layer the smaller the distance gets. Measured on the
// mid ring, which has 7 non-LFE speakers:
//
//   d     1.0    0.9    0.8    0.7    0.5    0.25   0.1    0.0
//   eff   1.27   1.27   1.57   1.86   2.62   5.30   6.74   7.00
//
// The band from 0.9 to 1.0 is flat: the blend there is half DBAP, but at a
// DBAP radius of 0.8 that is still a point image, so reading the zone
// boundaries out of the fork's source overstates what happens. Below 0.9
// the spread rises monotonically to the whole ring. Nothing here moves the
// image toward the listener, which is why the preview's marks stay on the
// hull.
TEST(ChannelRenderer, DistanceBelowOneSpreadsTheImage) {
  const double sharp = ObjectEffectiveSpeakers(22, 0, 1.0f);
  EXPECT_NEAR(ObjectEffectiveSpeakers(22, 0, 0.9f), sharp, 0.02 * sharp)
      << "0.9..1.0 must stay VBAP-sharp; the preview draws no spread there";

  const std::vector<float> sweep = {0.9f, 0.8f,  0.7f, 0.6f, 0.5f,
                                    0.4f, 0.25f, 0.1f, 0.0f};
  std::vector<double> eff;
  eff.reserve(sweep.size());
  for (const float d : sweep) eff.push_back(ObjectEffectiveSpeakers(22, 0, d));
  for (size_t i = 1; i < eff.size(); ++i) {
    EXPECT_GT(eff[i], eff[i - 1])
        << "d=" << sweep[i] << " (" << eff[i] << " speakers) should be more "
        << "diffuse than d=" << sweep[i - 1] << " (" << eff[i - 1] << ")";
  }
  // d = 0 puts the source at the centre of the ring: all 7 mid speakers
  // equally, which is the preview's fully-diffuse end stop.
  EXPECT_NEAR(eff.back(), 7.0, 0.05);
}

// Elevation above the top ring is imaged by spreading across that ring, not
// by panning to a point above it. The gain calculator scales distance by
// cos(elevation) once the source leaves the layer range (0 and 30 degrees on
// 7.1.4), which pulls DBAP in exactly as a small distance does, and the
// layerwise panner has already collapsed the source onto the ring. Measured
// at d = 1, over the top ring's 4 speakers:
//
//   el    30     40     50     60     70     80     90
//   eff   1.35   1.41   1.84   2.27   2.96   3.70   4.00
//
// So the zenith is reached by driving the whole ring evenly. A mark at 80
// degrees is where the render images it, but as a diffuse source, not a
// point; image_spread_test.cc measures how wide.
TEST(ChannelRenderer, ElevationAboveTheTopRingSpreadsAcrossIt) {
  const std::vector<float> sweep = {30.0f, 40.0f, 50.0f, 60.0f,
                                    70.0f, 80.0f, 90.0f};
  std::vector<double> eff;
  eff.reserve(sweep.size());
  for (const float el : sweep)
    eff.push_back(ObjectEffectiveSpeakers(22, el, 1.0f));
  EXPECT_LT(eff.front(), 1.5) << "30 degrees is the top ring itself: a pair";
  for (size_t i = 1; i < eff.size(); ++i) {
    EXPECT_GT(eff[i], eff[i - 1])
        << "el=" << sweep[i] << " (" << eff[i] << ") should be more diffuse "
        << "than el=" << sweep[i - 1] << " (" << eff[i - 1] << ")";
  }
  EXPECT_NEAR(eff.back(), 4.0, 0.05) << "the zenith is the whole top ring";
}

// The progress hook reports a non-decreasing frames_done that reaches
// frames_total, with one OLR-pass worth of work counted per non-coincident
// source and per object (here: 2 sources phantomed + 1 object = 3 passes).
TEST(ChannelRenderer, ProgressReportsMonotonicAndReachesTotal) {
  const Layout* l714 = &ImportLayout();
  const int kN = 4096;
  Scene scene;
  // Two non-coincident bed sources (off-speaker angles) + one object: 3 passes.
  scene.sources = {Spk(22, 5, 1), Spk(-22, 5, 2)};
  scene.objects = {Obj(3, 10, {Kf(0, 70, 10, 1.0f)})};
  std::vector<std::vector<float>> tracks = {std::vector<float>(kN, 1.0f),
                                            std::vector<float>(kN, 1.0f),
                                            std::vector<float>(kN, 1.0f)};

  uint64_t last_done = 0, final_total = 0;
  int calls = 0;
  bool monotonic = true;
  RenderProgress progress;
  progress.report = [&](uint64_t done, uint64_t total) {
    if (done < last_done) monotonic = false;
    last_done = done;
    final_total = total;
    ++calls;
  };

  auto out =
      RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr, &progress);
  ASSERT_TRUE(out.ok()) << out.status();
  EXPECT_GT(calls, 0);
  EXPECT_TRUE(monotonic);
  EXPECT_EQ(final_total, static_cast<uint64_t>(3) * kN);  // 3 passes * frames.
  EXPECT_EQ(last_done, final_total);                      // Reaches 100%.
}

// Cancelling mid-render aborts with CancelledError.
TEST(ChannelRenderer, CancelAbortsRender) {
  const Layout* l714 = &ImportLayout();
  Scene scene;
  scene.objects = {Obj(1, 10, {Kf(0, 70, 10, 1.0f)})};
  std::vector<std::vector<float>> tracks = {std::vector<float>(48000, 1.0f)};

  RenderProgress progress;
  progress.should_cancel = [] { return true; };  // Cancel at the first block.

  auto out =
      RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr, &progress);
  ASSERT_FALSE(out.ok());
  EXPECT_EQ(out.status().code(), absl::StatusCode::kCancelled);
}

// The layout-anchored conversion's acceptance criterion (ES-567): a cartesian
// object pushed into a room-cube corner lands entirely on that corner's real
// speaker on 7.1.4 (the fixed-anchor map phantom-imaged these between its
// ±30/±110 anchors instead). Cube convention: x right, y front, z up.
TEST(ChannelRenderer, CartesianCornersPinToRealSpeakersOn714) {
  const Layout* l714 = &ImportLayout();
  std::vector<std::vector<float>> tracks = {Dc(1.0f)};
  struct Corner {
    float x, y, z;
    const char* speaker;
  };
  const Corner corners[] = {
      {-1.0f, -1.0f, 0.0f, "M+135"},  // rear-left wall corner
      {1.0f, -1.0f, 0.0f, "M-135"},   // rear-right wall corner
      {1.0f, 1.0f, 1.0f, "U-045"},    // top-front-right cube corner
      {-1.0f, -1.0f, 1.0f, "U+135"},  // top-back-left cube corner
  };
  for (const Corner& c : corners) {
    Scene scene;
    scene.objects = {Obj(1, 10, {Kc(0, c.x, c.y, c.z)})};
    auto out = RenderChannelBed(scene, *l714, tracks, 48000, 0, nullptr);
    ASSERT_TRUE(out.ok()) << out.status();
    double total = 0;
    double best = 0;
    int best_ch = -1;
    for (int ch = 0; ch < l714->num_channels(); ++ch) {
      const double g = SteadyGain((*out)[ch]);
      total += g * g;
      if (g * g > best) {
        best = g * g;
        best_ch = ch;
      }
    }
    ASSERT_GT(total, 1e-6);
    EXPECT_GT(best / total, 0.99)
        << "corner (" << c.x << "," << c.y << "," << c.z << ") not pinned";
    ASSERT_GE(best_ch, 0);
    EXPECT_EQ(l714->speakers[best_ch].name, c.speaker)
        << "corner (" << c.x << "," << c.y << "," << c.z << ")";
  }
}

// ConvertObjectPosition with no anchors must fall back to the fixed sector
// map (oar.h's prescribed fallback for a failed anchor derivation) — NOT
// layout mode with NULL anchors, which oar silently maps to the balloon
// conversion. This pins the helper's contract only: RenderChannelBed and the
// probe refuse to run without anchors rather than take this path.
TEST(ChannelRenderer, NullAnchorsFallBackToSectorMap) {
  ObjectPosition p;
  p.cartesian = true;
  p.cube = {0.6f, 0.4f, 0.2f};
  const Polar got = ConvertObjectPosition(p, nullptr);
  const polar_t want = oar_cartesian_to_polar(nullptr, ck_oar_pos_conv_sector,
                                              {0.6f, 0.4f, 0.2f});
  EXPECT_EQ(got.azimuth, want.azimuth);
  EXPECT_EQ(got.elevation, want.elevation);
  EXPECT_EQ(got.distance, want.distance);

  ObjectPosition polar_pos;
  polar_pos.polar = {30.0f, 10.0f, 0.5f};
  const Polar through = ConvertObjectPosition(polar_pos, nullptr);
  EXPECT_EQ(through.azimuth, 30.0f);  // Polar passes through untouched.
}

}  // namespace
}  // namespace adm2iamf
