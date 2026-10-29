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
// audio-thread wiring and the size-mismatch guard. ElementInputRoutingTest
// covers the per-element input routing map (set_element_routing).

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <vector>

#include "engine.h"
#include "graph/audio_graph.h"
#include "graph/routing_scatter.h"
#include "gtest/gtest.h"
#include "renderer/channel_order.h"
#include "test_output_helper.h"
#include "test_wav_helper.h"

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

// ── scatter_routed_ramped (output-channel solo and mute, ES-999) ───────────

TEST(RampedScatter, AtUnityMatchesThePlainScatter) {
  const auto rendered = MakePlanar(/*rch=*/2, kFr, 10.0f);
  const uint64_t masks[2] = {1ull << 1, 1ull << 0};  // swapped
  const uint32_t channels = 2;
  std::vector<float> plain(static_cast<size_t>(kFr) * channels, 0.0f);
  std::vector<float> ramped(plain.size(), 0.0f);
  float gains[2] = {1.0f, 1.0f};

  scatter_routed(plain.data(), rendered.data(), masks, 2, kFr, channels);
  scatter_routed_ramped(ramped.data(), rendered.data(), masks,
                        /*silenced=*/0, gains, /*step=*/0.25f, 2, kFr,
                        channels);

  EXPECT_EQ(ramped, plain);
  EXPECT_FLOAT_EQ(gains[0], 1.0f);
  EXPECT_FLOAT_EQ(gains[1], 1.0f);
}

TEST(RampedScatter, RampsASilencedChannelDownAndKeepsTheGain) {
  const auto rendered = MakePlanar(/*rch=*/2, kFr, 10.0f);
  const uint64_t masks[2] = {1ull << 0, 1ull << 1};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);
  float gains[2] = {1.0f, 1.0f};

  scatter_routed_ramped(out.data(), rendered.data(), masks,
                        /*silenced=*/1ull << 1, gains, /*step=*/0.25f, 2, kFr,
                        channels);

  const float ramp[kFr] = {0.75f, 0.5f, 0.25f, 0.0f};
  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[kFr + f] * ramp[f]);
  }
  EXPECT_FLOAT_EQ(gains[0], 1.0f);
  EXPECT_FLOAT_EQ(gains[1], 0.0f);

  // The next block starts from the gain reached: silent throughout.
  std::fill(out.begin(), out.end(), 0.0f);
  scatter_routed_ramped(out.data(), rendered.data(), masks,
                        /*silenced=*/1ull << 1, gains, /*step=*/0.25f, 2, kFr,
                        channels);
  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.0f);
  }
}

TEST(RampedScatter, RampsARestoredChannelBackUp) {
  const auto rendered = MakePlanar(/*rch=*/1, kFr, 10.0f);
  const uint64_t masks[1] = {1ull << 0};
  const uint32_t channels = 1;
  std::vector<float> out(kFr, 0.0f);
  float gains[1] = {0.0f};

  scatter_routed_ramped(out.data(), rendered.data(), masks, /*silenced=*/0,
                        gains, /*step=*/0.4f, 1, kFr, channels);

  // Stops at unity rather than overshooting it.
  const float ramp[kFr] = {0.4f, 0.8f, 1.0f, 1.0f};
  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f], rendered[f] * ramp[f]);
  }
  EXPECT_FLOAT_EQ(gains[0], 1.0f);
}

TEST(RampedScatter, SplitAndSumCarryTheChannelGain) {
  // OAR ch0 splits to device ch0 and ch1; OAR ch1 sums into device ch1.
  const auto rendered = MakePlanar(/*rch=*/2, kFr, 10.0f);
  const uint64_t masks[2] = {(1ull << 0) | (1ull << 1), 1ull << 1};
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);
  float gains[2] = {1.0f, 1.0f};

  scatter_routed_ramped(out.data(), rendered.data(), masks,
                        /*silenced=*/1ull << 0, gains, /*step=*/0.5f, 2, kFr,
                        channels);

  const float ramp[kFr] = {0.5f, 0.0f, 0.0f, 0.0f};
  for (uint32_t f = 0; f < kFr; ++f) {
    const float ch0 = rendered[f] * ramp[f];
    EXPECT_FLOAT_EQ(out[f * channels + 0], ch0);
    EXPECT_FLOAT_EQ(out[f * channels + 1], ch0 + rendered[kFr + f]);
  }
}

