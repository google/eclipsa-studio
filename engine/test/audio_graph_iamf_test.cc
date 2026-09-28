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

// Integration test for AudioGraph's IAMF path — opens a two-AE
// fixture, processes a block, and verifies the graph produces output
// end to end.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "graph/audio_graph.h"
#include "gtest/gtest.h"
#include "iamf/iamf_playback_session.h"
#include "meters/meter_state.h"
#include "renderer/oar_capability.h"
#include "renderer/oar_renderer.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kMaxFrames = 512;
constexpr uint32_t kOutChannels = 2;

std::string FindFixture(const char* name) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir == nullptr) srcdir = ".";
  const std::string candidates[] = {
      std::string(srcdir) + "/_main/test/fixtures/" + name,
      std::string(srcdir) + "/_main/engine/test/fixtures/" + name,
      std::string(srcdir) + "/eclipsa_studio_engine/test/fixtures/" + name,
      std::string("test/fixtures/") + name,
      std::string("engine/test/fixtures/") + name,
  };
  for (const auto& c : candidates) {
    std::ifstream probe(c, std::ios::binary);
    if (probe) return c;
  }
  return {};
}

class AudioGraphIamfTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(graph_.init(kSampleRate, kMaxFrames, kOutChannels));
    fixture_ = FindFixture("tones_100ms_3OA_stereo_opus.iamf");
    ASSERT_FALSE(fixture_.empty()) << "fixture missing";
  }

  AudioGraph graph_;
  std::string fixture_;
};

TEST_F(AudioGraphIamfTest, OpenIamfClaimsSlotsPerAe) {
  const int32_t claimed = graph_.open_iamf(fixture_.c_str());
  ASSERT_GT(claimed, 0) << graph_.last_iamf_error();
  EXPECT_EQ(claimed, 2);  // fixture has 2 AEs
  EXPECT_TRUE(graph_.has_iamf_session());

  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_NE(state, nullptr);
  EXPECT_EQ(state->element_count, 2u);
}

TEST_F(AudioGraphIamfTest, OpenNonExistentFails) {
  const int32_t claimed = graph_.open_iamf("/no/such/file.iamf");
  EXPECT_LT(claimed, 0);
  EXPECT_FALSE(graph_.has_iamf_session());
  EXPECT_FALSE(graph_.last_iamf_error().empty());
}

TEST_F(AudioGraphIamfTest, OpenMalformedFails) {
  // Make a tiny "file" with junk bytes on disk.
  const std::string path =
      std::string(std::getenv("TEST_TMPDIR") ? std::getenv("TEST_TMPDIR")
                                             : "/tmp") +
      "/bad.iamf";
  {
    std::ofstream out(path, std::ios::binary);
    out.write("JUNK", 4);
  }
  const int32_t claimed = graph_.open_iamf(path.c_str());
  EXPECT_LT(claimed, 0);
  EXPECT_FALSE(graph_.has_iamf_session());
}

TEST_F(AudioGraphIamfTest, PerElementMetersPopulate) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);

  // The session's I/O thread fills the per-AE rings asynchronously;
  // wait until each AE has at least one block before pumping process()
  // so the meters see real signal rather than the empty-ring zeros.
  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_NE(state, nullptr);

  // Pump until some element registers a non-zero peak on some channel,
  // re-waiting for buffered audio between callbacks. A fixed burst of
  // back-to-back callbacks is flaky under ASan (which CI now runs,
  // ES-166): the instrumented decode thread can fall behind the pump, so
  // every block after the first reads an underrun's zeros — and if the
  // fixture's opening block is quiet, no peak ever registers.
  bool any_peak = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!any_peak && std::chrono::steady_clock::now() < deadline) {
    session->wait_for_buffered(0, kMaxFrames, 2000);
    session->wait_for_buffered(1, kMaxFrames, 2000);
    graph_.process(out.data(), kMaxFrames, kOutChannels);
    for (uint32_t i = 0; i < state->element_count && !any_peak; ++i) {
      for (float p : state->elements[i].peak) {
        if (p > 0.0f) {
          any_peak = true;
          break;
        }
      }
    }
  }
  EXPECT_TRUE(any_peak);
}

// The output bus meters both peak and EMA RMS from the same tap.
// OAR renders silence in this harness (no device/transport bring-up),
// so run with OAR bypassed: element audio sums straight into the
// device buffer, which is exactly the metering fallback path. Once
// signal flows both peak and RMS must be non-zero, RMS must not exceed
// the running max peak (an averaging integration cannot overshoot the
// peak of the signal that feeds it), and reset_meters() must clear the
// RMS integration state.
TEST_F(AudioGraphIamfTest, OutputRmsPopulatesAndResets) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  graph_.set_bypass_oar(true);

  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  float rms[kOutChannels] = {};
  float peaks[kOutChannels] = {};
  float max_peak = 0.0f;

  // Pump until output RMS registers, same underrun-tolerant loop as
  // PerElementMetersPopulate (see the ASan note there, ES-166).
  bool any_rms = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!any_rms && std::chrono::steady_clock::now() < deadline) {
    session->wait_for_buffered(0, kMaxFrames, 2000);
    session->wait_for_buffered(1, kMaxFrames, 2000);
    graph_.process(out.data(), kMaxFrames, kOutChannels);
    ASSERT_EQ(graph_.get_output_rms(rms, kOutChannels), kOutChannels);
    ASSERT_EQ(graph_.get_output_peaks(peaks, kOutChannels), kOutChannels);
    for (float p : peaks) max_peak = std::max(max_peak, p);
    for (float r : rms) {
      if (r > 0.0f) any_rms = true;
    }
  }
  EXPECT_TRUE(any_rms);
  EXPECT_LE(std::max(rms[0], rms[1]), max_peak);

  // reset_meters() clears the RMS integration state (the caller keeps
  // the callback quiescent — trivially true here, no audio thread).
  graph_.reset_meters();
  ASSERT_EQ(graph_.get_output_rms(rms, kOutChannels), kOutChannels);
  for (float r : rms) {
    EXPECT_EQ(r, 0.0f);
  }
}

