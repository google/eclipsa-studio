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

// Tests for LiveLoudnessMeter: the audio thread's push() into the ring,
// the meter thread's drain into the analyzer, and the control-thread
// reconfiguration calls (ES-905).
//
// PushDoesNotAllocate counts allocations through the sanitizer malloc
// hooks (test/alloc_counter.h), so it runs in the asan and tsan builds
// and is skipped in the others.

#include "meters/live_loudness_meter.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"
#include "meters/loudness_meter.h"
#include "meters/meter_state.h"
#include "test/alloc_counter.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kChannels = 2;
// 480 does not divide the ring capacity (a power of two), so pushes and
// drains cross the end of the ring's planes and take their two-part
// copies; device buffers of 480 and 441 frames are common.
constexpr uint32_t kBlock = 480;

// Planar storage for `frames` frames of a 1 kHz sine on every channel,
// with an AudioBuffer view of block `index` (kBlock frames each).
struct Signal {
  std::vector<float> storage;
  uint32_t frames;

  Signal(uint32_t channels, uint32_t n_frames, float amplitude)
      : storage(static_cast<size_t>(channels) * n_frames), frames(n_frames) {
    constexpr float kPi = 3.14159265358979323846f;
    for (uint32_t c = 0; c < channels; ++c) {
      for (uint32_t f = 0; f < n_frames; ++f) {
        storage[static_cast<size_t>(c) * n_frames + f] =
            amplitude * std::sin(2.0f * kPi * 1000.0f * static_cast<float>(f) /
                                 static_cast<float>(kSampleRate));
      }
    }
  }

  uint32_t blocks() const { return frames / kBlock; }

  AudioBuffer block(uint32_t index, uint32_t channels) {
    AudioBuffer b;
    b.data = storage.data() + static_cast<size_t>(index) * kBlock;
    b.channels = channels;
    b.frames = kBlock;
    b.capacity_frames = frames;  // channel stride of the backing store
    return b;
  }
};

// Pushes every block of `sig`, draining every eighth block so the ring
// never fills.
void PushAndDrain(LiveLoudnessMeter& live, Signal& sig, uint32_t channels) {
  for (uint32_t i = 0; i < sig.blocks(); ++i) {
    live.push(sig.block(i, channels), kBlock);
    if (i % 8 == 7) live.drain();
  }
  live.drain();
}

// The readings after pushing the signal block by block, draining every
// eighth block, equal those of a LoudnessMeter fed the same blocks
// directly: the ring passes every frame through, in order.
TEST(LiveLoudnessMeterTest, MatchesLoudnessMeterOnTheSameBlocks) {
  Signal sig(kChannels, 3 * kSampleRate, 0.5f);

  EclipsaStudioLoudnessData live_out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &live_out);
  EclipsaStudioMeterState direct{};
  LoudnessMeter meter(kSampleRate, kChannels);
  for (uint32_t i = 0; i < sig.blocks(); ++i) {
    const AudioBuffer b = sig.block(i, kChannels);
    live.push(b, kBlock);
    meter.process(b, kBlock, direct);
    if (i % 8 == 7) live.drain();
  }
  live.drain();

  EXPECT_EQ(live.dropped_frames(), 0u);
  EXPECT_EQ(live.mismatched_blocks(), 0u);
  ASSERT_GT(direct.loudness.lufs_integrated, -20.0f);
  EXPECT_NEAR(live_out.lufs_integrated, direct.loudness.lufs_integrated, 1e-3f);
  EXPECT_NEAR(live_out.lufs_momentary, direct.loudness.lufs_momentary, 1e-3f);
  EXPECT_NEAR(live_out.lufs_short_term, direct.loudness.lufs_short_term, 1e-3f);
  EXPECT_NEAR(live_out.true_peak, direct.loudness.true_peak, 1e-3f);
}

// The meter thread drains on its own: the readings appear without a
// drain() call.
TEST(LiveLoudnessMeterTest, MeterThreadPublishesWithoutADrainCall) {
  // Half a second: past the 400 ms momentary window, and within the ring.
  Signal sig(kChannels, kSampleRate / 2, 0.5f);
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);
  for (uint32_t i = 0; i < sig.blocks(); ++i) {
    live.push(sig.block(i, kChannels), kBlock);
  }
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (out.lufs_momentary < -70.0f &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(LiveLoudnessMeter::kPollInterval);
  }
  EXPECT_GT(out.lufs_momentary, -70.0f);
}

