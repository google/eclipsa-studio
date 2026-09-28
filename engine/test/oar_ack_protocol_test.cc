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

// Exercises the reconfiguring/ack protocol against a live simulated
// audio thread. One thread uses an `oar_t` at a time; the ack is how the
// control thread knows the audio thread has stopped using it.
//
// Every other OarRenderer test runs with no audio thread, so every ack
// wait times out and only the *timeout* branches are covered: the
// acked branches of rebuild() (immediate oar_destroy) and
// reap_zombies_locked() were unreachable, even though they are the
// normal path in production and the ones that must not double-free the
// deferred teardowns introduced for ES-158.
//
// The fake audio thread mirrors AudioGraph::process's OAR section
// exactly — skip-and-ack when the control thread is reconfiguring,
// otherwise render and re-check — so the sanitizer sweeps see the real
// interleaving. TSan is the oracle for the happens-before edges
// (reconfiguring_ release/acquire, the ack counter) and ASan for the
// zombie lifetime; the assertions below cover observable state.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <thread>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBlock = 512;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t stereo (2 ch)
constexpr uint32_t k714Layout = 8;     // oar_layout_t 7.1.4 (12 ch)

// Drives OarRenderer the way the real audio callback does. Declare it
// *after* the OarRenderer it wraps so the thread is joined before the
// renderer is destroyed — shutdown() requires no audio thread.
class FakeAudioThread {
 public:
  explicit FakeAudioThread(OarRenderer* renderer) : renderer_(renderer) {
    thread_ = std::thread([this] {
      while (run_.load(std::memory_order_acquire)) {
        float g0 = 0.0f, g1 = 0.0f;
        renderer_->fade_block(kBlock, kSampleRate, &g0, &g1);
        if (renderer_->is_reconfiguring()) {
          renderer_->acknowledge_reconfiguring();
        } else {
          renderer_->render(kBlock);
          // Reconfiguring may have been raised mid-render; the ack is
          // posted after the call returns, which is what lets the
          // control thread destroy the instance safely.
          if (renderer_->is_reconfiguring()) {
            renderer_->acknowledge_reconfiguring();
          }
        }
        std::this_thread::sleep_for(std::chrono::microseconds(200));
      }
    });
  }

  ~FakeAudioThread() {
    run_.store(false, std::memory_order_release);
    thread_.join();
  }

 private:
  OarRenderer* renderer_;
  std::atomic<bool> run_{true};
  std::thread thread_;
};

// With acks arriving, rebuild() takes the acked path: the old instance
// is destroyed inline and nothing is deferred. Repeated switches keep
// the cached channel count in step with the live instance.
TEST(OarAckProtocolTest, AckedRebuildDestroysInline) {
  OarRenderer renderer;
  ASSERT_TRUE(renderer.init(kSampleRate, kBlock, kStereoLayout));
  ASSERT_TRUE(renderer.add_element(1, /*type=*/0, kStereoLayout,
                                   /*channels=*/2));
  FakeAudioThread audio(&renderer);

  for (int i = 0; i < 4; ++i) {
    const uint32_t layout = (i % 2 == 0) ? k714Layout : kStereoLayout;
    ASSERT_TRUE(renderer.set_layout(layout)) << "iteration " << i;
    EXPECT_FALSE(renderer.is_reconfiguring()) << "iteration " << i;
    EXPECT_EQ(renderer.channel_count(), (i % 2 == 0) ? 12u : 2u)
        << "iteration " << i;
  }
}

// A rebuild whose ack times out stashes the old instance and its
// buffers instead of destroying them (ES-158). The next rebuild that
// *does* ack proves no OAR access is in flight and reaps the stash —
// the path that must not double-free.
TEST(OarAckProtocolTest, TimedOutTeardownReapedOnNextAck) {
  OarRenderer renderer;
  ASSERT_TRUE(renderer.init(kSampleRate, kBlock, kStereoLayout));
  ASSERT_TRUE(renderer.add_element(1, /*type=*/0, kStereoLayout,
                                   /*channels=*/2));

  // No audio thread yet — this ack wait times out, so the stereo
  // instance becomes a zombie rather than being destroyed.
  ASSERT_TRUE(renderer.set_layout(k714Layout));
  EXPECT_EQ(renderer.channel_count(), 12u);

  {
    FakeAudioThread audio(&renderer);
    ASSERT_TRUE(renderer.set_layout(kStereoLayout));
    EXPECT_FALSE(renderer.is_reconfiguring());
    EXPECT_EQ(renderer.channel_count(), 2u);
  }

  // Audio thread joined — safe to drive the renderer directly. Output
  // is live on the post-reap instance.
  EXPECT_NE(renderer.render(kBlock), nullptr);
}

// The ES-158 fix under the conditions it actually ships in: a running
// audio thread, an offline pass holding the mode, and the device
// reconfigure path trying to clear the flag underneath it.
TEST(OarAckProtocolTest, OfflineExclusiveHoldsAgainstLiveAudioThread) {
  OarRenderer renderer;
  ASSERT_TRUE(renderer.init(kSampleRate, kBlock, kStereoLayout));
  ASSERT_TRUE(renderer.add_element(1, /*type=*/0, kStereoLayout,
                                   /*channels=*/2));
  FakeAudioThread audio(&renderer);

  renderer.begin_offline_exclusive();
  EXPECT_TRUE(renderer.is_reconfiguring());

  // A device change mid-pass must not resume the live OAR: with a real
  // audio thread spinning, a resume here is the ES-44 race itself.
  renderer.set_reconfiguring(false);
  EXPECT_TRUE(renderer.is_reconfiguring());

  // A second pass entering and leaving mid-hold (Cmd-E while the
  // loudness report measures — the native menu bar is not blocked by
  // the modal barrier) must not resume the live OAR either: the mode
  // is refcounted and only the last exit releases it.
  renderer.begin_offline_exclusive();
  renderer.end_offline_exclusive();
  EXPECT_TRUE(renderer.is_reconfiguring());

  // A layout switch is staged, not executed — no live oar_create /
  // oar_destroy runs while the offline renderers are alive.
  EXPECT_TRUE(renderer.set_layout(k714Layout));
  EXPECT_EQ(renderer.channel_count(), 2u);
  EXPECT_TRUE(renderer.is_reconfiguring());

  // Exit replays the staged layout and hands the audio thread back a
  // live instance.
  renderer.end_offline_exclusive();
  EXPECT_FALSE(renderer.is_reconfiguring());
  EXPECT_EQ(renderer.channel_count(), 12u);
}

}  // namespace
