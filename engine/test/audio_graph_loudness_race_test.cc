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

// Regression test for issue ES-145 — loudness meter use-after-free on a
// meter reset that races the audio thread.
//
// The mix-bus loudness meter rebuilds its EbuR128Analyzer on reset()/
// reconfigure() (the analyzer has no in-place reset, so the unique_ptr is
// reassigned and the live object freed). That runs on the control thread
// while the audio thread may be inside LoudnessMeter::process(), called
// from AudioGraph::process(). Before the fence (AudioGraph's
// loudness_reconfiguring_/loudness_ack_ handshake), the control thread
// could free the analyzer while the audio thread dereferenced it —
// `c0000005` / heap-use-after-free in EbuR128Analyzer::Process.
//
// This test drives AudioGraph::process() in a tight loop on a second
// thread (standing in for the device callback) while the main thread
// hammers reset_meters(), exactly the pause→meterReset scenario from the
// report. set_audio_running(true) engages the fence (it would otherwise
// short-circuit with no callback thread registered).
//
// Run under AddressSanitizer to catch the regression:
//   bazel test --config=asan //test:audio_graph_loudness_race_test
// Without the fence ASAN faults inside EbuR128Analyzer::Process on the
// process() thread — exactly the ES-145 stack (GetSampleFromOrigin ←
// ProcessImpl ← Process ← LoudnessMeter::process ← AudioGraph::process).
// It surfaces as container-overflow or heap-use-after-free depending on
// timing (the control thread reallocates the analyzer's internal vectors
// and frees the object while the audio thread reads it). With the fence:
// clean.
//
// NOTE: under --config=tsan this also surfaces the *benign* peak/rms
// meter-state POD races that reset_meters() shares with the audio thread
// (flagged benign and out of scope for ES-145), so ASAN — which targets the
// actual use-after-free — is the intended sanitizer. The production FFI
// path no longer has those races: eclipsa_studio_meter_reset pauses and waits
// for callback quiescence before calling reset_meters() (ES-281); this test
// still sees them only because it calls reset_meters() directly, below
// that barrier.

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "graph/audio_graph.h"
#include "gtest/gtest.h"
#include "meters/loudness_meter.h"
#include "renderer/oar_renderer.h"
#include "test/test_wav_helper.h"

namespace {

TEST(AudioGraphLoudnessRaceTest, ResetMetersDuringProcessIsUseAfterFreeFree) {
  const std::string dir = test_wav::temp_dir();
  const std::string sine = dir + "/loudness_race_12ch_48k.wav";
  ASSERT_TRUE(test_wav::write_sine(sine, 12, 48000, 16, 440.f, 1.f));

  // Heap-allocated: AudioGraph pre-allocates several MB of element/mix
  // buffers, far too large for the stack.
  auto graph = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph->init(48000, 512, 2));
  ASSERT_EQ(graph->add_element(7, sine.c_str()), 0);
  // Register the element as 7.1.4 and monitor in stereo so process()
  // renders through OAR and feeds the mix-bus loudness meter.
  ASSERT_TRUE(graph->oar_renderer()->add_element(7, /*type=*/0,
                                                 /*sub_type=*/8, 12));
  const uint64_t masks[2] = {1ull << 0, 1ull << 1};
  ASSERT_EQ(graph->set_layout_and_routing(2, masks, 2), 0);

  // Tell the fence a callback is "running" so reset_meters() actually
  // waits for the process() thread to leave the meter (the production
  // signal AudioThread::start() sets).
  graph->set_audio_running(true);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::atomic<bool> stop{false};
  std::atomic<uint64_t> blocks{0};
  AudioGraph* g = graph.get();
  std::thread audio([&] {
    std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
    while (!stop.load(std::memory_order_relaxed)) {
      g->process(out.data(), kFrames, kChannels);
      blocks.fetch_add(1, std::memory_order_relaxed);
    }
  });

  // Wait until the process() thread is actually running so resets race a
  // live meter rather than a not-yet-started thread.
  while (blocks.load(std::memory_order_relaxed) < 4) {
    std::this_thread::yield();
  }

  // Hammer the reset path; each reset frees and rebuilds the analyzer.
  for (int i = 0; i < 1000; ++i) {
    graph->reset_meters();
  }

  stop.store(true, std::memory_order_relaxed);
  audio.join();

  // Reaching here without an ASAN report (or a native access violation)
  // is the pass condition — the analyzer was never used after free.
  SUCCEED();
}

// ── Monitoring layout switches (issue ES-833) ──────────────────────────────
//
// A layout switch changes the OAR output channel count, and the mix-bus
// loudness meter must be reconfigured for the new count before the audio
// thread feeds it a block of the new layout.