TEST_F(AudioGraphIamfTest, SeekRepositionsSession) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  // Pump once so there's a cursor to move.
  graph_.process(out.data(), kMaxFrames, kOutChannels);

  // Seek within the fixture (it's ~100 ms; 2048 samples is well
  // inside the range).
  graph_.seek(2048);
  graph_.process(out.data(), kMaxFrames, kOutChannels);
  // No crash and no silent-zero is the bar; meters may or may not
  // register an event in one callback depending on where 2048 lands.
  SUCCEED();
}

TEST_F(AudioGraphIamfTest, StagedWavSeekDoesNotLeakIntoFreshSession) {
  // ES-536 review finding: a WAV-staged seek is ENGINE-rate and
  // unclamped; the IAMF staging is FILE-rate and clamped. A staged
  // WAV seek that no callback consumed (paused with no device, or a
  // host driving the graph directly) must not survive open_iamf() —
  // the IAMF branch of post_staged_seek_rt() would hand it to the
  // decoder as a file-rate position, seeking the fresh session to
  // garbage (past EOF here: every ring EOF-marks and plays silence).
  // close_iamf() clears the staging unconditionally, even with no
  // session attached.
  const std::string wav = test_wav::temp_dir() + "/iamf_seek_leak.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 1, kSampleRate, 16, 440.f, 1.f));
  ASSERT_EQ(graph_.add_element(200, wav.c_str()), 0);
  graph_.seek(2 * kSampleRate);  // Staged, never consumed.
  graph_.remove_element(200);

  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  graph_.consume_pending_seek_paused();  // The paused branch's hook.

  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->seeks_requested(), 0u)
      << "a WAV-staged (engine-rate) seek reached the fresh IAMF session";
}

TEST_F(AudioGraphIamfTest, CloseIamfCarriesMeterSlotWithCompactedElement) {
  // ES-531 companion: close_iamf() compacts trailing non-iamf chains
  // toward the front. The moved chain's meter slot — the sticky clip
  // latch in particular — must move with it, and the vacated slots
  // must not keep stale meter values.
  // Pin the AE count: the body below hardcodes the WAV landing in
  // slot 2, so a fixture change must fail loudly here, not down there.
  ASSERT_EQ(graph_.open_iamf(fixture_.c_str()), 2);

  const std::string wav = test_wav::temp_dir() + "/iamf_close_meters.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 1, kSampleRate, 16, 440.f, 1.f));
  ASSERT_EQ(graph_.add_element(100, wav.c_str()), 0);  // Slot 2.
  graph_.set_element_gain(100, 12.0f);                 // The WAV element clips.

  // Pump past the gain ramp; the WAV chain meters regardless of
  // whether the IAMF rings have decoded audio yet.
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  for (int i = 0; i < 30; ++i) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_EQ(static_cast<int>(state->elements[2].clip[0]), 1)
      << "fixture no longer clips";

  graph_.close_iamf();  // The WAV chain compacts from slot 2 to slot 0.

  EXPECT_EQ(state->element_count, 1u);
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 1);
  // Identity check: slot 0 now carries the mono WAV's meter slot, not
  // a leftover from the 3OA (16 ch) / stereo AEs it displaced.
  EXPECT_EQ(state->elements[0].channel_count, 1u);
  // The vacated slots hold no leftovers for the next elements added.
  for (uint32_t slot = 1; slot <= 2; ++slot) {
    EXPECT_EQ(static_cast<int>(state->elements[slot].clip[0]), 0);
    EXPECT_FLOAT_EQ(state->elements[slot].peak[0], 0.0f);
    EXPECT_FLOAT_EQ(state->elements[slot].peak_hold[0], 0.0f);
  }
}

TEST_F(AudioGraphIamfTest, MismatchedRateOpenAttachesResamplerAndPlays) {
  // 48 kHz fixture into a 96 kHz graph — open_iamf must attach a
  // per-chain resampler instead of rejecting, and the decoded signal
  // must survive the resample into the meters.
  // AudioGraph embeds the pre-allocated chain buffers (tens of MB) —
  // heap-allocate; a stack instance overflows the test thread's stack.
  auto graph96 = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph96->init(96000, kMaxFrames, kOutChannels));
  ASSERT_GT(graph96->open_iamf(fixture_.c_str()), 0)
      << graph96->last_iamf_error();

  auto* session = graph96->iamf_session();
  ASSERT_NE(session, nullptr);
  EXPECT_EQ(session->sample_rate(), 48000u);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  // The fixture is 100 ms = 4800 file frames. Through the resampler it
  // spans 9600 engine frames; consumed unresampled it would dry up at
  // 4800. Pump past the unresampled EOF (12 × 512 = 6144), then check
  // fresh meters still see signal — an unresampled chain would be
  // producing zeros by now (mere energy at the start can't tell the
  // two apart; the stream length can).
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  for (int i = 0; i < 12; ++i) {
    graph96->process(out.data(), kMaxFrames, kOutChannels);
  }
  graph96->reset_meters();
  for (int i = 0; i < 2; ++i) {
    graph96->process(out.data(), kMaxFrames, kOutChannels);
  }

  const EclipsaStudioMeterState* state = graph96->meter_state();
  bool any_peak = false;
  for (uint32_t i = 0; i < state->element_count && !any_peak; ++i) {
    for (float p : state->elements[i].peak) {
      if (p > 0.0f) {
        any_peak = true;
        break;
      }
    }
  }
  EXPECT_TRUE(any_peak);
}