TEST(RampedScatter, RampsChannel63) {
  // The top bit of the mask: channel 63 ramps, channel 62 does not.
  constexpr uint32_t kRch = 64;
  const auto rendered = MakePlanar(kRch, kFr, 1.0f);
  uint64_t masks[kRch] = {};
  masks[62] = 1ull << 1;
  masks[63] = 1ull << 0;
  const uint32_t channels = 2;
  std::vector<float> out(static_cast<size_t>(kFr) * channels, 0.0f);
  std::vector<float> gains(kRch, 1.0f);

  scatter_routed_ramped(out.data(), rendered.data(), masks,
                        /*silenced=*/1ull << 63, gains.data(),
                        /*step=*/0.25f, kRch, kFr, channels);

  const float ramp[kFr] = {0.75f, 0.5f, 0.25f, 0.0f};
  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[63 * kFr + f] * ramp[f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], rendered[62 * kFr + f]);
  }
  EXPECT_FLOAT_EQ(gains[63], 0.0f);
  EXPECT_FLOAT_EQ(gains[62], 1.0f);
}

TEST(RampedScatter, OutOfRangeBitsAreSkipped) {
  const auto rendered = MakePlanar(/*rch=*/1, kFr, 10.0f);
  // bit 0 (in range) + bit 5 (past a 2-channel device, must be ignored).
  const uint64_t masks[1] = {(1ull << 0) | (1ull << 5)};
  const uint32_t channels = 2;
  constexpr float kSentinel = 999.0f;
  std::vector<float> out(static_cast<size_t>(kFr) * channels + 8, kSentinel);
  for (uint32_t i = 0; i < kFr * channels; ++i) out[i] = 0.0f;
  float gains[1] = {1.0f};

  scatter_routed_ramped(out.data(), rendered.data(), masks,
                        /*silenced=*/1ull << 0, gains, /*step=*/0.25f, 1, kFr,
                        channels);

  const float ramp[kFr] = {0.75f, 0.5f, 0.25f, 0.0f};
  for (uint32_t f = 0; f < kFr; ++f) {
    EXPECT_FLOAT_EQ(out[f * channels + 0], rendered[f] * ramp[f]);
    EXPECT_FLOAT_EQ(out[f * channels + 1], 0.0f);
  }
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

TEST(NoiseProcess, OutputMuteDoesNotCutCalibrationNoise) {
  // Output-channel mute (ES-999) cuts the program; a lit calibration cell
  // on the muted channel still reaches the device.
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, 512, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(kFrames * kChannels, 0.0f);

  graph->set_output_solo_mute(/*soloed=*/0, /*muted=*/1ull << 0);
  graph->set_noise(/*row=*/1, /*channel=*/0, /*amp=*/1.0f);

  // Past the 15 ms a cut would take to ramp out (two blocks), then
  // measure.
  for (int i = 0; i < 4; ++i) graph->process(out.data(), kFrames, kChannels);
  float peak0 = 0.0f;
  for (int i = 0; i < 4; ++i) {
    graph->process(out.data(), kFrames, kChannels);
    for (uint32_t f = 0; f < kFrames; ++f) {
      peak0 = std::max(peak0, std::fabs(out[f * kChannels + 0]));
    }
  }
  EXPECT_GT(peak0, 0.1f);
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

// ── Per-element input routing (ES-838) ──────────────────────────────────────

// A 3-channel element whose channels carry the constant levels 0.5,
// 0.25 and 0.125, so the element meters show which source channel
// reached each destination channel after the remap.
class ElementInputRoutingTest : public ::testing::Test {
 protected:
  static constexpr uint32_t kFrames = 512;
  static constexpr uint32_t kCh = 2;
  static constexpr float kLevels[3] = {0.5f, 0.25f, 0.125f};

  void SetUp() override {
    wav_ = test_wav::temp_dir() + "/element_routing_3ch.wav";
    std::vector<int16_t> frames;
    for (int f = 0; f < 48000; ++f) {
      for (float level : kLevels) {
        frames.push_back(static_cast<int16_t>(level * 32768.0f));
      }
    }
    ASSERT_TRUE(test_wav::write_frames_s16(wav_, 3, 48000, frames));
    graph_ = std::make_unique<AudioGraph>();
    ASSERT_TRUE(graph_->init(48000, kFrames, kCh));
    ASSERT_EQ(graph_->add_element(1, wav_.c_str()), 0);
  }

  // Runs one block and returns the per-channel peaks of the element in
  // meter slot `slot`.
  std::vector<float> ProcessAndReadPeaks(uint32_t slot = 0) {
    std::vector<float> out(kFrames * kCh);
    EXPECT_TRUE(graph_->wait_for_wav_streams(kFrames));
    graph_->process(out.data(), kFrames, kCh);
    const EclipsaStudioMeterData& m = graph_->meter_state()->elements[slot];
    std::vector<float> peaks(m.channel_count);
    for (uint32_t c = 0; c < peaks.size(); ++c) peaks[c] = m.peak[c];
    return peaks;
  }

  std::string wav_;
  std::unique_ptr<AudioGraph> graph_;
};

TEST_F(ElementInputRoutingTest, IdentityWithoutAMap) {
  EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.5f, 0.25f, 0.125f}));
}

