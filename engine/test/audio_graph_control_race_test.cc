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

// Concurrency tests for control-thread calls that the engine makes while
// the audio thread is inside AudioGraph::process(), with no pause or
// quiescence barrier: element gain, element input routing, element add,
// and the output meter reads. Each test runs process() in a loop on a second
// thread, standing in for the device callback, while the main thread makes the
// call. The pass condition is a clean run under ThreadSanitizer:
//   bazel test --config=tsan //test:audio_graph_control_race_test

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "graph/audio_graph.h"
#include "gtest/gtest.h"
#include "meters/meter_state.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kFrames = 512;
constexpr uint32_t kChannels = 2;

// Blocks of process() each test's control calls must overlap. ThreadSanitizer
// sees a race only when the two accesses are close in time, and a fixed
// number of control calls can finish within one or two blocks.
constexpr uint64_t kOverlapBlocks = 200;

// Calls graph->process() in a loop on its own thread from construction
// until destruction. The constructor returns once a few blocks have run,
// so the caller's control calls overlap a running process().
class ProcessLoop {
 public:
  explicit ProcessLoop(AudioGraph* graph)
      : graph_(graph), thread_([this] { Run(); }) {
    while (blocks() < 4) std::this_thread::yield();
  }
  ProcessLoop(const ProcessLoop&) = delete;
  ProcessLoop& operator=(const ProcessLoop&) = delete;
  ~ProcessLoop() {
    stop_.store(true, std::memory_order_relaxed);
    thread_.join();
  }

  // Relaxed on purpose: release/acquire on the counter would order the
  // process() thread's accesses before each later control call, and
  // ThreadSanitizer would then not report the races these tests look for.
  uint64_t blocks() const { return blocks_.load(std::memory_order_relaxed); }

 private:
  void Run() {
    std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
    while (!stop_.load(std::memory_order_relaxed)) {
      graph_->process(out.data(), kFrames, kChannels);
      blocks_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  AudioGraph* graph_;
  std::atomic<bool> stop_{false};
  std::atomic<uint64_t> blocks_{0};
  std::thread thread_;  // Last: starts after the fields above exist.
};

class AudioGraphControlRaceTest : public ::testing::Test {
 protected:
  void SetUp() override {
    sine_ = test_wav::temp_dir() + "/control_race_2ch_48k.wav";
    ASSERT_TRUE(test_wav::write_sine(sine_, 2, 48000, 16, 440.f, 1.f));
    // Heap-allocated: AudioGraph pre-allocates several MB of element
    // buffers, too large for the stack.
    graph_ = std::make_unique<AudioGraph>();
    ASSERT_TRUE(graph_->init(48000, kFrames, kChannels));
  }

  std::string sine_;
  std::unique_ptr<AudioGraph> graph_;
};

// eclipsa_studio_element_set_gain calls set_element_gain() during
// playback. The gain targets it writes are read by Gain::process() on
// the audio thread.
TEST_F(AudioGraphControlRaceTest, SetElementGainWhileProcessing) {
  ASSERT_EQ(graph_->add_element(1, sine_.c_str()), 0);
  {
    ProcessLoop loop(graph_.get());
    const uint64_t end = loop.blocks() + kOverlapBlocks;
    for (int i = 0; loop.blocks() < end; ++i) {
      graph_->set_element_gain(1, (i % 2) ? -6.0f : 0.0f);
    }
  }
  SUCCEED();
}

// eclipsa_studio_element_set_input_routing runs during playback (ES-838).
// Cycles through two maps of different lengths and a clear. The element
// must always meter 2 channels (the file's identity, or the swap) or 4
// (the wide map). The check catches the old clear, which set the length
// to 0 before withdrawing the map, so a block could meter 0 channels.
TEST_F(AudioGraphControlRaceTest, SetElementRoutingWhileProcessing) {
  ASSERT_EQ(graph_->add_element(1, sine_.c_str()), 0);
  const int8_t swap[2] = {1, 0};
  const int8_t wide[4] = {0, 1, 0, 1};
  const EclipsaStudioMeterData& meter = graph_->meter_state()->elements[0];
  {
    ProcessLoop loop(graph_.get());
    const uint64_t end = loop.blocks() + kOverlapBlocks;
    for (int i = 0; loop.blocks() < end; ++i) {
      switch (i % 3) {
        case 0:
          graph_->set_element_routing(1, swap, 2);
          break;
        case 1:
          graph_->set_element_routing(1, wide, 4);
          break;
        default:
          graph_->set_element_routing(1, nullptr, 0);
          break;
      }
      const uint32_t metered = meter.channel_count;
      ASSERT_TRUE(metered == 2 || metered == 4) << metered;
    }
  }
}

// eclipsa_studio_element_add does not pause the audio thread. The
// element count in the shared meter state must have one writer.
TEST_F(AudioGraphControlRaceTest, AddElementWhileProcessing) {
  constexpr uint32_t kAdded = 6;
  {
    ProcessLoop loop(graph_.get());
    for (uint32_t id = 1; id <= kAdded; ++id) {
      ASSERT_EQ(graph_->add_element(id, sine_.c_str()), 0);
      // Read the count as the Dart tick loop does, across several blocks.
      const uint64_t end = loop.blocks() + kOverlapBlocks / kAdded;
      while (loop.blocks() < end) {
        ASSERT_EQ(graph_->meter_state()->element_count, id);
      }
    }
  }
  EXPECT_EQ(graph_->meter_state()->element_count, kAdded);
}

// The Dart tick loop reads the output meters through
// eclipsa_studio_get_output_peaks/rms/clips every frame while process()
// writes them and the output channel count.
TEST_F(AudioGraphControlRaceTest, ReadOutputMetersWhileProcessing) {
  ASSERT_EQ(graph_->add_element(1, sine_.c_str()), 0);
  constexpr uint32_t kMaxRead = 32;
  float levels[kMaxRead];
  uint8_t clips[kMaxRead];
  {
    ProcessLoop loop(graph_.get());
    // Every block since the loop started metered the stereo render.
    const uint64_t end = loop.blocks() + kOverlapBlocks;
    while (loop.blocks() < end) {
      ASSERT_EQ(graph_->get_output_peaks(levels, kMaxRead), kChannels);
      ASSERT_EQ(graph_->get_output_rms(levels, kMaxRead), kChannels);
      ASSERT_EQ(graph_->get_output_clips(clips, kMaxRead), kChannels);
    }
  }
}

}  // namespace