TEST_F(AudioGraphIamfTest, MismatchedRateSeekConvertsToFileFrames) {
  // The noise fixture advertises 10344 file frames (the upstream
  // trim-adjusted total — shorter than its "3s" name suggests) at
  // 48 kHz; in a 96 kHz graph its engine-rate timeline is 20688
  // frames. Seek to engine frame 16000 — in range only after
  // conversion to file frame 8000. Unconverted, 16000 > 10344 gets
  // clamped to the EOF by AudioGraph::seek's staging-time clamp (the
  // scan has published the duration by then), and the post-seek
  // refill produces nothing.
  const std::string noise = FindFixture("noise_3s_stereo_opus.iamf");
  ASSERT_FALSE(noise.empty()) << "fixture missing";

  auto graph96 = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph96->init(96000, kMaxFrames, kOutChannels));
  ASSERT_GT(graph96->open_iamf(noise.c_str()), 0) << graph96->last_iamf_error();

  auto* session = graph96->iamf_session();
  ASSERT_NE(session, nullptr);

  // Wait for the upstream lazy temporal-unit scan to publish the
  // file's duration before seeking. A far seek that races the scan is
  // rejected upstream ("sample position beyond end-of-stream") and
  // poisons the rings until a fresh seek — the app can't hit this
  // through the UI because the timeline can only target positions
  // within the already-published duration.
  {
    const auto scan_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (session->refresh_total_frames() == 0 &&
           std::chrono::steady_clock::now() < scan_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    // Upstream-advertised trim-adjusted total for this fixture.
    ASSERT_EQ(session->total_frames(), 10344u);
  }

  // Drain the stream to EOF before seeking so no pre-seek audio is
  // left in the rings — post-seek energy can then only come from a
  // post-seek refill. (Without the drain, stale buffered frames
  // satisfy the energy check no matter what the seek did.)
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  for (int i = 0; i < 60; ++i) {  // 60 × 512 ≫ 20688 engine frames
    graph96->process(out.data(), kMaxFrames, kOutChannels);
  }
  graph96->reset_meters();

  // Seek to engine frame 16000 = file frame 8000 after conversion,
  // leaving 2344 file frames of audio. Unconverted, 16000 clamps to
  // the 10344-frame EOF and the refill produces nothing.
  graph96->seek(16000);

  // Poll-pump until the post-seek refill produces signal; a clamped
  // (unconverted) seek never refills and times out here.
  bool any_peak = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (!any_peak && std::chrono::steady_clock::now() < deadline) {
    graph96->process(out.data(), kMaxFrames, kOutChannels);
    const EclipsaStudioMeterState* state = graph96->meter_state();
    for (uint32_t i = 0; i < state->element_count && !any_peak; ++i) {
      for (float p : state->elements[i].peak) {
        if (p > 0.0f) {
          any_peak = true;
          break;
        }
      }
    }
    if (!any_peak) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }
  EXPECT_TRUE(any_peak) << "session error: '" << session->last_error()
                        << "' graph error: '" << graph96->last_iamf_error()
                        << "'";
}