TEST_F(ElementInputRoutingTest, MapReordersAndSilencesChannels) {
  // dest 0 <- src 2, dest 1 <- src 0, dest 2 silent, dest 3 <- src 1.
  const int8_t map[4] = {2, 0, -1, 1};
  graph_->set_element_routing(1, map, 4);
  EXPECT_EQ(ProcessAndReadPeaks(),
            (std::vector<float>{0.125f, 0.5f, 0.0f, 0.25f}));
}

TEST_F(ElementInputRoutingTest, SourceIndexPastTheFileIsSilent) {
  const int8_t map[2] = {5, 0};
  graph_->set_element_routing(1, map, 2);
  EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.0f, 0.5f}));
}

TEST_F(ElementInputRoutingTest, ClearRestoresIdentity) {
  const int8_t swap[2] = {1, 0};
  graph_->set_element_routing(1, swap, 2);
  ASSERT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.25f, 0.5f}));

  graph_->set_element_routing(1, nullptr, 0);
  EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.5f, 0.25f, 0.125f}));

  graph_->set_element_routing(1, swap, 2);
  ASSERT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.25f, 0.5f}));
  graph_->set_element_routing(1, swap, 0);  // len 0 clears as well
  EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.5f, 0.25f, 0.125f}));
}

// Several updates between two blocks: the block applies the last one,
// whatever the earlier ones were.
TEST_F(ElementInputRoutingTest, BlockAppliesTheLatestOfSeveralUpdates) {
  const int8_t first[1] = {0};
  const int8_t second[2] = {2, 2};
  graph_->set_element_routing(1, first, 1);
  graph_->set_element_routing(1, second, 2);
  EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.125f, 0.125f}));

  const int8_t third[1] = {1};
  const int8_t fourth[2] = {0, 1};
  graph_->set_element_routing(1, third, 1);
  graph_->set_element_routing(1, nullptr, 0);
  graph_->set_element_routing(1, fourth, 2);
  EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{0.5f, 0.25f}));

  // Six rounds of one update and one block: the audio thread reads each
  // of the three slots twice.
  for (int i = 0; i < 6; ++i) {
    const int8_t map[1] = {static_cast<int8_t>(i % 3)};
    graph_->set_element_routing(1, map, 1);
    EXPECT_EQ(ProcessAndReadPeaks(), (std::vector<float>{kLevels[i % 3]}));
  }
}

// remove_element() moves the last chain into the freed slot; the moved
// chain keeps its routing.
TEST_F(ElementInputRoutingTest, RoutingMovesWithItsChainOnRemove) {
  ASSERT_EQ(graph_->add_element(2, wav_.c_str()), 0);
  const int8_t map[2] = {2, 1};
  graph_->set_element_routing(2, map, 2);
  ASSERT_EQ(ProcessAndReadPeaks(/*slot=*/1),
            (std::vector<float>{0.125f, 0.25f}));

  graph_->remove_element(1);
  EXPECT_EQ(ProcessAndReadPeaks(/*slot=*/0),
            (std::vector<float>{0.125f, 0.25f}));
  // A later update reaches the moved chain.
  const int8_t swap[2] = {1, 0};
  graph_->set_element_routing(2, swap, 2);
  EXPECT_EQ(ProcessAndReadPeaks(/*slot=*/0), (std::vector<float>{0.25f, 0.5f}));
}

// A map published while no block runs (the transport is paused) is still
// pending when remove_element() compacts; the moved chain applies it.
TEST_F(ElementInputRoutingTest, PendingRoutingMovesWithItsChainOnRemove) {
  ASSERT_EQ(graph_->add_element(2, wav_.c_str()), 0);
  const int8_t map[2] = {2, 1};
  graph_->set_element_routing(2, map, 2);  // No block before the remove.
  graph_->remove_element(1);
  EXPECT_EQ(ProcessAndReadPeaks(/*slot=*/0),
            (std::vector<float>{0.125f, 0.25f}));
}

