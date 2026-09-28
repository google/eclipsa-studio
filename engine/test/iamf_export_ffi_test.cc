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

// FFI-level contract of the push-export builder sequence in engine.cc:
// eclipsa_studio_iamf_push_export_begin is the cancel reset boundary (a cancel
// raised before begin is stale and dropped; one raised after begin
// aborts the run even when it lands before run()), and begin rejects
// concurrent entry with -4 instead of clearing the in-flight run's
// cancel. The IamfExporter class-level halves of these contracts are
// pinned in iamf_push_export_test.cc; here the point is the extern "C"
// boundary the Dart dialog is written against.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>

#include "engine.h"
#include "gtest/gtest.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
// A multiple of the 1024-sample coded frame, like the dialog guarantees.
constexpr int kSourceFrames = 1024 * 12;

std::string FindFixture(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
      std::string("engine/test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

std::string ReadFileOrEmpty(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return {};
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

class IamfExportFfiTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = test_wav::temp_dir();
    config_ = ReadFileOrEmpty(FindFixture("golden/multi_mix.textproto"));
    ASSERT_FALSE(config_.empty()) << "golden fixture missing";
    ASSERT_TRUE(test_wav::write_sine_frames(dir_ + "/bed.wav", 2, kSampleRate,
                                            16, 440.0f, kSourceFrames, 0.25f));
    ASSERT_TRUE(test_wav::write_sine_frames(dir_ + "/vocal.wav", 2, kSampleRate,
                                            16, 2000.0f, kSourceFrames, 0.25f));
  }

  // begin + both elements of the golden config, padded to `frames`.
  int32_t BeginWithElements(const std::string& out_path, uint64_t frames) {
    int32_t rc = eclipsa_studio_iamf_push_export_begin(config_.c_str(),
                                                       out_path.c_str());
    if (rc != 0) return rc;
    const std::string bed = dir_ + "/bed.wav";
    const std::string vocal = dir_ + "/vocal.wav";
    rc = eclipsa_studio_iamf_push_export_add_element(
        "bed.wav", bed.c_str(), 0.0f, nullptr, 0, frames, kSampleRate);
    if (rc != 0) return rc;
    return eclipsa_studio_iamf_push_export_add_element(
        "vocal.wav", vocal.c_str(), 0.0f, nullptr, 0, frames, kSampleRate);
  }

  std::string dir_;
  std::string config_;
};

TEST_F(IamfExportFfiTest, BeginIsTheCancelResetBoundary) {
  // Side 1: a cancel raised before begin (e.g. during the app's measure
  // phase) is stale — begin drops it and the run completes.
  const std::string out = dir_ + "/ffi_cancel_boundary.iamf";
  eclipsa_studio_iamf_export_cancel();
  ASSERT_EQ(BeginWithElements(out, kSourceFrames), 0);
  EXPECT_EQ(eclipsa_studio_iamf_push_export_run(), 0);
  EXPECT_FALSE(ReadFileOrEmpty(out).empty());
  std::remove(out.c_str());

  // Side 2: a cancel raised after begin but before run (the dialog's
  // config-staging / isolate-spawn window) stays armed and aborts the
  // run with -99, removing the output.
  ASSERT_EQ(BeginWithElements(out, kSourceFrames), 0);
  eclipsa_studio_iamf_export_cancel();
  EXPECT_EQ(eclipsa_studio_iamf_push_export_run(), -99);
  EXPECT_TRUE(ReadFileOrEmpty(out).empty())
      << "output survived a begin-window cancel";
}

TEST_F(IamfExportFfiTest, ElementClipStatsRoundTripAndResetOnBegin) {
  // ES-470: begin → add (hot element) → run, then pull per-index overload
  // stats — the exact sequence the encode isolate uses. A fresh begin
  // is the validity boundary: stats read -1 until the new run returns.
  const std::string out = dir_ + "/ffi_clip_stats.iamf";
  ASSERT_EQ(eclipsa_studio_iamf_push_export_begin(config_.c_str(), out.c_str()),
            0);
  const std::string bed = dir_ + "/bed.wav";
  const std::string vocal = dir_ + "/vocal.wav";
  ASSERT_EQ(eclipsa_studio_iamf_push_export_add_element(
                "bed.wav", bed.c_str(),
                /*gain_db=*/15.0f, nullptr, 0, kSourceFrames, kSampleRate),
            0);
  ASSERT_EQ(eclipsa_studio_iamf_push_export_add_element(
                "vocal.wav", vocal.c_str(), 0.0f, nullptr, 0, kSourceFrames,
                kSampleRate),
            0);

  // Begin cleared any previous run's stats: nothing readable pre-run.
  EXPECT_EQ(
      eclipsa_studio_iamf_push_export_element_clip_stats(0, nullptr, nullptr),
      -1);

  ASSERT_EQ(eclipsa_studio_iamf_push_export_run(), 0);

  uint64_t clipped = 0;
  float peak = 0.0f;
  EXPECT_EQ(
      eclipsa_studio_iamf_push_export_element_clip_stats(0, &clipped, &peak),
      0);
  EXPECT_GT(clipped, 0u);
  EXPECT_GT(peak, 1.2f);
  EXPECT_EQ(
      eclipsa_studio_iamf_push_export_element_clip_stats(1, &clipped, &peak),
      0);
  EXPECT_EQ(clipped, 0u);
  EXPECT_EQ(
      eclipsa_studio_iamf_push_export_element_clip_stats(5, nullptr, nullptr),
      -1);
  std::remove(out.c_str());

  // A fresh begin invalidates the previous run's stats; complete the
  // new run so no half-built request leaks into the next test.
  ASSERT_EQ(BeginWithElements(out, kSourceFrames), 0);
  EXPECT_EQ(
      eclipsa_studio_iamf_push_export_element_clip_stats(0, nullptr, nullptr),
      -1);
  EXPECT_EQ(eclipsa_studio_iamf_push_export_run(), 0);
  std::remove(out.c_str());
}

TEST_F(IamfExportFfiTest, BeginDuringRunReturnsBusyAndKeepsCancelArmed) {
  // A begin issued while a run is in flight must be rejected with -4 —
  // if it went through, its ResetForNewRequest() would drop a cancel
  // the user already raised against the running encode. The program is
  // sized (3000 units) so the side thread fires while the unit loop
  // runs; it then cancels, which must still abort the run.
  constexpr int kLongFrames = 1024 * 3000;
  ASSERT_TRUE(
      test_wav::write_silence(dir_ + "/bed.wav", 2, kSampleRate, 16,
                              static_cast<float>(kLongFrames) / kSampleRate));
  ASSERT_TRUE(
      test_wav::write_silence(dir_ + "/vocal.wav", 2, kSampleRate, 16,
                              static_cast<float>(kLongFrames) / kSampleRate));

  const std::string out = dir_ + "/ffi_busy_begin.iamf";
  ASSERT_EQ(BeginWithElements(out, kLongFrames), 0);

  std::atomic<int32_t> begin_rc{123};
  std::atomic<bool> done{false};
  std::thread side([&]() {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!done.load(std::memory_order_relaxed) &&
           eclipsa_studio_iamf_export_progress() < 0.06f &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    begin_rc.store(
        eclipsa_studio_iamf_push_export_begin(config_.c_str(), out.c_str()),
        std::memory_order_relaxed);
    eclipsa_studio_iamf_export_cancel();
  });
  const int32_t run_rc = eclipsa_studio_iamf_push_export_run();
  done.store(true, std::memory_order_relaxed);
  side.join();

  EXPECT_EQ(begin_rc.load(std::memory_order_relaxed), -4);
  EXPECT_EQ(run_rc, -99);
  EXPECT_TRUE(ReadFileOrEmpty(out).empty())
      << "partial output survived the cancel";
}

TEST_F(IamfExportFfiTest, BuilderCallsFromTwoThreadsAreDataRaceFree) {
  // ES-504: the builder entry points share the pending-request state;
  // they are serialized by a mutex, so a contract-violating second
  // thread garbles a request at worst — never a data race on its
  // strings/vector. This test is the tsan probe for that: two threads
  // hammer begin/add concurrently (return codes deliberately
  // unasserted — any interleaving of 0 and -1 is legal), then a clean
  // single-thread sequence must still encode.
  const std::string bed = dir_ + "/bed.wav";
  const std::string race_out = dir_ + "/ffi_race.iamf";
  std::atomic<bool> go{false};
  auto hammer = [&]() {
    while (!go.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
    for (int i = 0; i < 200; ++i) {
      (void)eclipsa_studio_iamf_push_export_begin(config_.c_str(),
                                                  race_out.c_str());
      (void)eclipsa_studio_iamf_push_export_add_element(
          "bed.wav", bed.c_str(), 0.0f, nullptr, 0, kSourceFrames, kSampleRate);
    }
  };
  std::thread a(hammer);
  std::thread b(hammer);
  go.store(true, std::memory_order_release);
  a.join();
  b.join();

  // Whatever garbled request the hammering left behind must not poison
  // a fresh begin→add→run sequence.
  const std::string out = dir_ + "/ffi_after_race.iamf";
  ASSERT_EQ(BeginWithElements(out, kSourceFrames), 0);
  EXPECT_EQ(eclipsa_studio_iamf_push_export_run(), 0);
  EXPECT_FALSE(ReadFileOrEmpty(out).empty());
  std::remove(out.c_str());
}

}  // namespace