TEST_F(AudioGraphIamfTest, MismatchedRateRepeatedSeekKeepsBothRingsAlive) {
  // Regression for ES-238: at an engine rate != the file rate (so every
  // chain runs a resampler), a *seek during playback* could starve one
  // AE's ring — the consumer reads got=0 from it on every callback and
  // it never recovers until a second seek — while the sibling AE plays
  // on. Drive the two-AE fixture in a 96 kHz graph, seek repeatedly to
  // mid-stream positions, and assert *both* elements deliver fresh
  // signal within a bounded number of callbacks after each seek. A
  // wedged ring leaves its element's peak stuck at zero.
  auto graph96 = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph96->init(96000, kMaxFrames, kOutChannels));
  ASSERT_GT(graph96->open_iamf(fixture_.c_str()), 0)
      << graph96->last_iamf_error();

  auto* session = graph96->iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_EQ(session->num_audio_elements(), 2u);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  const EclipsaStudioMeterState* state = graph96->meter_state();
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);

  // Helper: true once element `i` has registered a non-zero peak.
  auto element_has_signal = [&](uint32_t i) {
    for (float p : state->elements[i].peak) {
      if (p > 0.0f) return true;
    }
    return false;
  };

  // The fixture is 100 ms = 4800 file frames = 9600 engine frames.
  // Seek to a rotating set of mid-stream *engine* positions, all far
  // enough from the end that a healthy refill yields several callbacks
  // of signal before EOF.
  const uint64_t kEngineSeekTargets[] = {1024, 2048, 512, 3072, 1536};

  for (int iter = 0; iter < 40; ++iter) {
    const uint64_t target = kEngineSeekTargets[iter % 5];
    const uint64_t applied_before = session->seeks_applied();
    graph96->seek(target);
    // Drive the staged seek (ES-473) through the fade-out to the post,
    // then wait for the I/O thread to apply it (discard floors
    // published) BEFORE clearing the meters: the fade-out block still
    // reads PRE-seek audio at ramping gain, which must not satisfy
    // the alive check below — post-seek signal must come from the
    // refill.
    const auto post_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (session->seeks_applied() <= applied_before &&
           std::chrono::steady_clock::now() < post_deadline) {
      graph96->process(out.data(), kMaxFrames, kOutChannels);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_GT(session->seeks_applied(), applied_before) << "iter " << iter;
    graph96->reset_meters();

    // Pump until both elements show signal, letting the I/O thread
    // refill between callbacks. Deadline-based rather than a fixed
    // callback budget: the ES-473 seek de-click intentionally holds the
    // chains muted through fade-out + post + a ~43 ms priming refill
    // before any post-seek signal can appear. The regression this
    // test pins — a WEDGED ring that never recovers — still fails, by
    // exhausting the deadline.
    bool both_alive = false;
    const auto alive_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!both_alive && std::chrono::steady_clock::now() < alive_deadline) {
      graph96->process(out.data(), kMaxFrames, kOutChannels);
      both_alive = element_has_signal(0) && element_has_signal(1);
      if (!both_alive) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
    ASSERT_TRUE(both_alive)
        << "iter " << iter << " seek->" << target
        << ": element 0 signal=" << element_has_signal(0)
        << " element 1 signal=" << element_has_signal(1)
        << " (ring0 buffered=" << session->buffered_frames(0)
        << " ring1 buffered=" << session->buffered_frames(1)
        << " underruns=" << state->ring_underrun_count
        << " last_el=" << state->last_underrun_element << ")";
  }
}

TEST_F(AudioGraphIamfTest, ReconfigureThenRepeatedSeekKeepsBothRingsAlive) {
  // Regression for ES-238, field-timeline variant: the wedge appeared
  // after an *OS rate change* (48 kHz -> 96 kHz, via set_sample_rate
  // which re-creates the per-chain resamplers) followed ~seconds later
  // by a seek. Open matched at 48 kHz, retarget to 96 kHz, then seek
  // repeatedly — both AEs must keep delivering signal.
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0) << graph_.last_iamf_error();
  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  // Play a little at the matched rate, like the clean pre-switch window.
  for (int i = 0; i < 4; ++i) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }

  // OS rate change: retarget the graph, re-seek to the playhead (the
  // engine's reconfigure path does this), then keep playing clean.
  ASSERT_TRUE(graph_.set_sample_rate(96000));
  graph_.seek(2048);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  const EclipsaStudioMeterState* state = graph_.meter_state();
  auto element_has_signal = [&](uint32_t i) {
    for (float p : state->elements[i].peak) {
      if (p > 0.0f) return true;
    }
    return false;
  };

  const uint64_t kEngineSeekTargets[] = {1024, 2048, 512, 3072, 1536};
  for (int iter = 0; iter < 40; ++iter) {
    const uint64_t target = kEngineSeekTargets[iter % 5];
    const uint64_t applied_before = session->seeks_applied();
    graph_.seek(target);
    // Same drive-to-applied dance as the mismatched-rate variant
    // above — see the comment there.
    const auto post_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (session->seeks_applied() <= applied_before &&
           std::chrono::steady_clock::now() < post_deadline) {
      graph_.process(out.data(), kMaxFrames, kOutChannels);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_GT(session->seeks_applied(), applied_before) << "iter " << iter;
    graph_.reset_meters();
    // Deadline-based for the same ES-473 priming-latency reason as
    // MismatchedRateRepeatedSeekKeepsBothRingsAlive above.
    bool both_alive = false;
    const auto alive_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!both_alive && std::chrono::steady_clock::now() < alive_deadline) {
      graph_.process(out.data(), kMaxFrames, kOutChannels);
      both_alive = element_has_signal(0) && element_has_signal(1);
      if (!both_alive) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    }
    ASSERT_TRUE(both_alive)
        << "iter " << iter << " seek->" << target
        << ": element 0 signal=" << element_has_signal(0)
        << " element 1 signal=" << element_has_signal(1)
        << " (ring0 buffered=" << session->buffered_frames(0)
        << " ring1 buffered=" << session->buffered_frames(1)
        << " underruns=" << state->ring_underrun_count
        << " last_el=" << state->last_underrun_element << ")";
  }
}