// ── 9.1.6 monitoring channel order (ES-960) ─────────────────────────────────

// Per-device-channel peak over one block of interleaved output.
std::vector<float> DevicePeaks(const std::vector<float>& out, uint32_t frames,
                               uint32_t channels) {
  std::vector<float> peaks(channels, 0.0f);
  for (uint32_t f = 0; f < frames; ++f) {
    for (uint32_t c = 0; c < channels; ++c) {
      peaks[c] = std::max(peaks[c], std::fabs(out[f * channels + c]));
    }
  }
  return peaks;
}

// A mono object on a 9.1.6 target with the identity patch. OLR renders
// the layout in Sound System H order (L60 R60 C LFE1 L135 R135 L30 R30
// ...), so an object at +30 degrees lands on OLR channel 6 and one at
// +60 degrees on OLR channel 0. The monitoring path reorders the block
// into OBR's alternative order before the scatter and the output
// meters, so the +30 degree source reaches device channel 0 (FLc) and
// the +60 degree source device channel 4 (FL), and the output meter
// indices follow the same order.
TEST(MonitoringOrder, Alt916ReordersRoutingAndOutputMeters) {
  const std::string wav = test_wav::temp_dir() + "/routing_916_object.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(wav, 1, 48000, 16, 440.f, 4 * 48000,
                                          /*amplitude=*/0.25f));

  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kCh = 16;
  constexpr uint32_t k916 = eclipsa_studio::kOarLayout916;
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, kFrames, kCh));
  ASSERT_EQ(graph->add_element(1, wav.c_str()), 0);
  ASSERT_TRUE(graph->oar_renderer()->add_element(1, /*type=object*/ 2,
                                                 /*num_objects=*/1,
                                                 /*channels=*/1));
  graph->set_element_object(1, true);
  ASSERT_TRUE(test_output::set_layout_identity(*graph, k916, kCh));
  ASSERT_EQ(graph->oar_renderer()->channel_count(), kCh);
  ASSERT_EQ(graph->oar_renderer()->rendered_layout(), k916);

  // (azimuth, expected device channel): FLc is output 0, FL output 4.
  const struct {
    float az;
    uint32_t device;
  } cases[] = {{30.0f, 0}, {60.0f, 4}};
  for (const auto& c : cases) {
    graph->set_element_object_position(1, 1, c.az, 0.0f, 1.0f, 0.0f, 0.0f,
                                       0.0f);
    // Past the element mute ramp and OLR's position gain ramp.
    test_output::run_blocks(*graph, test_output::kWarmupBlocks, kFrames, kCh);

    std::vector<float> out(static_cast<size_t>(kFrames) * kCh, 0.0f);
    graph->process(out.data(), kFrames, kCh);
    const std::vector<float> device = DevicePeaks(out, kFrames, kCh);
    float meters[kCh] = {};
    ASSERT_EQ(graph->get_output_peaks(meters, kCh), kCh);

    for (uint32_t d = 0; d < kCh; ++d) {
      if (d == c.device) {
        EXPECT_GT(device[d], 0.1f) << "az " << c.az << ": device " << d;
        EXPECT_GT(meters[d], 0.1f) << "az " << c.az << ": meter " << d;
      } else {
        EXPECT_LT(device[d], 0.005f) << "az " << c.az << ": device " << d;
        EXPECT_LT(meters[d], 0.005f) << "az " << c.az << ": meter " << d;
      }
    }
  }
}

// A 16-channel WAV with a tone on channel 0 only.
std::string WriteTone16(const std::string& name) {
  constexpr int kCh = 16;
  constexpr int kFrames = 4 * 48000;
  std::vector<int16_t> frames(static_cast<size_t>(kFrames) * kCh, 0);
  for (int i = 0; i < kFrames; ++i) {
    const float t = static_cast<float>(i) / 48000.0f;
    frames[static_cast<size_t>(i) * kCh] = static_cast<int16_t>(
        std::sin(2.0f * 3.14159265f * 440.0f * t) * 0.25f * 32767.0f);
  }
  const std::string path = test_wav::temp_dir() + "/" + name;
  if (!test_wav::write_frames_s16(path, kCh, 48000, frames)) return {};
  return path;
}

