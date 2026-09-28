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

// Concurrency contract for OfflineMixRenderer (offline-vs-offline
// exclusion; each `oar_t` is used by one thread at a time): the header
// promises that instances are standalone and may run concurrently on
// different threads, while the app has historically serialized measure
// renders on the belief that the binaural renderer keeps process-global
// state (ES-44). This test is the load-bearing evidence either way: N
// instances render and measure in parallel, so the asan/ubsan/tsan CI
// sweeps turn any cross-instance sharing into a hard failure, and
// result-equality against a sequential reference catches logical
// cross-talk that the sanitizers can't see. Binaural (OBR, the suspect
// path) is exercised alongside loudspeaker layouts — the exact mix of
// jobs a parallel export measure pass would dispatch.
//
// No gtest assertions run on the worker threads (gtest failure
// reporting is not thread-safe); workers only fill their result slot
// and everything is checked after join(). A failed render collapses to
// the default -120 dBFS result, which the reference checks reject.

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#include "gtest/gtest.h"
#include "mix_renderer/offline_mix_renderer.h"
#include "test_wav_helper.h"

namespace eclipsa_studio {
namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBufferSize = 1024;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t stereo
constexpr uint32_t k714Layout = 8;     // oar_layout_t 7.1.4
constexpr uint32_t kBinauralLayout = 0xFF;
constexpr int kSeconds = 2;         // short program: N renders run under tsan
constexpr float kAmplitude = 0.1f;  // sine peak = -20 dBFS

// Loudness renders are deterministic per instance, so parallel results
// must match the sequential reference almost exactly; the small slack
// leaves room for FMA / instruction-ordering differences between
// sanitizer builds, not for real divergence.
constexpr float kTolerance = 0.01f;

struct Sources {
  std::string bed_wav;
  std::string obj_wav;
};

// Writes the shared source WAVs once: a stereo bed and a mono object
// program. Every renderer instance opens its own readers, so sharing
// the files across threads is read-only.
Sources WriteSources() {
  Sources s;
  s.bed_wav = test_wav::temp_dir() + "/concurrency_bed.wav";
  s.obj_wav = test_wav::temp_dir() + "/concurrency_obj.wav";
  EXPECT_TRUE(test_wav::write_sine_frames(s.bed_wav, 2, kSampleRate, 16, 997.0f,
                                          kSeconds * kSampleRate, kAmplitude));
  EXPECT_TRUE(test_wav::write_sine_frames(s.obj_wav, 1, kSampleRate, 16, 499.0f,
                                          kSeconds * kSampleRate, kAmplitude));
  return s;
}

// Builds a fresh renderer (stereo bed + one positioned object — covers
// the channel-bed path and the object path, which binaural routes
// through OBR) and runs the full measure. Called from worker threads:
// no gtest assertions; errors surface as the default -120 result.
LoudnessResult MeasureOnce(const Sources& src, uint32_t layout) {
  OfflineMixRenderer renderer;
  if (!renderer.Init(kSampleRate, kBufferSize, layout)) return {};

  MixElementConfig bed;
  bed.element_id = 1;
  bed.stream.input_wav_path = src.bed_wav;
  bed.element_type = 0;  // channel bed
  bed.element_sub_type = kStereoLayout;
  bed.channels = 2;
  if (!renderer.AddElement(bed)) return {};

  MixElementConfig obj;
  obj.element_id = 2;
  obj.stream.input_wav_path = src.obj_wav;
  obj.element_type = 2;  // object
  obj.element_sub_type = 1;
  obj.channels = 1;
  if (!renderer.AddElement(obj)) return {};
  const float az = 30.0f, el = 10.0f, dist = 1.0f;
  if (!renderer.SetObjectPosition(2, 1, &az, &el, &dist)) return {};

  return renderer.RenderAndMeasure().value_or(LoudnessResult{});
}

// Runs one MeasureOnce per requested layout concurrently, all threads
// released together by an atomic gate to maximize overlap.
std::vector<LoudnessResult> MeasureConcurrently(
    const Sources& src, const std::vector<uint32_t>& layouts) {
  std::atomic<bool> go{false};
  std::vector<LoudnessResult> out(layouts.size());
  std::vector<std::thread> threads;
  threads.reserve(layouts.size());
  for (size_t i = 0; i < layouts.size(); ++i) {
    threads.emplace_back([&, i] {
      while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
      out[i] = MeasureOnce(src, layouts[i]);
    });
  }
  go.store(true, std::memory_order_release);
  for (auto& t : threads) t.join();
  return out;
}

void ExpectMatches(const LoudnessResult& got, const LoudnessResult& ref) {
  EXPECT_NEAR(got.integrated_lufs, ref.integrated_lufs, kTolerance);
  EXPECT_NEAR(got.true_peak_dbtp, ref.true_peak_dbtp, kTolerance);
  EXPECT_NEAR(got.digital_peak_dbfs, ref.digital_peak_dbfs, kTolerance);
}

// Four binaural renders in parallel — all through OBR — must each match
// a sequential binaural reference.
TEST(OfflineMixConcurrencyTest, ParallelBinauralMatchesSequential) {
  const Sources src = WriteSources();
  const LoudnessResult ref = MeasureOnce(src, kBinauralLayout);
  ASSERT_GT(ref.integrated_lufs, -60.0f);  // reference actually measured

  constexpr int kThreads = 4;
  const std::vector<uint32_t> layouts(kThreads, kBinauralLayout);
  const std::vector<LoudnessResult> results = MeasureConcurrently(src, layouts);
  for (const LoudnessResult& r : results) ExpectMatches(r, ref);
}

// One binaural, one 7.1.4, one stereo render in parallel — the shape a
// parallel export measure pass dispatches — each matching its own
// sequential reference.
TEST(OfflineMixConcurrencyTest, MixedLayoutsInParallel) {
  const Sources src = WriteSources();
  const std::vector<uint32_t> layouts = {kBinauralLayout, k714Layout,
                                         kStereoLayout};
  std::vector<LoudnessResult> refs;
  for (const uint32_t layout : layouts) {
    refs.push_back(MeasureOnce(src, layout));
    ASSERT_GT(refs.back().integrated_lufs, -60.0f);
  }

  const std::vector<LoudnessResult> results = MeasureConcurrently(src, layouts);
  for (size_t i = 0; i < layouts.size(); ++i) {
    ExpectMatches(results[i], refs[i]);
  }
}

}  // namespace
}  // namespace eclipsa_studio
