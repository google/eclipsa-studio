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

// Unit tests for PcmRing, the SPSC decoded-PCM ring between the IAMF
// I/O (decode) thread and the audio thread. Focused on the seek-discard
// machinery: the published floor's effect on buffered/free accounting
// (ES-427, ES-238), the guard against the producer reclaiming a region a
// concurrent read is copying, and the pump's gate→write no-truncation
// contract. Synthetic rings only — no fixtures, no session.

#include "iamf/pcm_ring.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>

#include "graph/audio_buffer.h"
#include "gtest/gtest.h"

namespace {

// Planar destination backed by a local vector.
struct PlanarOut {
  PlanarOut(uint32_t channels, uint32_t capacity)
      : storage(static_cast<size_t>(channels) * capacity, 0.0f) {
    buf.data = storage.data();
    buf.channels = channels;
    buf.capacity_frames = capacity;
  }
  std::vector<float> storage;
  AudioBuffer buf;
};

// Interleaved source where frame f, channel c carries the value
// base + f (channel-independent so reads are easy to verify).
std::vector<float> MakeFrames(uint32_t channels, uint32_t frames, float base) {
  std::vector<float> v(static_cast<size_t>(channels) * frames);
  for (uint32_t f = 0; f < frames; ++f) {
    for (uint32_t c = 0; c < channels; ++c) {
      v[static_cast<size_t>(f) * channels + c] = base + f;
    }
  }
  return v;
}

TEST(PcmRingTest, WriteReadRoundTrip) {
  PcmRing ring;
  ring.configure(2, 64);
  const auto src = MakeFrames(2, 10, 100.0f);
  ASSERT_EQ(ring.write_interleaved(src.data(), 10), 10u);
  EXPECT_EQ(ring.buffered_frames(), 10u);

  PlanarOut out(2, 64);
  ASSERT_EQ(ring.read_planar(out.buf, 10), 10u);
  EXPECT_EQ(out.buf.frames, 10u);
  for (uint32_t f = 0; f < 10; ++f) {
    EXPECT_FLOAT_EQ(out.buf.channel(0)[f], 100.0f + f);
    EXPECT_FLOAT_EQ(out.buf.channel(1)[f], 100.0f + f);
  }
  EXPECT_EQ(ring.buffered_frames(), 0u);
}

// Regression for the ES-427 flake: a published discard floor must zero
// buffered_frames() immediately. Before the fix it kept reporting the
// condemned pre-seek backlog, so wait-for-buffered barriers returned
// instantly while the post-seek refill had not produced a single
// frame — and the next read returned 0.
TEST(PcmRingTest, DiscardFloorZeroesBufferedFrames) {
  PcmRing ring;
  ring.configure(1, 64);
  const auto src = MakeFrames(1, 48, 0.0f);
  ASSERT_EQ(ring.write_interleaved(src.data(), 48), 48u);

  PlanarOut out(1, 64);
  ASSERT_EQ(ring.read_planar(out.buf, 8), 8u);
  ASSERT_EQ(ring.buffered_frames(), 40u);

  // "Seek": everything currently buffered is stale.
  ring.publish_discard_to(ring.head_pos());
  EXPECT_EQ(ring.buffered_frames(), 0u);
  // The producer may reclaim the whole ring right away (ES-238).
  EXPECT_EQ(ring.free_frames(), ring.capacity());

  // Only fresh post-seek frames count — and reads serve exactly them.
  const auto fresh = MakeFrames(1, 12, 1000.0f);
  ASSERT_EQ(ring.write_interleaved(fresh.data(), 12), 12u);
  EXPECT_EQ(ring.buffered_frames(), 12u);
  ASSERT_EQ(ring.read_planar(out.buf, 64), 12u);
  for (uint32_t f = 0; f < 12; ++f) {
    EXPECT_FLOAT_EQ(out.buf.channel(0)[f], 1000.0f + f);
  }
}

// Regression for ES-238 (moved from iamf_playback_session_test.cc):
// after a seek the producer publishes a discard floor at head_pos();
// free_frames() must reflect that reclaimable space *immediately* so
// the post-seek refill doesn't stall waiting for the consumer —
// otherwise, with a sibling ring still full, the all-rings pump gate
// wedges and this ring starves until a second seek.
TEST(PcmRingTest, FreeFramesHonorsDiscardFloorForImmediateRefill) {
  PcmRing ring;
  ring.configure(/*channels=*/2, /*capacity_frames=*/16);
  const uint32_t cap = ring.capacity();
  ASSERT_EQ(cap, 16u);

  std::vector<float> src(static_cast<size_t>(cap) * 2, 0.25f);
  ASSERT_EQ(ring.write_interleaved(src.data(), cap), cap);
  EXPECT_EQ(ring.free_frames(), 0u);

  PlanarOut out(2, 16);
  ASSERT_EQ(ring.read_planar(out.buf, 4), 4u);
  EXPECT_EQ(ring.free_frames(), 4u);
  EXPECT_EQ(ring.buffered_frames(), cap - 4u);

  // Seek: the consumer hasn't read yet (tail_ is stale at 4), but
  // everything below head is condemned — reclaimable now.
  ring.publish_discard_to(ring.head_pos());
  EXPECT_EQ(ring.free_frames(), cap)
      << "post-seek free space must ignore the stale tail";

  EXPECT_EQ(ring.write_interleaved(src.data(), cap), cap);
  EXPECT_EQ(ring.read_planar(out.buf, cap), cap);
}

TEST(PcmRingTest, DiscardBeyondHeadReportsEmptyUntilRefill) {
  PcmRing ring;
  ring.configure(1, 64);
  const auto src = MakeFrames(1, 8, 0.0f);
  ASSERT_EQ(ring.write_interleaved(src.data(), 8), 8u);
  ring.publish_discard_to(ring.head_pos() + 16);
  EXPECT_EQ(ring.buffered_frames(), 0u);

  PlanarOut out(1, 64);
  EXPECT_EQ(ring.read_planar(out.buf, 8), 0u);
}

TEST(PcmRingTest, ReadClampsToDestinationCapacity) {
  PcmRing ring;
  ring.configure(1, 64);
  const auto src = MakeFrames(1, 32, 0.0f);
  ASSERT_EQ(ring.write_interleaved(src.data(), 32), 32u);

  PlanarOut out(1, 16);
  EXPECT_EQ(ring.read_planar(out.buf, 32), 16u);
  EXPECT_EQ(ring.buffered_frames(), 16u);
}

// Producer/consumer stress across seek discards on a small ring that
// wraps constantly. Frame at stream position p always carries the
// value float(p), so every read must return a consecutive run — a
// producer overwriting slots mid-read (the reclaim race) surfaces as
// a broken run. This value check is the load-bearing guard: TSan (v3)
// does NOT flag the pre-fix race in this shape, and catching the old
// code is probabilistic (more likely at -O0 than -O2) — so treat a
// single failure as real, never as flaky.
//
// The producer also emulates io_loop's pump contract: a gated write
// may fall short transiently while a read's entry is mid-flight (the
// in_read_ guard raises before the tail settles on the floor — TSan
// timing makes this reproducible), but retrying the remainder must
// always complete promptly. Only an unresolved shortfall counts as a
// failure — mirroring io_loop, which retries with a deadline and
// halts the pump only if the space never reappears. Note the gate
// and write are adjacent here, while io_loop decodes a TU between
// them — so any shortfall rate observed here is a lower bound on
// production's, not an estimate of it.
//
// All failures are recorded and asserted AFTER producer.join() — a
// fatal assert inside the loop would skip the join, hit
// std::terminate in ~std::thread, and lose the failure message to
// bazel's buffered stdout: exactly the evidence this test exists to
// produce.
TEST(PcmRingTest, ConcurrentSeekDiscardStress) {
  constexpr uint32_t kTu = 16;        // one "temporal unit"
  constexpr uint32_t kHeadroom = 24;  // pump gate, > kTu
  PcmRing ring;
  ring.configure(1, 64);
  std::atomic<bool> stop{false};
  std::atomic<uint32_t> truncated{0};

  std::thread producer([&] {
    uint64_t pos = 0;
    std::vector<float> chunk(kTu);
    uint64_t iter = 0;
    while (!stop.load(std::memory_order_relaxed)) {
      // Periodic "seek": condemn everything buffered so far.
      if (++iter % 37 == 0) ring.publish_discard_to(ring.head_pos());
      // Pump gate: snapshot free_frames() once — it can change
      // between calls (grow as the consumer drains; shrink while a
      // read is in flight) — and only write when a full TU fits.
      const uint32_t free = ring.free_frames();
      if (free < kHeadroom) continue;
      for (uint32_t f = 0; f < kTu; ++f) {
        chunk[f] = static_cast<float>(pos + f);
      }
      uint32_t written = ring.write_interleaved(chunk.data(), kTu);
      // Transient shortfall: retry the remainder like io_loop does.
      // Generous iteration bound stands in for io_loop's deadline.
      for (int spin = 0; written < kTu && spin < 1000000; ++spin) {
        written +=
            ring.write_interleaved(chunk.data() + written, kTu - written);
      }
      if (written != kTu) {
        truncated.fetch_add(1, std::memory_order_relaxed);
      }
      pos += written;  // keep the value sequence consistent
    }
  });

  PlanarOut out(1, 32);
  double last_start = -1.0;
  double backwards_from = 0.0, backwards_to = 0.0;
  bool torn = false, backwards = false;
  uint32_t torn_f = 0, torn_got = 0;
  for (uint32_t i = 0; i < 200000 && !torn && !backwards; ++i) {
    const uint32_t got = ring.read_planar(out.buf, 32);
    if (got == 0) continue;
    const float start = out.buf.channel(0)[0];
    // Reads never go backwards (discards only jump forward).
    if (static_cast<double>(start) <= last_start) {
      backwards = true;
      backwards_from = last_start;
      backwards_to = start;
    }
    last_start = start;
    for (uint32_t f = 1; f < got; ++f) {
      // Exact compare: values are exactly-representable integers
      // (see the < 2^24 guard below); FLOAT_EQ's 4-ULP tolerance
      // would be ±1.0 or more at these magnitudes.
      if (out.buf.channel(0)[f] != start + f) {
        torn = true;
        torn_f = f;
        torn_got = got;
        break;
      }
    }
  }
  stop.store(true, std::memory_order_relaxed);
  producer.join();

  EXPECT_FALSE(torn) << "torn read at frame " << torn_f << " of " << torn_got;
  EXPECT_FALSE(backwards) << "read went backwards: " << backwards_from << " -> "
                          << backwards_to;
  EXPECT_EQ(truncated.load(), 0u)
      << "gated write truncated — io_loop would halt the pump";
  // float carries stream positions exactly only below 2^24 — fail
  // loudly if a future iteration bump ever erodes that headroom.
  EXPECT_LT(last_start, static_cast<double>(1u << 24));
}

}  // namespace
