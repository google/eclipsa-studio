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

// Pins the offline-exclusive contract (ES-158): offline export and
// measurement take exclusive use of the renderer, so while the pass
// holds the mode, live rebuilds are deferred and replayed on exit, and
// the raw set_reconfiguring(false) calls from the device
// start/reconfigure paths cannot resume the live OAR mid-pass.
//
// No audio thread runs here, so every ack wait inside
// begin_offline_exclusive()/rebuild() times out (~500 ms each) — the
// tests assert state, not timing.

#include <cstdint>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"

namespace {

constexpr uint32_t kStereoLayout = 2;  // oar_layout_t stereo (2 ch)
constexpr uint32_t k714Layout = 8;     // oar_layout_t 7.1.4 (12 ch)

TEST(OarOfflineExclusiveTest, DeferredRebuildReplayedOnExit) {
  OarRenderer r;
  ASSERT_TRUE(r.init(48000, 512, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=*/0, kStereoLayout, /*channels=*/2));
  ASSERT_EQ(r.channel_count(), 2u);

  r.begin_offline_exclusive();
  EXPECT_TRUE(r.is_reconfiguring());

  // A layout switch while the mode is held is staged, not executed:
  // no live oar_destroy/oar_create, so the channel count stays put and
  // the audio thread keeps seeing the reconfiguring flag.
  EXPECT_TRUE(r.set_layout(k714Layout));
  EXPECT_EQ(r.channel_count(), 2u);
  EXPECT_TRUE(r.is_reconfiguring());

  // Exit replays the staged state.
  r.end_offline_exclusive();
  EXPECT_FALSE(r.is_reconfiguring());
  EXPECT_EQ(r.channel_count(), 12u);
}

TEST(OarOfflineExclusiveTest, ReconfiguringClearIgnoredWhileHeld) {
  OarRenderer r;
  ASSERT_TRUE(r.init(48000, 512, kStereoLayout));
  r.begin_offline_exclusive();
  EXPECT_TRUE(r.is_reconfiguring());

  // The device reconfigure path's raw flag-clear must not resume the
  // live OAR while an offline pass is running.
  r.set_reconfiguring(false);
  EXPECT_TRUE(r.is_reconfiguring());
  r.set_reconfiguring(true);  // raising is always allowed
  EXPECT_TRUE(r.is_reconfiguring());

  r.end_offline_exclusive();
  EXPECT_FALSE(r.is_reconfiguring());
  r.set_reconfiguring(false);  // and clears work again after exit
  EXPECT_FALSE(r.is_reconfiguring());
}

TEST(OarOfflineExclusiveTest, NestedEnterHeldUntilLastExit) {
  OarRenderer r;
  ASSERT_TRUE(r.init(48000, 512, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=*/0, kStereoLayout, /*channels=*/2));

  // Two overlapping passes (export dialog + loudness report — the
  // native menu bar lets both open at once) nest instead of clashing.
  r.begin_offline_exclusive();
  r.begin_offline_exclusive();
  EXPECT_TRUE(r.is_reconfiguring());

  // A rebuild staged while both hold the mode…
  EXPECT_TRUE(r.set_layout(k714Layout));
  EXPECT_EQ(r.channel_count(), 2u);

  // …survives the first exit: the live OAR must NOT resume while the
  // other pass is still rendering (the ES-44 race the refcount closes).
  r.end_offline_exclusive();
  EXPECT_TRUE(r.is_reconfiguring());
  EXPECT_EQ(r.channel_count(), 2u);
  r.set_reconfiguring(false);  // device path still can't resume it
  EXPECT_TRUE(r.is_reconfiguring());

  // The last exit replays the deferred rebuild and resumes.
  r.end_offline_exclusive();
  EXPECT_FALSE(r.is_reconfiguring());
  EXPECT_EQ(r.channel_count(), 12u);

  r.end_offline_exclusive();  // exit when not held is a no-op
  EXPECT_FALSE(r.is_reconfiguring());
}

}  // namespace