// A 9.1.6 channel element on a 9.1.6 target with the identity patch.
// Declared in OBR's alt order, WAV channel 0 is FLc: the engine feeds
// it to OLR channel 6 (L30), which the monitoring path sends to device
// channel 0. Declared in OAR's order, the same WAV channel is FL (L60,
// OLR channel 0), which reaches device channel 4. The element's own
// meters stay in the element's order either way: slot 0 carries the
// tone, slot 6 stays silent.
TEST(MonitoringOrder, Alt916ElementIsFedToOlrInItsOrder) {
  const std::string wav = WriteTone16("routing_916_alt_element.wav");
  ASSERT_FALSE(wav.empty());

  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kCh = 16;
  constexpr uint32_t k916 = eclipsa_studio::kOarLayout916;
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, kFrames, kCh));
  ASSERT_TRUE(test_output::add_wav_element(*graph, 1, wav, k916, kCh));
  ASSERT_TRUE(test_output::set_layout_identity(*graph, k916, kCh));

  const struct {
    uint32_t order;
    uint32_t device;
  } cases[] = {{eclipsa_studio::kChannelOrder916Alt, 0},
               {eclipsa_studio::kChannelOrderOar, 4}};
  for (const auto& c : cases) {
    graph->set_element_channel_order(1, c.order);
    test_output::run_blocks(*graph, test_output::kWarmupBlocks, kFrames, kCh);

    std::vector<float> out(static_cast<size_t>(kFrames) * kCh, 0.0f);
    graph->process(out.data(), kFrames, kCh);
    const std::vector<float> device = DevicePeaks(out, kFrames, kCh);
    for (uint32_t d = 0; d < kCh; ++d) {
      if (d == c.device) {
        EXPECT_GT(device[d], 0.1f) << "order " << c.order << ": device " << d;
      } else {
        EXPECT_LT(device[d], 0.005f) << "order " << c.order << ": device " << d;
      }
    }
    const EclipsaStudioMeterState* state = graph->meter_state();
    ASSERT_NE(state, nullptr);
    EXPECT_GT(state->elements[0].peak[0], 0.1f) << "order " << c.order;
    EXPECT_FLOAT_EQ(state->elements[0].peak[6], 0.0f) << "order " << c.order;
  }
}

// The element input order on another target, where only the input
// semantic matters: OLR takes a 9.1.6 element in the same Sound System
// H order it renders. On a 7.1.4 target (L30 R30 C LFE L90 R90 L135
// R135 and four tops) with the identity patch, a WAV tone on channel 0
// declared in the alt order is FLc at 30 degrees and lands on device
// channel 0 alone; declared in OAR's order it is FL at 60 degrees,
// which OLR pans between L30 (device 0) and L90 (device 4).
TEST(MonitoringOrder, Alt916ElementOnA714Target) {
  const std::string wav = WriteTone16("routing_916_alt_on_714.wav");
  ASSERT_FALSE(wav.empty());

  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kCh = 12;
  constexpr uint32_t k916 = eclipsa_studio::kOarLayout916;
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, kFrames, kCh));
  ASSERT_TRUE(test_output::add_wav_element(*graph, 1, wav, k916, 16));
  ASSERT_TRUE(
      test_output::set_layout_identity(*graph, test_output::kLayout714, kCh));

  std::vector<float> out(static_cast<size_t>(kFrames) * kCh, 0.0f);

  graph->set_element_channel_order(1, eclipsa_studio::kChannelOrder916Alt);
  test_output::run_blocks(*graph, test_output::kWarmupBlocks, kFrames, kCh);
  graph->process(out.data(), kFrames, kCh);
  const std::vector<float> alt = DevicePeaks(out, kFrames, kCh);
  EXPECT_GT(alt[0], 0.1f);
  for (uint32_t d = 1; d < kCh; ++d) EXPECT_LT(alt[d], 0.005f) << d;

  graph->set_element_channel_order(1, eclipsa_studio::kChannelOrderOar);
  test_output::run_blocks(*graph, test_output::kWarmupBlocks, kFrames, kCh);
  graph->process(out.data(), kFrames, kCh);
  const std::vector<float> oar = DevicePeaks(out, kFrames, kCh);
  EXPECT_GT(oar[0], 0.01f);
  EXPECT_GT(oar[4], 0.01f);
  EXPECT_LT(oar[0], alt[0]);
  for (uint32_t d = 1; d < kCh; ++d) {
    if (d == 4) continue;
    EXPECT_LT(oar[d], 0.005f) << d;
  }
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
