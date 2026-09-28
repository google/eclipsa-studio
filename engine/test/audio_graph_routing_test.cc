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

// Routing scatter + pink-noise injection tests.
//
// The bulk drives the pure scatter_routed / scatter_noise helpers (no OAR
// renderer needed) so the matrix maths is checked in isolation. A couple of
// cases go through AudioGraph::process() and the engine FFI to cover the
// audio-thread wiring and the size-mismatch guard.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <vector>

#include "engine.h"
#include "graph/audio_graph.h"
#include "graph/routing_scatter.h"
#include "gtest/gtest.h"

namespace {

// Planar OAR render fixture: channel c, frame f -> base*(c+1) + f.
std::vector<float> MakePlanar(uint32_t rch, uint32_t fr, float base) {
  std::vector<float> v(static_cast<size_t>(rch) * fr);
  for (uint32_t c = 0; c < rch; ++c) {
    for (uint32_t f = 0; f < fr; ++f) {
      v[static_cast<size_t>(c) * fr + f] = base * (c + 1) + f;
    }
  }
  return v;
}

constexpr uint32_t kFr = 4;

// ── scatter_routed ────────────────────────────────────────────────────────

TEST(RoutingScatter, IdentityMatchesFlatInterleave) {
  const auto rendered = MakePlanar(/*rch=*/2, kFr, /*base=*/10.0f);
  const uint64_t masks[2] = {1ull << 0, 1ull << 1};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_routed(out.data(), rendered.data(), masks, 2, kFr, channels);

  // Identity == the old flat planar->interleaved copy, byte for byte.
  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[0 * kFr + f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[1 * kFr + f]);
  }
}

TEST(RoutingScatter, IdentityTailZeroesExtraDeviceChannels) {
  const auto rendered = MakePlanar(/*rch=*/2, kFr, 10.0f);
  const uint64_t masks[2] = {1ull << 0, 1ull << 1};
  const uint32_t channels = 4;  // device wider than the layout
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_routed(out.data(), rendered.data(), masks, 2, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[0 * kFr + f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[1 * kFr + f]);
    EXPECT_FLOAT_EQ(out[f * channels + 2], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 3], 0.0f);
  }
}

TEST(RoutingScatter, SwapMovesChannels) {
  const auto rendered = MakePlanar(/*rch=*/2, kFr, 10.0f);
  // OAR ch0 -> device ch1, OAR ch1 -> device ch0.
  const uint64_t masks[2] = {1ull << 1, 1ull << 0};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_routed(out.data(), rendered.data(), masks, 2, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[1 * kFr + f]);  // R->ch0
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[0 * kFr + f]);  // L->ch1
  }
}

TEST(RoutingScatter, ZeroMaskMutesChannel) {
  const auto rendered = MakePlanar(/*rch=*/2, kFr, 10.0f);
  const uint64_t masks[2] = {0, 1ull << 1};  // ch0 muted
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_routed(out.data(), rendered.data(), masks, 2, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[1 * kFr + f]);
  }
}

TEST(RoutingScatter, ManyToOneAccumulates) {
  // Both OAR channels feed device ch0 — output is their sum. DC sources so
  // the expected sum is exact.
  std::vector<float> rendered(static_cast<size_t>(2) * kFr, 0.0f);
  for (uint32_t f = 0; f < kFr; ++f) {
    rendered[0 * kFr + f] = 1.0f;
    rendered[1 * kFr + f] = 2.0f;
  }
  const uint64_t masks[2] = {1ull << 0, 1ull << 0};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_routed(out.data(), rendered.data(), masks, 2, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], 3.0f);  // 1 + 2
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.0f);
  }
}

TEST(RoutingScatter, OneToManySplit) {
  const auto rendered = MakePlanar(/*rch=*/1, kFr, 10.0f);
  // OAR ch0 -> device ch1 AND ch3.
  const uint64_t masks[1] = {(1ull << 1) | (1ull << 3)};
  const uint32_t channels = 4;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_routed(out.data(), rendered.data(), masks, 1, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[f]);
    EXPECT_FLOAT_EQ(out[f * channels + 2], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 3], rendered[f]);
  }
}

