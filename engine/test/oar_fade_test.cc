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

// Tests for the OAR output fade primitives (issue ES-73): a short
// linear ramp the audio thread applies to the rendered output so OAR
// rebuilds and device stops are click-free. The state machine is
// exercised directly — fade_block plays the audio-thread role, the
// control-thread calls are made inline.

#include <cstdint>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"

namespace {

constexpr uint32_t kRate = 48000;

// Drives fade_block until the gain stops changing; returns the number
// of blocks it took to reach `target`.
int run_to_target(OarRenderer& r, uint32_t frames, float target,
                  int max_blocks = 100) {
  float g0 = -1.0f;
  float g1 = -1.0f;
  for (int blocks = 1; blocks <= max_blocks; ++blocks) {
    r.fade_block(frames, kRate, &g0, &g1);
    if (g1 == target) return blocks;
  }
  return -1;
}

TEST(OarFadeTest, SteadyStateIsUnity) {
  OarRenderer r;
  float g0 = 0.0f;
  float g1 = 0.0f;
  r.fade_block(512, kRate, &g0, &g1);
  EXPECT_EQ(g0, 1.0f);
  EXPECT_EQ(g1, 1.0f);
}

TEST(OarFadeTest, FadeOutRampsAcrossSmallBlocks) {
  OarRenderer r;
  // No audio thread is running, so the wait can't resolve — it must
  // time out (bounded) rather than hang, and the target stays set.
  EXPECT_FALSE(r.fade_out_and_wait(/*timeout_ms=*/1));

  // 64-frame blocks at 48 kHz: a 5 ms fade spans ~240 frames → the
  // ramp needs several blocks, each continuous with the previous.
  float g0 = 0.0f;
  float g1 = 0.0f;
  r.fade_block(64, kRate, &g0, &g1);
  EXPECT_EQ(g0, 1.0f);
  EXPECT_LT(g1, 1.0f);
  EXPECT_GT(g1, 0.0f);

  float prev_end = g1;
  int blocks = 1;
  while (g1 > 0.0f && blocks < 100) {
    r.fade_block(64, kRate, &g0, &g1);
    EXPECT_EQ(g0, prev_end) << "ramp must be continuous across blocks";
    EXPECT_LE(g1, g0);
    prev_end = g1;
    ++blocks;
  }
  EXPECT_EQ(g1, 0.0f);
  EXPECT_GE(blocks, 3);
  EXPECT_LE(blocks, 6);

  // Already silent — the wait now returns immediately.
  EXPECT_TRUE(r.fade_out_and_wait(/*timeout_ms=*/1));
}

TEST(OarFadeTest, LargeBlockSpansWholeFade) {
  OarRenderer r;
  EXPECT_FALSE(r.fade_out_and_wait(/*timeout_ms=*/1));
  // One 2048-frame block exceeds the 5 ms fade — the ramp stretches
  // across the block and lands exactly on silence.
  float g0 = 0.0f;
  float g1 = 0.0f;
  r.fade_block(2048, kRate, &g0, &g1);
  EXPECT_EQ(g0, 1.0f);
  EXPECT_EQ(g1, 0.0f);
}

TEST(OarFadeTest, FadeInRampsBackToUnityAndClamps) {
  OarRenderer r;
  EXPECT_FALSE(r.fade_out_and_wait(/*timeout_ms=*/1));
  ASSERT_EQ(run_to_target(r, 512, 0.0f), 1);  // 512 ≥ 240-frame fade

  r.fade_in();
  const int blocks = run_to_target(r, 64, 1.0f);
  EXPECT_GE(blocks, 3);
  EXPECT_LE(blocks, 6);

  // Clamped at unity: further blocks stay there.
  float g0 = 0.0f;
  float g1 = 0.0f;
  r.fade_block(64, kRate, &g0, &g1);
  EXPECT_EQ(g0, 1.0f);
  EXPECT_EQ(g1, 1.0f);
}

// ES-467: a device-switch reopen ramps back in over kReopenFadeSeconds
// (100 ms) rather than the 5 ms click-killer — long enough to hear as
// a fade, so program audio doesn't snap on at full scale on the new
// hardware. A subsequent fade-out must NOT inherit the stretched
// length: fade_out_and_wait restores the short default so rebuilds
// and reconfigures never stall behind a 100 ms tail.
TEST(OarFadeTest, ReopenFadeInIsStretchedAndFadeOutStaysShort) {
  OarRenderer r;
  EXPECT_FALSE(r.fade_out_and_wait(/*timeout_ms=*/1));
  ASSERT_EQ(run_to_target(r, 512, 0.0f), 1);

  // 100 ms at 48 kHz = 4800 frames → ~9–10 512-frame blocks.
  r.fade_in(OarRenderer::kReopenFadeSeconds);
  const int blocks = run_to_target(r, 512, 1.0f);
  EXPECT_GE(blocks, 8);
  EXPECT_LE(blocks, 12);

  // The next fade-out runs at the short default again: one 512-frame
  // block covers the whole 5 ms (240-frame) ramp.
  EXPECT_FALSE(r.fade_out_and_wait(/*timeout_ms=*/1));
  EXPECT_EQ(run_to_target(r, 512, 0.0f), 1);
}

// ES-515: a declared no-audio-thread instance (offline render / measure)
// short-circuits both waits — nothing would ever advance the gain or
// post an ack — and leaves the fade state at unity: fade_out_and_wait
// must not touch fade_target_ in this mode.
TEST(OarFadeTest, NoAudioThreadShortCircuitsWaits) {
  OarRenderer r;
  r.set_no_audio_thread();
  EXPECT_TRUE(r.fade_out_and_wait(/*timeout_ms=*/1));
  EXPECT_TRUE(r.wait_for_audio_thread_ack(/*timeout_ms=*/1));

  float g0 = 0.0f;
  float g1 = 0.0f;
  r.fade_block(512, kRate, &g0, &g1);
  EXPECT_EQ(g0, 1.0f);
  EXPECT_EQ(g1, 1.0f);
}

TEST(OarFadeTest, SnapCompletesPendingFadeInstantly) {
  OarRenderer r;
  EXPECT_FALSE(r.fade_out_and_wait(/*timeout_ms=*/1));
  // The paused branch of the audio callback snaps the gain (output is
  // silent while paused, so this is inaudible).
  r.fade_snap_to_target();
  EXPECT_TRUE(r.fade_out_and_wait(/*timeout_ms=*/1));

  float g0 = -1.0f;
  float g1 = -1.0f;
  r.fade_block(512, kRate, &g0, &g1);
  EXPECT_EQ(g0, 0.0f);
  EXPECT_EQ(g1, 0.0f);

  r.fade_in();
  r.fade_snap_to_target();
  r.fade_block(512, kRate, &g0, &g1);
  EXPECT_EQ(g0, 1.0f);
  EXPECT_EQ(g1, 1.0f);
}

}  // namespace