TEST_F(AudioGraphIamfTest, MismatchedRateDownsamplePlays) {
  // 48 kHz fixture into a 44.1 kHz graph — the DOWNSAMPLING direction
  // (147:160 ratio), which the 96 kHz tests don't cover. Field repro:
  // 48 kHz IAMF on a 44.1 kHz device played silence.
  auto graph441 = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph441->init(44100, kMaxFrames, kOutChannels));
  ASSERT_GT(graph441->open_iamf(fixture_.c_str()), 0)
      << graph441->last_iamf_error();

  auto* session = graph441->iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  // Mirror the FFI layer's OAR registration (eclipsa_studio_playback_open) so
  // the render path actually produces output, like in the app: sub-types
  // come from the capability mapping keyed on the raw coded layout pair,
  // not from layout_info (an OutputLayout value for channel AEs).
  auto register_aes = [](AudioGraph& g) {
    uint32_t ids[8] = {};
    const uint32_t n = g.iamf_element_ids(ids, 8);
    auto* sess = g.iamf_session();
    for (uint32_t i = 0; i < n; ++i) {
      const auto info = sess->ae_info(i);
      const std::optional<int> sub_type =
          OarSubTypeForElement(info.kind, info.loudspeaker_layout_raw,
                               info.expanded_loudspeaker_layout_raw,
                               info.kind == 1 ? info.layout_info : -1);
      ASSERT_TRUE(sub_type.has_value())
          << "AE " << ids[i] << " has no OAR mapping";
      g.oar_renderer()->add_element(ids[i], info.kind, *sub_type,
                                    info.num_channels);
    }
  };
  register_aes(*graph441);

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  float out_peak441 = 0.0f;
  for (int i = 0; i < 8; ++i) {
    graph441->process(out.data(), kMaxFrames, kOutChannels);
    for (float v : out) out_peak441 = std::max(out_peak441, std::fabs(v));
  }

  const EclipsaStudioMeterState* state = graph441->meter_state();
  bool any_peak = false;
  for (uint32_t i = 0; i < state->element_count && !any_peak; ++i) {
    for (float p : state->elements[i].peak) {
      if (p > 0.0f) {
        any_peak = true;
        break;
      }
    }
  }
  EXPECT_TRUE(any_peak);

  // Control: same fixture at the matched 48 kHz rate.
  auto graph48 = std::make_unique<AudioGraph>();
  ASSERT_TRUE(graph48->init(48000, kMaxFrames, kOutChannels));
  ASSERT_GT(graph48->open_iamf(fixture_.c_str()), 0);
  auto* s48 = graph48->iamf_session();
  ASSERT_TRUE(s48->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(s48->wait_for_buffered(1, kMaxFrames, 2000));
  register_aes(*graph48);
  float out_peak48 = 0.0f;
  for (int i = 0; i < 8; ++i) {
    graph48->process(out.data(), kMaxFrames, kOutChannels);
    for (float v : out) out_peak48 = std::max(out_peak48, std::fabs(v));
  }
  EXPECT_GT(out_peak48, 0.0f);   // control
  EXPECT_GT(out_peak441, 0.0f);  // field-repro config
}

TEST_F(AudioGraphIamfTest, SetSampleRateRetargetsIamfChains) {
  // Open matched (48 kHz graph, no resampler), then retarget the graph
  // to 96 kHz — set_sample_rate must create resamplers for the IAMF
  // chains so playback continues at the right pitch and the meters
  // keep seeing signal.
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  ASSERT_TRUE(graph_.set_sample_rate(96000));

  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  // Same stream-length discriminator as the mismatched-open test: the
  // 4800-file-frame fixture spans 9600 engine frames only if
  // set_sample_rate created the 48->96 resamplers.
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  for (int i = 0; i < 12; ++i) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  graph_.reset_meters();
  for (int i = 0; i < 2; ++i) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  const EclipsaStudioMeterState* state = graph_.meter_state();
  bool any_peak = false;
  for (uint32_t i = 0; i < state->element_count && !any_peak; ++i) {
    for (float p : state->elements[i].peak) {
      if (p > 0.0f) {
        any_peak = true;
        break;
      }
    }
  }
  EXPECT_TRUE(any_peak);
}

// Renders the 128-sample binaural LPCM fixture through a fresh graph
// with the given OAR output layout and per-element
// headphones_rendering_mode, returning the first processed block.
// Registration mirrors eclipsa_studio_playback_open (capability mapping) and
// the rendering-config push mirrors the QC active-mix apply (ES-327).
std::vector<float> RenderBinauralBed(const std::string& fixture,
                                     uint32_t oar_layout,
                                     uint32_t headphones_mode) {
  auto graph = std::make_unique<AudioGraph>();
  if (!graph->init(kSampleRate, kMaxFrames, kOutChannels)) return {};
  if (graph->open_iamf(fixture.c_str()) <= 0) return {};
  auto* sess = graph->iamf_session();
  // The fixture holds 128 samples; wait for those, not a full block.
  if (sess == nullptr || !sess->wait_for_buffered(0, 128, 2000)) return {};

  uint32_t ids[8] = {};
  const uint32_t n = graph->iamf_element_ids(ids, 8);
  auto* oar = graph->oar_renderer();
  for (uint32_t i = 0; i < n; ++i) {
    const auto info = sess->ae_info(i);
    const std::optional<int> sub_type =
        OarSubTypeForElement(info.kind, info.loudspeaker_layout_raw,
                             info.expanded_loudspeaker_layout_raw,
                             info.kind == 1 ? info.layout_info : -1);
    if (!sub_type.has_value()) return {};
    if (!oar->add_element(ids[i], info.kind, *sub_type, info.num_channels)) {
      return {};
    }
    if (!oar->set_element_rendering_config(ids[i], headphones_mode,
                                           /*binaural_profile=*/0)) {
      return {};
    }
  }
  if (!oar->commit_rendering_config()) return {};
  if (!oar->set_layout(oar_layout)) return {};

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  graph->process(out.data(), kMaxFrames, kOutChannels);
  return out;
}