TEST(RoutingScatter, OutOfRangeBitsAreSkipped) {
  const auto rendered = MakePlanar(/*rch=*/1, kFr, 10.0f);
  // bit 0 (in range) + bit 5 (past a 2-channel device — must be ignored).
  const uint64_t masks[1] = {(1ull << 0) | (1ull << 5)};
  const uint32_t channels = 2;
  // Extra guard slots after the live region, seeded with a sentinel.
  constexpr float kSentinel = 999.0f;
  std::vector<float> out(static_cast<size_t>(kFr) * channels + 8, kSentinel);
  for (uint32_t i = 0; i < kFr * channels; ++i) out[i] = 0.0f;

  scatter_routed(out.data(), rendered.data(), masks, 1, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.0f);
  }
  // Nothing wrote past the live region.
  for (uint32_t i = kFr * channels; i < out.size(); ++i) {
    EXPECT_FLOAT_EQ(out[i], kSentinel);
  }
}

// ── scatter_noise ─────────────────────────────────────────────────────────

TEST(NoiseScatter, RowFollowsThePatch) {
  // Row at OAR ch0, which the patch routes to device ch1.
  const float noise[kFr] = {0.5f, 0.5f, 0.5f, 0.5f};
  const uint64_t routing[1] = {1ull << 1};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_noise(out.data(), noise, /*mode=*/1, /*channel=*/0, routing,
                /*rch=*/1, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.5f);  // followed the patch
  }
}

TEST(NoiseScatter, RowSplitsLikeProgram) {
  const float noise[kFr] = {0.25f, 0.25f, 0.25f, 0.25f};
  const uint64_t routing[1] = {(1ull << 0) | (1ull << 2)};  // split ch0 + ch2
  const uint32_t channels = 4;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_noise(out.data(), noise, /*mode=*/1, /*channel=*/0, routing,
                /*rch=*/1, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], 0.25f);
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 2], 0.25f);
    EXPECT_FLOAT_EQ(out[f * channels + 3], 0.0f);
  }
}

TEST(NoiseScatter, ColGoesStraightToDevice) {
  // Column straight to device ch1, ignoring the routing matrix.
  const float noise[kFr] = {0.5f, 0.5f, 0.5f, 0.5f};
  const uint64_t routing[1] = {1ull << 0};  // patch would say ch0 — ignored
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_noise(out.data(), noise, /*mode=*/2, /*channel=*/1, routing,
                /*rch=*/1, kFr, channels);

  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], 0.0f);
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.5f);  // straight to device ch1
  }
}

TEST(NoiseScatter, OffAndOutOfRangeAreNoOps) {
  const float noise[kFr] = {0.5f, 0.5f, 0.5f, 0.5f};
  const uint64_t routing[1] = {1ull << 0};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);

  scatter_noise(out.data(), noise, /*mode=*/0, 0, routing, 1, kFr, channels);
  scatter_noise(out.data(), noise, /*mode=*/1, /*channel=*/9, routing, 1, kFr,
                channels);  // row channel past rch
  scatter_noise(out.data(), noise, /*mode=*/2, /*channel=*/9, routing, 1, kFr,
                channels);  // col channel past device

  for (float v : out) EXPECT_FLOAT_EQ(v, 0.0f);
}

// ── AudioGraph::process() wiring ──────────────────────────────────────────

TEST(NoiseProcess, ColInjectionReachesDeviceAndMutesElsewhere) {
  // AudioGraph carries ~25 MB of pre-allocated buffers — heap-allocate it so
  // it doesn't blow the stack (the fixture-based tests get this for free).
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, 512, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(kFrames * kChannels, 0.0f);

  // Column noise to device ch0 at unity amplitude.
  graph->set_noise(/*mode=*/2, /*channel=*/0, /*amp=*/1.0f);

  float peak0 = 0.0f, peak1 = 0.0f;
  for (int i = 0; i < 4; ++i) {  // let the generator run up.
    graph->process(out.data(), kFrames, kChannels);
    for (uint32_t f = 0; f < kFrames; ++f) {
      peak0 = std::max(peak0, std::fabs(out[f * kChannels + 0]));
      peak1 = std::max(peak1, std::fabs(out[f * kChannels + 1]));
    }
  }
  EXPECT_GT(peak0, 0.0f);        // noise present on the targeted device ch
  EXPECT_FLOAT_EQ(peak1, 0.0f);  // nothing leaks to the other channel

  // Turning noise off silences the targeted channel again.
  graph->set_noise(/*mode=*/0, 0, 0.0f);
  std::fill(out.begin(), out.end(), 0.0f);
  graph->process(out.data(), kFrames, kChannels);
  float peak_off = 0.0f;
  for (float v : out) peak_off = std::max(peak_off, std::fabs(v));
  EXPECT_FLOAT_EQ(peak_off, 0.0f);
}