constexpr uint32_t kStereo = 2;  // ck_oar_layout_stereo, 2 channels
constexpr uint32_t k714 = 8;     // ck_oar_layout_714, 12 channels

// A graph with one 12-channel 7.1.4 element, so process() renders
// through OAR and feeds the loudness meter.
std::unique_ptr<AudioGraph> MakeGraphWith714Element(const std::string& name) {
  const std::string path = test_wav::temp_dir() + "/" + name;
  EXPECT_TRUE(test_wav::write_sine(path, 12, 48000, 16, 440.f, 1.f));
  auto graph = std::make_unique<AudioGraph>();
  EXPECT_TRUE(graph->init(48000, 512, 2));
  EXPECT_EQ(graph->add_element(7, path.c_str()), 0);
  EXPECT_TRUE(graph->oar_renderer()->add_element(7, /*type=*/0,
                                                 /*sub_type=*/8, 12));
  return graph;
}

// While offline-exclusive mode is held the OAR rebuild is deferred and the
// channel count stays at the old value. Releasing the mode replays the
// rebuild; the meter must follow it to the new channel count. Before the
// fix the meter stayed at 12 channels for the rest of the session while
// the renderer produced 2.
TEST(AudioGraphLoudnessLayoutTest, DeferredSwitchResyncsMeterOnRelease) {
  auto graph = MakeGraphWith714Element("loudness_deferred_714.wav");
  ASSERT_TRUE(graph->set_monitoring_layout(k714));
  const LoudnessMeter* meter = graph->mix_loudness_meter();
  ASSERT_NE(meter, nullptr);
  ASSERT_EQ(meter->num_channels(), 12u);

  graph->oar_renderer()->begin_offline_exclusive();
  ASSERT_TRUE(graph->set_monitoring_layout(kStereo));
  // Deferred: the renderer still reports 12 channels, and the meter keeps
  // its 7.1.4 configuration to match.
  EXPECT_EQ(graph->oar_renderer()->channel_count(), 12u);
  EXPECT_EQ(meter->num_channels(), 12u);
  EXPECT_EQ(meter->layout(), k714);

  graph->end_offline_exclusive();
  EXPECT_EQ(graph->oar_renderer()->channel_count(), 2u);
  EXPECT_EQ(meter->num_channels(), 2u);
  EXPECT_EQ(meter->layout(), kStereo);

  // The meter now measures the stereo render: 600 ms of a full-scale sine
  // produces a momentary reading, and no block was skipped.
  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
  for (int i = 0; i < 60; ++i) graph->process(out.data(), kFrames, kChannels);
  EXPECT_EQ(meter->mismatched_blocks(), 0u);
  EXPECT_GT(graph->meter_state()->loudness.lufs_momentary, -70.0f);
}

// A release that replays a deferred element-only rebuild (a rendering
// config commit, no layout change) keeps the meter's configuration and its
// accumulated integrated loudness.
TEST(AudioGraphLoudnessLayoutTest, DeferredElementRebuildKeepsIntegrated) {
  auto graph = MakeGraphWith714Element("loudness_release_714.wav");
  ASSERT_TRUE(graph->set_monitoring_layout(k714));

  // 60 blocks of 512 frames at 48 kHz = 640 ms, more than one 400 ms
  // gating block, so the integrated reading is established.
  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
  for (int i = 0; i < 60; ++i) graph->process(out.data(), kFrames, kChannels);
  const float integrated = graph->meter_state()->loudness.lufs_integrated;
  ASSERT_GT(integrated, -120.0f);
  ASSERT_NE(integrated, 0.0f);

  OarRenderer* oar = graph->oar_renderer();
  oar->begin_offline_exclusive();
  // Default mode is 1 (binaural world-locked); 2 differs, so the commit
  // stages a rebuild, which offline-exclusive mode defers.
  ASSERT_TRUE(oar->set_element_rendering_config(7, /*mode=*/2, /*profile=*/0));
  ASSERT_TRUE(oar->commit_rendering_config());
  ASSERT_TRUE(graph->end_offline_exclusive());  // replayed the rebuild

  EXPECT_EQ(graph->mix_loudness_meter()->num_channels(), 12u);
  EXPECT_EQ(graph->mix_loudness_meter()->layout(), k714);
  // A meter reconfigure would have zeroed the loudness state.
  EXPECT_FLOAT_EQ(graph->meter_state()->loudness.lufs_integrated, integrated);
}