TEST_F(AudioGraphIamfTest, BinauralBedMode0PassthroughMatchesStereoTarget) {
  // ES-327 passthrough-identity invariant (see also ES-88): a pre-rendered
  // binaural bed (registered as a stereo element) with
  // headphones_rendering_mode = 0 must take OAR's stereo passthrough
  // on the binaural output target — identical to the stereo target's
  // render. With world-locked (mode 1, OAR's per-element default) OBR
  // spatializes instead, so that render must differ. Together these
  // pin the behaviour the QC rendering-config push relies on: without
  // the push, an already-binaural signal is audibly re-binauralized.
  const std::string fixture = FindFixture("sine_128samp_binaural_pcm.iamf");
  ASSERT_FALSE(fixture.empty()) << "fixture missing";

  constexpr uint32_t kOarLayoutStereo = 2;
  constexpr uint32_t kOarLayoutBinaural = 0xFF;

  const auto stereo = RenderBinauralBed(fixture, kOarLayoutStereo,
                                        /*headphones_mode=*/0);
  const auto binaural_mode0 = RenderBinauralBed(fixture, kOarLayoutBinaural,
                                                /*headphones_mode=*/0);
  const auto binaural_mode1 = RenderBinauralBed(fixture, kOarLayoutBinaural,
                                                /*headphones_mode=*/1);
  ASSERT_EQ(stereo.size(), size_t{kMaxFrames * kOutChannels});
  ASSERT_EQ(binaural_mode0.size(), stereo.size());
  ASSERT_EQ(binaural_mode1.size(), stereo.size());

  // The renders must carry signal at all for the comparison to mean
  // anything.
  float stereo_peak = 0.0f;
  for (float v : stereo) stereo_peak = std::max(stereo_peak, std::fabs(v));
  ASSERT_GT(stereo_peak, 0.0f);

  // Mode 0 on the binaural target == the stereo target's render
  // (identical stereo-pipeline code path, so exact equality).
  float max_diff_mode0 = 0.0f;
  float max_diff_mode1 = 0.0f;
  for (size_t i = 0; i < stereo.size(); ++i) {
    max_diff_mode0 =
        std::max(max_diff_mode0, std::fabs(binaural_mode0[i] - stereo[i]));
    max_diff_mode1 =
        std::max(max_diff_mode1, std::fabs(binaural_mode1[i] - stereo[i]));
  }
  EXPECT_EQ(max_diff_mode0, 0.0f);
  // World-locked actually binauralizes — the difference must be a
  // meaningful fraction of the signal, not float noise.
  EXPECT_GT(max_diff_mode1, stereo_peak * 0.01f);
}

TEST_F(AudioGraphIamfTest, CloseIamfReleasesSlots) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  EXPECT_TRUE(graph_.has_iamf_session());
  EXPECT_EQ(graph_.meter_state()->element_count, 2u);

  graph_.close_iamf();
  EXPECT_FALSE(graph_.has_iamf_session());
  EXPECT_EQ(graph_.meter_state()->element_count, 0u);

  // Re-open should claim the same slots again.
  EXPECT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  EXPECT_EQ(graph_.meter_state()->element_count, 2u);
}

// Drain helper for the underrun tests: wait until the I/O thread has
// pumped the whole fixture (every ring at EOF — the 100 ms fixture
// fits in the rings whole), then consume past the end so subsequent
// reads are pure EOF shortfalls.
void DrainToEof(AudioGraph& graph) {
  auto* session = graph.iamf_session();
  ASSERT_NE(session, nullptr);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  for (uint32_t i = 0; i < session->num_audio_elements(); ++i) {
    while (!session->ring(i)->eof() &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_TRUE(session->ring(i)->eof()) << "ring " << i << " never hit EOF";
  }
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  for (int i = 0; i < 60; ++i) {  // 60 × 512 ≫ the 4800-frame fixture
    graph.process(out.data(), kMaxFrames, kOutChannels);
  }
}

TEST_F(AudioGraphIamfTest, EofShortReadsAreNotUnderruns) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  DrainToEof(graph_);
  // Every post-EOF process() call read short, but with EOF marked —
  // expected drain behaviour, not starvation.
  EXPECT_EQ(graph_.meter_state()->ring_underrun_count, 0u);
  EXPECT_EQ(graph_.meter_state()->ring_underrun_frames, 0u);
}

TEST_F(AudioGraphIamfTest, StarvedRingCountsUnderruns) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  DrainToEof(graph_);

  // Clear EOF on the drained (empty) rings — exactly the state of a
  // starved ring mid-playback: no data buffered, producer not done.
  // The I/O thread is parked on its EOF sleep and won't re-mark them.
  auto* session = graph_.iamf_session();
  for (uint32_t i = 0; i < session->num_audio_elements(); ++i) {
    ASSERT_EQ(session->ring(i)->buffered_frames(), 0u);
    session->ring(i)->clear_eof();
  }

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  graph_.process(out.data(), kMaxFrames, kOutChannels);

  const EclipsaStudioMeterState* state = graph_.meter_state();
  EXPECT_EQ(state->ring_underrun_count, 2u);  // one per AE
  EXPECT_EQ(state->ring_underrun_frames, 2u * kMaxFrames);
  EXPECT_EQ(state->last_underrun_missing, kMaxFrames);

  // reset_meters clears the counters (new session / device run).
  graph_.reset_meters();
  EXPECT_EQ(state->ring_underrun_count, 0u);
  EXPECT_EQ(state->ring_underrun_frames, 0u);
}

