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

#include "dropout_detector.h"

#include <cstdint>

#include "gtest/gtest.h"

namespace {

// Default stream shape: 96 kHz / 512 frames — the configuration from
// the field log that exposed the false-positive storm (issue ES-32).
constexpr uint32_t kRate = 96000;
constexpr uint32_t kFrames = 512;
constexpr double kPeriodNs = 1e9 * kFrames / kRate;  // ≈ 5.333 ms

// Feeds synthetic callback-entry timelines to a DropoutDetector and
// accumulates counted dropouts. Times are doubles in ns for easy math;
// t = 0 maps to an arbitrary nonzero epoch.
class Sim {
 public:
  DropoutDetector::Result feed_at(double t_ns, uint32_t frames = kFrames,
                                  uint32_t rate = kRate) {
    // Sum in double before casting: t_ns can be slightly negative
    // (entry jitter around t = 0), and casting a negative double to
    // uint64_t is UB. kEpochNs + t_ns is always positive and well
    // within double's exact-integer range.
    const auto r =
        det_.on_callback(static_cast<uint64_t>(kEpochNs + t_ns), frames, rate);
    total_ += r.new_dropouts;
    return r;
  }

  void reset() { det_.reset(); }
  uint64_t total() const { return total_; }

 private:
  static constexpr uint64_t kEpochNs = 1'000'000'000;
  DropoutDetector det_;
  uint64_t total_ = 0;
};

// ── Healthy delivery patterns must stay silent ─────────────────────────────

TEST(DropoutDetectorTest, SteadyCadenceIsClean) {
  Sim sim;
  for (int k = 0; k < 12000; ++k) {  // ~64 s
    sim.feed_at(k * kPeriodNs);
  }
  EXPECT_EQ(sim.total(), 0u);
}

// The issue ES-32 field case: device internal period is 2× the requested
// one, so callbacks arrive in back-to-back pairs — a ~0 ms gap followed
// by a ~2-period gap — at exactly nominal overall throughput. The old
// gap-based detector flagged every second callback (~94/s of noise).
TEST(DropoutDetectorTest, BurstPairsAtPerfectThroughputAreClean) {
  Sim sim;
  constexpr double kIntraBurstNs = 50e3;        // 50 µs between pair members
  for (int cycle = 0; cycle < 6000; ++cycle) {  // ~64 s
    sim.feed_at(cycle * 2 * kPeriodNs);
    sim.feed_at(cycle * 2 * kPeriodNs + kIntraBurstNs);
  }
  EXPECT_EQ(sim.total(), 0u);
}

// Worse pacing than ever observed: device period 8× the requested one,
// callbacks delivered in clusters of eight.
TEST(DropoutDetectorTest, BurstClustersOfEightAreClean) {
  Sim sim;
  for (int cycle = 0; cycle < 1500; ++cycle) {  // ~64 s
    for (int j = 0; j < 8; ++j) {
      sim.feed_at(cycle * 8 * kPeriodNs + j * 60e3);
    }
  }
  EXPECT_EQ(sim.total(), 0u);
}

TEST(DropoutDetectorTest, EntryJitterIsClean) {
  Sim sim;
  for (int k = 0; k < 12000; ++k) {
    // Deterministic ±0.4 ms zero-mean jitter pattern.
    const double jitter_ns = ((k % 5) - 2) * 0.2e6;
    sim.feed_at(k * kPeriodNs + jitter_ns);
  }
  EXPECT_EQ(sim.total(), 0u);
}

// Clock skew between the monotonic clock and the device clock must not
// accumulate into false positives. 100 ppm is generous — real crystal
// drift is well under that.
TEST(DropoutDetectorTest, ClockDriftIsClean) {
  Sim sim;
  for (int k = 0; k < 24000; ++k) {  // ~128 s
    sim.feed_at(k * kPeriodNs * 1.0001);
  }
  EXPECT_EQ(sim.total(), 0u);
}

// Variable callback sizes (and an implicit period change) re-derive the
// buffer unit per evaluation without re-anchoring.
TEST(DropoutDetectorTest, VariableFrameCountsAreClean) {
  Sim sim;
  double t = 0.0;
  for (int k = 0; k < 8000; ++k) {
    const uint32_t frames = (k % 2 == 0) ? 512 : 256;
    sim.feed_at(t, frames);
    t += 1e9 * frames / kRate;
  }
  EXPECT_EQ(sim.total(), 0u);
}

// A stall the device absorbs — delivery pauses, then a burst of extra
// callbacks restores the cumulative count — never starved the output,
// so it is not a dropout.
TEST(DropoutDetectorTest, StallWithFullCatchUpIsClean) {
  Sim sim;
  int k = 0;
  for (; k < 2000; ++k) {
    sim.feed_at(k * kPeriodNs);
  }
  // 50 ms of silence: ~9 slots elapse undelivered…
  const double resume_ns = k * kPeriodNs + 50e6;
  // …then 10 rapid catch-up callbacks restore the count…
  for (int j = 0; j < 10; ++j) {
    sim.feed_at(resume_ns + j * 20e3);
    ++k;
  }
  // …and steady delivery resumes on the original schedule.
  for (int j = 1; j < 4000; ++j) {
    sim.feed_at(resume_ns + j * kPeriodNs);
  }
  EXPECT_EQ(sim.total(), 0u);
}

// ── Genuine loss must be counted ───────────────────────────────────────────

TEST(DropoutDetectorTest, SingleSkippedCallbackCountsOne) {
  Sim sim;
  float behind_ms = 0.0f;
  for (int k = 0; k < 4000; ++k) {
    if (k == 2000) continue;  // one slot's buffer is never delivered
    const auto r = sim.feed_at(k * kPeriodNs);
    if (r.new_dropouts > 0) behind_ms = r.behind_ms;
  }
  EXPECT_EQ(sim.total(), 1u);
  // The reported deficit is the one missing buffer: ≈ 5.33 ms at 96 kHz.
  EXPECT_GT(behind_ms, 3.0f);
  EXPECT_LT(behind_ms, 8.0f);
}

// A long stall the device does not catch up from (the 209 ms gap from
// the issue ES-32 log): every elapsed-but-undelivered slot is real loss.
TEST(DropoutDetectorTest, StallWithoutCatchUpCountsElapsedBuffers) {
  Sim sim;
  int k = 0;
  for (; k < 2000; ++k) {
    sim.feed_at(k * kPeriodNs);
  }
  const double stall_ns = 209e6;
  for (int j = 0; j < 4000; ++j) {
    sim.feed_at(k * kPeriodNs + stall_ns + j * kPeriodNs);
  }
  // 209 ms ≈ 39.2 slots elapsed, one of which got its (late) delivery.
  EXPECT_GE(sim.total(), 36u);
  EXPECT_LE(sim.total(), 40u);
}

// Sustained slow starvation — e.g. a clock-slip rate mismatch where
// delivery runs 1% behind the device — must be counted at roughly the
// true loss rate, not bled away as drift.
TEST(DropoutDetectorTest, GradualStarvationIsCounted) {
  Sim sim;
  for (int k = 0; k < 6000; ++k) {  // ~32 s of wall time
    sim.feed_at(k * kPeriodNs * 1.01);
  }
  // True loss: 6000 buffers delivered over 6000 × 1.01 periods → ~60
  // buffers behind. Allow slack for window quantization.
  EXPECT_GE(sim.total(), 45u);
  EXPECT_LE(sim.total(), 65u);
}

// ── Resets and reconfiguration ─────────────────────────────────────────────

TEST(DropoutDetectorTest, ResetForgetsThePauseGap) {
  Sim sim;
  int k = 0;
  for (; k < 2000; ++k) {
    sim.feed_at(k * kPeriodNs);
  }
  sim.reset();  // transport paused; callbacks idle for 10 s
  const double resume_ns = k * kPeriodNs + 10e9;
  for (int j = 0; j < 2000; ++j) {
    sim.feed_at(resume_ns + j * kPeriodNs);
  }
  EXPECT_EQ(sim.total(), 0u);
}

TEST(DropoutDetectorTest, SampleRateChangeReanchors) {
  Sim sim;
  int k = 0;
  for (; k < 2000; ++k) {
    sim.feed_at(k * kPeriodNs);
  }
  // Device reconfigured to 48 kHz: the period doubles, and the first
  // callback arrives after a 100 ms reconfiguration hiccup.
  const double t0 = k * kPeriodNs + 100e6;
  const double period48_ns = 1e9 * kFrames / 48000.0;
  for (int j = 0; j < 2000; ++j) {
    sim.feed_at(t0 + j * period48_ns, kFrames, 48000);
  }
  EXPECT_EQ(sim.total(), 0u);
}

}  // namespace