TEST(NoiseProcess, RenderNoiseWorksWhilePaused) {
  // render_noise is the paused-transport path: it must inject calibration
  // noise without the graph running process(), so calibration works with no
  // session playing.
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, 512, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(kFrames * kChannels, 0.0f);

  EXPECT_FALSE(graph->noise_active());
  graph->render_noise(out.data(), kFrames, kChannels);
  for (float v : out) EXPECT_FLOAT_EQ(v, 0.0f);  // off -> silence

  graph->set_noise(/*col=*/2, /*channel=*/1, /*amp=*/1.0f);
  EXPECT_TRUE(graph->noise_active());

  float peak0 = 0.0f, peak1 = 0.0f;
  for (int i = 0; i < 4; ++i) {
    graph->render_noise(out.data(), kFrames, kChannels);
    for (uint32_t f = 0; f < kFrames; ++f) {
      peak0 = std::max(peak0, std::fabs(out[f * kChannels + 0]));
      peak1 = std::max(peak1, std::fabs(out[f * kChannels + 1]));
    }
  }
  EXPECT_FLOAT_EQ(peak0, 0.0f);  // nothing on the untargeted channel
  EXPECT_GT(peak1, 0.0f);        // noise on device ch1 even while paused
}

TEST(NoiseProcess, LayoutShrinkClearsStaleMasks) {
  // Regression: a layout/routing push that under-sizes its mask array must not
  // leave a prior wider push's masks live in the unwritten high slots. Here
  // OAR ch5 is first routed to device ch0, then a too-short re-push (len=2)
  // should reset routing_[2..] back to identity so ch5 falls back to device
  // ch5 rather than scattering through the stale ch5->device0 patch.
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, 512, 2));

  constexpr uint32_t k51 = 3;  // ck_oar_layout_51 (5.1 = 6 channels)
  uint64_t wide[6];
  for (uint32_t i = 0; i < 6; ++i) wide[i] = 1ull << i;
  wide[5] = 1ull << 0;  // distinctive stale candidate: ch5 -> device ch0
  ASSERT_EQ(graph->set_layout_and_routing(k51, wide, 6), 0);

  // Re-push the same layout but under-size the masks. A correct caller sizes
  // them to channel_count(); this mimics that wiring bug.
  const uint64_t narrow[2] = {1ull << 0, 1ull << 1};
  ASSERT_EQ(graph->set_layout_and_routing(k51, narrow, 2), 0);

  constexpr uint32_t kFrames = 512, kCh = 6;
  std::vector<float> out(kFrames * kCh, 0.0f);
  graph->set_noise(/*row=*/1, /*channel=*/5, /*amp=*/1.0f);

  float peak0 = 0.0f, peak5 = 0.0f;
  for (int i = 0; i < 4; ++i) {
    graph->render_noise(out.data(), kFrames, kCh);
    for (uint32_t f = 0; f < kFrames; ++f) {
      peak0 = std::max(peak0, std::fabs(out[f * kCh + 0]));
      peak5 = std::max(peak5, std::fabs(out[f * kCh + 5]));
    }
  }
  EXPECT_GT(peak5, 0.0f);        // ch5 follows the identity fallback
  EXPECT_FLOAT_EQ(peak0, 0.0f);  // no leak through the stale ch5->device0 route
}