// ES-473: a seek during playback must not hard-cut the output. The
// staged seek fades the IAMF program to silence (~5 ms), posts to the
// session only after reaching silence, holds the chains muted (ring
// reads skipped) until the post-seek refill is primed, then fades
// back in. Assert the audible sequence — signal, a silent hold,
// signal again — and the de-click property itself: no
// consecutive-sample step anywhere in the transition approaches the
// program's own amplitude (the old behaviour's 512-frame underrun
// holes stepped to silence and back at full program level).
TEST_F(AudioGraphIamfTest, SeekFadesOutPrimesThenFadesBackIn) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  graph_.set_bypass_oar(true);  // element audio sums straight to out

  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  ASSERT_TRUE(session->wait_for_buffered(1, kMaxFrames, 2000));

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);

  // Establish signal and measure the program's peak amplitude.
  float peak_amp = 0.0f;
  {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (peak_amp == 0.0f && std::chrono::steady_clock::now() < deadline) {
      session->wait_for_buffered(0, kMaxFrames, 2000);
      session->wait_for_buffered(1, kMaxFrames, 2000);
      graph_.process(out.data(), kMaxFrames, kOutChannels);
      for (float s : out) peak_amp = std::max(peak_amp, std::abs(s));
    }
    ASSERT_GT(peak_amp, 0.0f);
  }

  // Seek back to an early position (the fixture is ~100 ms; priming
  // needs 2048 post-seek frames, comfortably available from 1024).
  // Record the whole post-seek output stream per channel so the
  // silence boundaries can be inspected afterwards.
  //
  // The zero-run edge assertion below leans on this fixture having
  // CONTINUOUS tone at file frame 1024: the run then always ends
  // inside the fade-in ramp (first sample ~= one ramp step, orders of
  // magnitude under the bound). A fixture change that put >= 64
  // samples of digital silence at the seek target would let the run
  // end at full gain and needs the target moved.
  std::vector<std::vector<float>> recorded(kOutChannels);

  graph_.seek(1024);

  // Pump through fade-out → post → priming hold → fade-in. Expect at
  // least one fully-silent block (the mute hold) before signal
  // returns.
  bool saw_silence = false;
  bool signal_back = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!signal_back && std::chrono::steady_clock::now() < deadline) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
    float block_peak = 0.0f;
    for (float s : out) block_peak = std::max(block_peak, std::abs(s));
    for (uint32_t f = 0; f < kMaxFrames; ++f) {
      for (uint32_t c = 0; c < kOutChannels; ++c) {
        recorded[c].push_back(out[f * kOutChannels + c]);
      }
    }
    if (block_peak == 0.0f) {
      saw_silence = true;
    } else if (saw_silence && block_peak > 0.1f * peak_amp) {
      signal_back = true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  EXPECT_TRUE(saw_silence) << "no mute hold observed after seek";
  EXPECT_TRUE(signal_back) << "signal never returned after seek "
                           << "(session error: '" << session->last_error()
                           << "')";
  // The seek reached the session and was applied (floors published).
  EXPECT_GE(session->seeks_applied(), 1u);

  // De-click property: the program itself may slew steeply between
  // samples (the fixture carries high-frequency tones), so a global
  // step bound cannot separate clicks from content. What defines the
  // click is a hard edge AGAINST SILENCE: the old behaviour's underrun
  // holes were >= 512-frame zero runs with program-level samples on
  // both edges. Assert every long zero run (the mute hold included)
  // has small-amplitude neighbours — a fade lands near zero before
  // silence and ramps from near zero after it.
  constexpr size_t kMinRun = 64;  // ignore natural zero crossings
  const float kEdgeBound = 0.15f * peak_amp;
  for (uint32_t c = 0; c < kOutChannels; ++c) {
    const std::vector<float>& s = recorded[c];
    size_t run_start = 0;
    bool in_run = false;
    for (size_t i = 0; i <= s.size(); ++i) {
      const bool zero = i < s.size() && s[i] == 0.0f;
      if (zero && !in_run) {
        in_run = true;
        run_start = i;
      } else if (!zero && in_run) {
        in_run = false;
        if (i - run_start >= kMinRun) {
          if (run_start > 0) {
            EXPECT_LT(std::abs(s[run_start - 1]), kEdgeBound)
                << "hard edge INTO silence at ch " << c << " sample "
                << run_start - 1;
          }
          if (i < s.size()) {
            EXPECT_LT(std::abs(s[i]), kEdgeBound)
                << "hard edge OUT OF silence at ch " << c << " sample " << i;
          }
        }
      }
    }
  }
}