// resync_loudness_meter_if_stale() after a non-layout rebuild that keeps
// the channel count leaves the meter and its integrated reading alone.
TEST(AudioGraphLoudnessLayoutTest, ResyncIfStaleIsNoOpWhenMeterMatches) {
  auto graph = MakeGraphWith714Element("loudness_resync_noop_714.wav");
  ASSERT_TRUE(graph->set_monitoring_layout(k714));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
  for (int i = 0; i < 60; ++i) graph->process(out.data(), kFrames, kChannels);
  const float integrated = graph->meter_state()->loudness.lufs_integrated;
  ASSERT_GT(integrated, -120.0f);
  ASSERT_NE(integrated, 0.0f);

  // An element-only rebuild: a second 7.1.4 element registered with OAR.
  ASSERT_TRUE(graph->oar_renderer()->add_element(8, /*type=*/0,
                                                 /*sub_type=*/8, 12));
  graph->resync_loudness_meter_if_stale();

  EXPECT_EQ(graph->mix_loudness_meter()->num_channels(), 12u);
  EXPECT_EQ(graph->mix_loudness_meter()->layout(), k714);
  EXPECT_FLOAT_EQ(graph->meter_state()->loudness.lufs_integrated, integrated);
}

// A renderer rebuild that changes the channel count without going through
// set_monitoring_layout() (the path a failed rebuild followed by a later
// successful one takes) leaves the meter stale; the renderer's blocks are
// skipped until resync_loudness_meter_if_stale() reconfigures the meter.
TEST(AudioGraphLoudnessLayoutTest, ResyncIfStaleReconfiguresStaleMeter) {
  auto graph = MakeGraphWith714Element("loudness_resync_stale_714.wav");
  const LoudnessMeter* meter = graph->mix_loudness_meter();
  ASSERT_EQ(meter->num_channels(), 2u);  // init() configures stereo

  // Bypass AudioGraph: the meter is not told about the new layout.
  ASSERT_TRUE(graph->oar_renderer()->set_layout(k714));
  ASSERT_EQ(graph->oar_renderer()->channel_count(), 12u);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
  graph->process(out.data(), kFrames, kChannels);
  EXPECT_GT(meter->mismatched_blocks(), 0u);  // stale: block skipped

  graph->resync_loudness_meter_if_stale();
  EXPECT_EQ(meter->num_channels(), 12u);
  EXPECT_EQ(meter->layout(), k714);

  const uint64_t skipped = meter->mismatched_blocks();
  for (int i = 0; i < 4; ++i) graph->process(out.data(), kFrames, kChannels);
  EXPECT_EQ(meter->mismatched_blocks(), skipped);
}

// Layout switches while a callback thread runs process() in a tight loop.
// The loudness fence is held from before the OAR rebuild until the meter
// is reconfigured, so the meter never receives a block whose channel count
// differs from its configuration; LoudnessMeter::process() counts any
// such block it skips. Before the fix the window between the OAR rebuild
// and the meter reconfigure was a few microseconds per switch, so this
// test does not reliably reproduce the old failure; it checks that 100
// switches with a callback running skip no block and run under the
// sanitizer configs without a report.
TEST(AudioGraphLoudnessLayoutTest, SwitchesDuringProcessNeverMismatchMeter) {
  auto graph = MakeGraphWith714Element("loudness_switch_714.wav");
  const uint64_t masks12[12] = {1ull << 0, 1ull << 1, 0, 0, 0, 0,
                                0,         0,         0, 0, 0, 0};
  const uint64_t masks2[2] = {1ull << 0, 1ull << 1};
  ASSERT_EQ(graph->set_layout_and_routing(k714, masks12, 12), 0);
  graph->set_audio_running(true);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::atomic<bool> stop{false};
  std::atomic<uint64_t> blocks{0};
  AudioGraph* g = graph.get();
  std::thread audio([&] {
    std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
    while (!stop.load(std::memory_order_relaxed)) {
      g->process(out.data(), kFrames, kChannels);
      blocks.fetch_add(1, std::memory_order_relaxed);
    }
  });
  while (blocks.load(std::memory_order_relaxed) < 4) {
    std::this_thread::yield();
  }

  for (int i = 0; i < 100; ++i) {
    if (i % 2 == 0) {
      ASSERT_EQ(graph->set_layout_and_routing(kStereo, masks2, 2), 0);
    } else {
      ASSERT_EQ(graph->set_layout_and_routing(k714, masks12, 12), 0);
    }
    // Let a few callbacks render the new layout before the next switch.
    const uint64_t target = blocks.load(std::memory_order_relaxed) + 2;
    while (blocks.load(std::memory_order_relaxed) < target) {
      std::this_thread::yield();
    }
  }

  stop.store(true, std::memory_order_relaxed);
  audio.join();
  graph->set_audio_running(false);

  EXPECT_EQ(graph->mix_loudness_meter()->mismatched_blocks(), 0u);
  EXPECT_EQ(graph->mix_loudness_meter()->num_channels(), 12u);
}

}  // namespace