TEST(NoiseProcess, LiveSetRoutingTakesEffect) {
  // A set_routing call mid-stream (as happens during playback) must be picked
  // up by the next process() callback. Row noise on OAR ch0 is a deterministic
  // signal that follows the patch, so swapping the patch should move it.
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, 512, 2));

  constexpr uint32_t kFrames = 512, kCh = 2;
  std::vector<float> out(kFrames * kCh, 0.0f);
  graph->set_noise(/*row=*/1, /*channel=*/0, /*amp=*/1.0f);

  auto peak = [&](uint32_t dev) {
    float p = 0.0f;
    for (uint32_t f = 0; f < kFrames; ++f) {
      p = std::max(p, std::fabs(out[f * kCh + dev]));
    }
    return p;
  };

  // Identity patch: OAR ch0 -> device ch0.
  for (int i = 0; i < 4; ++i) graph->process(out.data(), kFrames, kCh);
  EXPECT_GT(peak(0), 0.0f);
  EXPECT_FLOAT_EQ(peak(1), 0.0f);

  // Swap the patch live: OAR ch0 -> device ch1.
  const uint64_t swap[2] = {1ull << 1, 1ull << 0};
  ASSERT_EQ(graph->set_routing(swap, 2), 0);

  std::fill(out.begin(), out.end(), 0.0f);
  for (int i = 0; i < 4; ++i) graph->process(out.data(), kFrames, kCh);
  EXPECT_FLOAT_EQ(peak(0), 0.0f);  // old route fell silent
  EXPECT_GT(peak(1), 0.0f);        // noise followed the new patch
}

// ── Engine FFI size-mismatch guard ────────────────────────────────────────

class MonitoringFfiTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ASSERT_EQ(eclipsa_studio_engine_init(48000, 512), 0);
  }
  void TearDown() override { eclipsa_studio_engine_shutdown(); }
};

TEST_F(MonitoringFfiTest, SetRoutingRejectsWrongLength) {
  const uint32_t channels = eclipsa_studio_monitoring_get_channels();
  ASSERT_EQ(channels, 2u);  // default layout is stereo

  // Too few masks for the active layout -> rejected, prior map untouched.
  const uint64_t bad[3] = {1, 2, 4};
  EXPECT_EQ(eclipsa_studio_monitoring_set_routing(bad, 3), -1);
  EXPECT_EQ(eclipsa_studio_monitoring_set_routing(nullptr, channels), -1);

  // Correct length is accepted.
  const uint64_t good[2] = {1ull << 0, 1ull << 1};
  EXPECT_EQ(eclipsa_studio_monitoring_set_routing(good, 2), 0);
}

TEST_F(MonitoringFfiTest, LayoutAndRoutingAndNoiseSucceed) {
  const uint64_t masks[2] = {1ull << 0, 1ull << 1};
  EXPECT_EQ(
      eclipsa_studio_monitoring_set_layout_and_routing(/*stereo=*/2, masks, 2),
      0);
  // Null masks / zero length is rejected.
  EXPECT_EQ(eclipsa_studio_monitoring_set_layout_and_routing(/*stereo=*/2,
                                                             nullptr, 0),
            -1);
  // A length past the 64-channel mask range is rejected.
  std::vector<uint64_t> huge(65, 1);
  EXPECT_EQ(eclipsa_studio_monitoring_set_layout_and_routing(/*stereo=*/2,
                                                             huge.data(), 65),
            -1);

  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*off=*/0, 0, -20.0f), 0);
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*col=*/2, 0, -20.0f), 0);
}

TEST_F(MonitoringFfiTest, SetNoiseRejectsInvalidArgs) {
  // A valid injection is accepted.
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*col=*/2, 0, -20.0f), 0);

  // mode > 2 would register as "noise active" (muting the program) yet scatter
  // nothing, leaving the output silently dead -> rejected.
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*bad=*/3, 0, -20.0f), -1);

  // A non-finite dbfs would make pow() yield a NaN amplitude -> rejected.
  const float nan = std::numeric_limits<float>::quiet_NaN();
  const float inf = std::numeric_limits<float>::infinity();
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*col=*/2, 0, nan), -1);
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*row=*/1, 0, inf), -1);

  // A channel wider than the 24-bit packed field can't round-trip -> rejected.
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*col=*/2, 0x1000000u, -20.0f),
            -1);

  // Off carries no level, so a non-finite dbfs is irrelevant and accepted.
  EXPECT_EQ(eclipsa_studio_monitoring_set_noise(/*off=*/0, 0, nan), 0);
}

}  // namespace