// ES-473: a seek staged while the transport is paused is consumed by
// the audio thread's paused-branch hook (process() doesn't run), so
// the session repositions immediately and resume starts primed — not
// from the stale position.
TEST_F(AudioGraphIamfTest, PausedSeekConsumedByPausedHook) {
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  graph_.set_bypass_oar(true);

  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  const uint64_t requested_before = session->seeks_requested();

  graph_.seek(1024);
  // No process() (paused). The staged seek must reach the session
  // through the hook alone.
  graph_.consume_pending_seek_paused();
  EXPECT_EQ(session->seeks_requested(), requested_before + 1);

  // The I/O thread applies it within its bounded poll interval.
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (session->seeks_applied() < requested_before + 1 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  EXPECT_GE(session->seeks_applied(), requested_before + 1);

  // Resume: the graph holds the mute until primed, then signal flows.
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  bool any_signal = false;
  const auto play_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!any_signal && std::chrono::steady_clock::now() < play_deadline) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
    for (float s : out) {
      if (std::abs(s) > 0.0f) {
        any_signal = true;
        break;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  EXPECT_TRUE(any_signal);
}

TEST_F(AudioGraphIamfTest, OpenIamfCloseIamfIdempotent) {
  // Open twice in a row — the second call should close the first
  // session implicitly.
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  EXPECT_EQ(graph_.meter_state()->element_count, 2u);
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  EXPECT_EQ(graph_.meter_state()->element_count, 2u);

  // Close when there's no session is also a no-op.
  graph_.close_iamf();
  graph_.close_iamf();
  EXPECT_FALSE(graph_.has_iamf_session());
  EXPECT_EQ(graph_.meter_state()->element_count, 0u);
}

TEST_F(AudioGraphIamfTest, StreamGainGateHonorsAppGains) {
  // With stream gains disabled (non-default mix presentation selected
  // by the app), process() must NOT overwrite the app-driven per-AE
  // mix gain with the stream's per-TU value; re-enabling hands control
  // back to the stream fan-out. See eclipsa_studio_playback_use_stream_gains
  // and iamf-tools#23.
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  uint32_t ids[4] = {};
  ASSERT_GT(graph_.iamf_element_ids(ids, 4), 0u);
  const uint32_t id = ids[0];

  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  graph_.set_iamf_stream_gains(false);
  graph_.set_element_mix_gain(id, -24.0f);
  for (int i = 0; i < 3; ++i) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  EXPECT_FLOAT_EQ(graph_.element_mix_gain_db(id), -24.0f);

  graph_.set_iamf_stream_gains(true);
  graph_.process(out.data(), kMaxFrames, kOutChannels);
  // The stream fan-out reclaims the value (the fixture's default gain,
  // whatever it is — just not the app's -24).
  EXPECT_NE(graph_.element_mix_gain_db(id), -24.0f);
}

TEST_F(AudioGraphIamfTest, OpenIamfResetsStreamGainGate) {
  // A left-over disabled gate from a previous file must not survive
  // into the next open — a fresh file starts on its default
  // presentation, where stream gains are authoritative.
  graph_.set_iamf_stream_gains(false);
  ASSERT_GT(graph_.open_iamf(fixture_.c_str()), 0);
  uint32_t ids[4] = {};
  ASSERT_GT(graph_.iamf_element_ids(ids, 4), 0u);
  const uint32_t id = ids[0];

  graph_.set_element_mix_gain(id, -24.0f);
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  graph_.process(out.data(), kMaxFrames, kOutChannels);
  EXPECT_NE(graph_.element_mix_gain_db(id), -24.0f);
}

TEST_F(AudioGraphIamfTest, MixExcludedGatesIamfElement) {
  // Mix-exclusion (the gating mechanism Playback uses when a selected
  // presentation omits an AE) must silence an IAMF-sourced chain via
  // the mute-gain ramp, exactly like a Creator WAV chain, and come
  // back when re-included.
  //
  // Frame budget: despite the name, the noise fixture's trim-adjusted
  // decodable length is 10344 frames (~215 ms, 20 callbacks of 512 —
  // see MismatchedRateSeekConvertsToFileFrames). At EOF the ring
  // returns zero-frame reads and the mute ramp FREEZES (the Gain
  // smoother only advances over processed frames), so each phase must
  // fit inside the data and the re-include phase rewinds via seek(0).
  const std::string noise = FindFixture("noise_3s_stereo_opus.iamf");
  ASSERT_FALSE(noise.empty()) << "fixture missing";
  ASSERT_GT(graph_.open_iamf(noise.c_str()), 0) << graph_.last_iamf_error();
  uint32_t ids[4] = {};
  ASSERT_GT(graph_.iamf_element_ids(ids, 4), 0u);
  const uint32_t id = ids[0];

  auto* session = graph_.iamf_session();
  ASSERT_NE(session, nullptr);
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));

  // Baseline: element meters see the noise. (4 callbacks = 2048 fr.)
  std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
  for (int i = 0; i < 4; ++i) {
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);

  // Exclude and let the ~145 ms (≈14-callback) fade settle on real
  // data, then measure one fresh block: silent. (4+15+1 = 20 blocks =
  // 10240 fr ≤ 10344 — the whole phase stays inside the stream.)
  graph_.set_element_mix_excluded(id, true);
  for (int i = 0; i < 15; ++i) {
    ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  graph_.reset_meters();
  graph_.process(out.data(), kMaxFrames, kOutChannels);
  EXPECT_LT(graph_.meter_state()->elements[0].peak[0], 0.001f);

  // Re-include and rewind for fresh data; the ramp back up needs
  // ~14 callbacks of processed frames again.
  graph_.set_element_mix_excluded(id, false);
  graph_.seek(0);
  for (int i = 0; i < 15; ++i) {
    ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
    graph_.process(out.data(), kMaxFrames, kOutChannels);
  }
  graph_.reset_meters();
  ASSERT_TRUE(session->wait_for_buffered(0, kMaxFrames, 2000));
  graph_.process(out.data(), kMaxFrames, kOutChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);
}

}  // namespace