TEST(LiveLoudnessMeterTest, MismatchedChannelCountIsSkipped) {
  Signal sig(6, kSampleRate, 0.5f);
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);
  live.push(sig.block(0, 6), kBlock);
  live.push(sig.block(1, 6), kBlock);
  live.drain();
  EXPECT_EQ(live.mismatched_blocks(), 2u);
  EXPECT_FLOAT_EQ(out.lufs_momentary, -120.0f);
}

// A block larger than the ring's free space is dropped whole and
// counted; the ring keeps accepting blocks that fit.
TEST(LiveLoudnessMeterTest, BlockLargerThanTheRingIsDropped) {
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);
  const uint32_t too_big = live.ring_capacity() + 1;
  Signal big(kChannels, too_big, 0.5f);
  AudioBuffer b;
  b.data = big.storage.data();
  b.channels = kChannels;
  b.frames = too_big;
  b.capacity_frames = too_big;
  live.push(b, too_big);
  EXPECT_EQ(live.dropped_frames(), too_big);

  Signal sig(kChannels, kSampleRate, 0.5f);
  PushAndDrain(live, sig, kChannels);
  EXPECT_EQ(live.dropped_frames(), too_big);
  EXPECT_GT(out.lufs_momentary, -70.0f);
}

TEST(LiveLoudnessMeterTest, ResetClearsReadingsAndPendingFrames) {
  Signal sig(kChannels, kSampleRate, 0.5f);
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);
  PushAndDrain(live, sig, kChannels);
  ASSERT_GT(out.lufs_momentary, -70.0f);

  // Frames pending at the reset are dropped with the analyzer state.
  // A push that fits the empty ring always lands before reset() runs on
  // this thread; the meter thread may already have drained it.
  live.push(sig.block(0, kChannels), kBlock);
  live.reset();
  EXPECT_EQ(live.pending_frames(), 0u);
  EXPECT_FLOAT_EQ(out.lufs_momentary, -120.0f);
  EXPECT_FLOAT_EQ(out.lufs_integrated, -120.0f);
}

TEST(LiveLoudnessMeterTest, ReconfigureChangesTheChannelCount) {
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);
  live.reconfigure(6, /*layout=*/0);
  EXPECT_EQ(live.num_channels(), 6u);

  Signal sig(6, kSampleRate, 0.5f);
  PushAndDrain(live, sig, 6);
  EXPECT_EQ(live.mismatched_blocks(), 0u);
  EXPECT_GT(out.lufs_momentary, -70.0f);
}

TEST(LiveLoudnessMeterTest, RingHoldsHalfASecondAtTheSampleRate) {
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);
  EXPECT_EQ(live.ring_capacity(), 32768u);
  live.set_sample_rate(96000);
  EXPECT_EQ(live.ring_capacity(), 65536u);
}

// push() runs on the audio thread and must not allocate. 4 s of blocks
// complete 40 analyzer steps, each of which appends to the analyzer's
// history vectors on the meter thread while this thread pushes. The run
// first makes one allocation of its own and requires the hook to count
// it, so a hook that installs but is not called does not pass.
TEST(LiveLoudnessMeterTest, PushDoesNotAllocate) {
  if (!alloc_counter::kAvailable) {
    GTEST_SKIP() << "allocation counts need an asan or tsan build";
  }
  Signal sig(kChannels, 4 * kSampleRate, 0.5f);
  EclipsaStudioLoudnessData out;
  LiveLoudnessMeter live(kSampleRate, kChannels, /*layout=*/0, &out);

  const bool probe_counted = alloc_counter::Start();
  for (uint32_t i = 0; i < sig.blocks(); ++i) {
    live.push(sig.block(i, kChannels), kBlock);
    // Pace the pushes at about twice real time (960 frames, 20 ms of
    // audio, per 10 ms) so the meter thread drains concurrently and the
    // ring never fills.
    if (i % 2 == 1) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  const uint64_t allocations = alloc_counter::Stop();

  live.drain();
  EXPECT_TRUE(probe_counted);
  EXPECT_EQ(allocations, 0u);
  EXPECT_EQ(live.dropped_frames(), 0u);
  EXPECT_GT(out.lufs_integrated, -20.0f);
}

}  // namespace
