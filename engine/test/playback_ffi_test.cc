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

// Integration test for the Playback-mode C FFI (engine.h exports).
//
// Exercises the extern "C" entry points the way Dart would call them,
// catching bugs that don't surface in the AudioGraph unit test —
// heap-string ownership on the result struct, OAR element
// registration during open, double-open semantics, and shutdown
// ordering.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

#include "engine.h"
#include "gtest/gtest.h"
#include "iamf/iamf_probe_ffi.h"
#include "renderer/oar_renderer.h"
#include "test/test_wav_helper.h"
#include "transport_fade.h"

// Sets OarRenderer's creation-failure seam. Declared a friend by
// OarRenderer, so it must live in the global namespace.
class OarRendererTestPeer {
 public:
  static void SetFailCreate(bool fail) {
    OarRenderer::fail_create_for_testing_.store(fail,
                                                std::memory_order_relaxed);
  }
};

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBufferSize = 512;

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

// Waits until the transport position stops advancing (two reads a
// callback-period apart agree), or times out. Needed wherever a test
// pauses and then relies on paused-path semantics: the user pause
// fades its final block (ES-530), so the park lands a callback later.
bool wait_transport_parked() {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    const uint64_t p1 = eclipsa_studio_transport_get_position_frames();
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    if (eclipsa_studio_transport_get_position_frames() == p1) return true;
  }
  return false;
}

// Waits until the transport position advances (playing transport), or
// times out. A wedged transport freezes the position permanently, so
// the generous deadline is safe — it never delays a passing run.
bool wait_transport_advanced() {
  const uint64_t p1 = eclipsa_studio_transport_get_position_frames();
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    if (eclipsa_studio_transport_get_position_frames() > p1) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return false;
}

// The dylib must report the API version of the header it was built
// from — FFI clients compare this before calling anything else.
TEST(EngineInfoFfi, ApiVersionMatchesHeader) {
  EXPECT_EQ(eclipsa_studio_api_version(), ECLIPSA_STUDIO_ENGINE_API_VERSION);
}

TEST(EngineInfoFfi, VersionStringIsNonEmpty) {
  const char* v = eclipsa_studio_version();
  ASSERT_NE(v, nullptr);
  EXPECT_GT(std::strlen(v), 0u);
}

// Test fixture — brings the engine up once per test and tears it down
// cleanly. Individual cases can call eclipsa_studio_playback_open/_close
// multiple times without re-initialising.
class PlaybackFfiTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ASSERT_EQ(eclipsa_studio_engine_init(kSampleRate, kBufferSize), 0);
    fixture_ = FindFixture("tones_100ms_3OA_stereo_opus.iamf");
    ASSERT_FALSE(fixture_.empty()) << "fixture missing";
  }
  void TearDown() override {
    eclipsa_studio_playback_close();
    eclipsa_studio_engine_shutdown();
  }

  std::string fixture_;
};

// Capability invariant, end-to-end (ES-326/ES-330): every fixture shape the
// old hand-maintained gates refused — Mono, Binaural, 7.1, Expanded
// 9.1.6, 4OA — probes as renderable and opens with its AE registered.
TEST_F(PlaybackFfiTest, NewlyRenderableShapesProbeAndOpen) {
  const struct {
    const char* fixture;
    int32_t kind;
    uint32_t num_channels;
  } kCases[] = {
      {"sine_128samp_mono_pcm.iamf", 0, 1},
      {"sine_128samp_binaural_pcm.iamf", 0, 2},
      {"sine_128samp_7_1_pcm.iamf", 0, 8},
      {"sine_128samp_expanded916_pcm.iamf", 0, 16},
      {"sine_128samp_4oa_pcm.iamf", 1, 25},
  };
  for (const auto& c : kCases) {
    SCOPED_TRACE(c.fixture);
    const std::string path = FindFixture(c.fixture);
    ASSERT_FALSE(path.empty()) << "fixture missing: " << c.fixture;

    EclipsaStudioIamfProbeResult* probe =
        eclipsa_studio_iamf_probe(path.c_str());
    ASSERT_NE(probe, nullptr);
    ASSERT_EQ(probe->status, 0) << probe->error_message;
    ASSERT_EQ(probe->num_audio_elements, 1u);
    EXPECT_EQ(probe->audio_elements[0].renderable, 1);
    EXPECT_EQ(probe->audio_elements[0].skip_reason,
              ECLIPSA_STUDIO_AE_RENDERABLE);
    EXPECT_EQ(probe->audio_elements[0].num_channels, c.num_channels);
    eclipsa_studio_iamf_probe_free(probe);

    EclipsaStudioPlaybackOpenResult* r =
        eclipsa_studio_playback_open(path.c_str());
    ASSERT_NE(r, nullptr);
    ASSERT_EQ(r->status, 0) << (r->error_message ? r->error_message : "");
    ASSERT_EQ(r->num_audio_elements, 1u);
    EXPECT_EQ(r->audio_elements[0].kind, c.kind);
    EXPECT_EQ(r->audio_elements[0].num_channels, c.num_channels);
    eclipsa_studio_playback_open_result_free(r);
    eclipsa_studio_playback_close();
  }
}

// The probe's renderable flag mirrors what registration will do — the
// multi-AE fixture (3OA + stereo) must report both AEs renderable.
TEST_F(PlaybackFfiTest, ProbeReportsRenderableForSupportedShapes) {
  EclipsaStudioIamfProbeResult* probe =
      eclipsa_studio_iamf_probe(fixture_.c_str());
  ASSERT_NE(probe, nullptr);
  ASSERT_EQ(probe->status, 0) << probe->error_message;
  ASSERT_EQ(probe->num_audio_elements, 2u);
  for (uint32_t i = 0; i < probe->num_audio_elements; ++i) {
    EXPECT_EQ(probe->audio_elements[i].renderable, 1) << "ae " << i;
    EXPECT_EQ(probe->audio_elements[i].skip_reason,
              ECLIPSA_STUDIO_AE_RENDERABLE)
        << "ae " << i;
  }
  eclipsa_studio_iamf_probe_free(probe);
}

TEST_F(PlaybackFfiTest, OpenSuccessPopulatesResult) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->status, 0);
  EXPECT_EQ(r->error_message, nullptr);
  EXPECT_EQ(r->sample_rate, kSampleRate);
  // `total_frames` is published by the upstream lazy temporal-unit scan
  // worker — `eclipsa_studio_playback_open` returns before the scan finishes,
  // so the open-time value is 0. The published total is read via
  // `eclipsa_studio_playback_status()` once `total_samples_ready` flips.
  EXPECT_EQ(r->num_audio_elements, 2u);
  ASSERT_NE(r->audio_elements, nullptr);

  // Both AEs should have positive channel counts and a non-zero
  // audio_element_id; kinds should be 0 (channel) or 1 (scene) since
  // Phase A excludes objects from the supported set.
  for (uint32_t i = 0; i < r->num_audio_elements; ++i) {
    EXPECT_NE(r->audio_elements[i].audio_element_id, 0u);
    EXPECT_GT(r->audio_elements[i].num_channels, 0u);
    EXPECT_TRUE(r->audio_elements[i].kind == 0 ||
                r->audio_elements[i].kind == 1);
  }

  // Poll the lazy-scan state until the worker publishes a total. The
  // 5 s ceiling keeps this from hanging if the scan stalls; the test
  // fixture is tiny so completion takes milliseconds in practice.
  EclipsaStudioPlaybackStatus status = {};
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (std::chrono::steady_clock::now() < deadline) {
    status = eclipsa_studio_playback_status();
    if (status.total_samples_ready) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  EXPECT_EQ(status.session_open, 1);
  EXPECT_EQ(status.scan_complete, 1);
  EXPECT_EQ(status.total_samples_ready, 1);
  EXPECT_GT(status.total_frames, 0u);

  eclipsa_studio_playback_open_result_free(r);
}

TEST_F(PlaybackFfiTest, OpenMissingFileReturnsError) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open("/no/such/file.iamf");
  ASSERT_NE(r, nullptr);
  EXPECT_LT(r->status, 0);
  ASSERT_NE(r->error_message, nullptr);
  EXPECT_GT(std::strlen(r->error_message), 0u);
  EXPECT_EQ(r->num_audio_elements, 0u);
  EXPECT_EQ(r->audio_elements, nullptr);

  eclipsa_studio_playback_open_result_free(r);
}

TEST_F(PlaybackFfiTest, OpenEmptyPathReturnsError) {
  EclipsaStudioPlaybackOpenResult* r = eclipsa_studio_playback_open("");
  ASSERT_NE(r, nullptr);
  EXPECT_LT(r->status, 0);
  EXPECT_NE(r->error_message, nullptr);
  eclipsa_studio_playback_open_result_free(r);
}

TEST_F(PlaybackFfiTest, OpenMalformedBytesReturnsError) {
  // Write a tiny junk file, open it through the FFI.
  const char* tmp = std::getenv("TEST_TMPDIR");
  const std::string path = std::string(tmp ? tmp : "/tmp") + "/ffi_bad.iamf";
  {
    std::ofstream out(path, std::ios::binary);
    out.write("JUNK", 4);
  }

  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(path.c_str());
  ASSERT_NE(r, nullptr);
  EXPECT_LT(r->status, 0);
  EXPECT_NE(r->error_message, nullptr);
  eclipsa_studio_playback_open_result_free(r);
}

// ES-906: a playback open whose OAR commit fails must remove the
// elements it registered, as playback_close does; otherwise every
// later rebuild includes elements of a session that does not exist.
// oar_create() fails only when an allocation fails, so the test
// forces the failure through OarRendererTestPeer. The commit rebuilds
// only when a rendering config is staged, so a WAV element registered
// with OAR stages one before the open. A WAV element beside a playback
// session is a state engine.h calls unsupported; if playback_open starts
// rejecting it, this test needs another way to stage the config.
TEST_F(PlaybackFfiTest, FailedCommitRemovesSessionElementsFromOar) {
  constexpr uint32_t kWavId = 101;
  constexpr int32_t kOarLayoutMono = 1;  // ck_oar_layout_mono

  // The fixture's element ids, from a successful open.
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  std::vector<uint32_t> session_ids;
  for (uint32_t i = 0; i < r->num_audio_elements; ++i) {
    session_ids.push_back(r->audio_elements[i].audio_element_id);
  }
  eclipsa_studio_playback_open_result_free(r);
  eclipsa_studio_playback_close();
  ASSERT_FALSE(session_ids.empty());

  const std::string wav = test_wav::temp_dir() + "/ffi_commit_fail.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 1, 48000, 16, 440.f, 1.f));
  ASSERT_EQ(eclipsa_studio_element_add(wav.c_str(), kWavId), 0);
  ASSERT_EQ(eclipsa_studio_element_set_type(kWavId, 0, kOarLayoutMono, 1), 0);
  // Mode 2 (head-locked) differs from the default, so this stages a
  // change and the open's commit rebuilds.
  ASSERT_EQ(eclipsa_studio_element_set_rendering_config(kWavId, 2, 0), 0);

  OarRendererTestPeer::SetFailCreate(true);
  r = eclipsa_studio_playback_open(fixture_.c_str());
  OarRendererTestPeer::SetFailCreate(false);
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, -7) << "the open did not fail at the commit";
  eclipsa_studio_playback_open_result_free(r);
  EXPECT_EQ(eclipsa_studio_playback_status().session_open, 0);

  // set_rendering_config returns -1 for an id OAR does not track.
  for (const uint32_t id : session_ids) {
    EXPECT_EQ(eclipsa_studio_element_set_rendering_config(id, 1, 0), -1)
        << "element " << id << " is still registered with OAR";
  }
  EXPECT_EQ(eclipsa_studio_element_set_rendering_config(kWavId, 1, 0), 0)
      << "the rollback removed an element the session did not add";

  // The next open rebuilds the renderer.
  r = eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);
  EXPECT_GT(eclipsa_studio_monitoring_get_channels(), 0u);
}

// ES-906: an open over an attached session closes that session first.
// When the new open then fails, the old session's elements must not
// stay registered with OAR either.
TEST_F(PlaybackFfiTest, FailedReopenRemovesPreviousSessionElementsFromOar) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  std::vector<uint32_t> session_ids;
  for (uint32_t i = 0; i < r->num_audio_elements; ++i) {
    session_ids.push_back(r->audio_elements[i].audio_element_id);
  }
  eclipsa_studio_playback_open_result_free(r);
  ASSERT_FALSE(session_ids.empty());

  r = eclipsa_studio_playback_open("/no/such/file.iamf");
  ASSERT_NE(r, nullptr);
  ASSERT_LT(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);
  EXPECT_EQ(eclipsa_studio_playback_status().session_open, 0);

  for (const uint32_t id : session_ids) {
    EXPECT_EQ(eclipsa_studio_element_set_rendering_config(id, 1, 0), -1)
        << "element " << id << " is still registered with OAR";
  }
}

// ES-906: a successful open over an attached session must not leave the
// old session's elements registered when the new file does not reuse
// their ids.
TEST_F(PlaybackFfiTest, ReopenRemovesPreviousSessionElementsFromOar) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  std::vector<uint32_t> old_ids;
  for (uint32_t i = 0; i < r->num_audio_elements; ++i) {
    old_ids.push_back(r->audio_elements[i].audio_element_id);
  }
  eclipsa_studio_playback_open_result_free(r);

  const std::string mono = FindFixture("sine_128samp_mono_pcm.iamf");
  ASSERT_FALSE(mono.empty()) << "fixture missing";
  r = eclipsa_studio_playback_open(mono.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  std::vector<uint32_t> new_ids;
  for (uint32_t i = 0; i < r->num_audio_elements; ++i) {
    new_ids.push_back(r->audio_elements[i].audio_element_id);
  }
  eclipsa_studio_playback_open_result_free(r);

  int dropped = 0;
  for (const uint32_t id : old_ids) {
    if (std::find(new_ids.begin(), new_ids.end(), id) != new_ids.end()) {
      continue;
    }
    ++dropped;
    EXPECT_EQ(eclipsa_studio_element_set_rendering_config(id, 1, 0), -1)
        << "element " << id << " is still registered with OAR";
  }
  ASSERT_GT(dropped, 0) << "the new file reuses every old element id";
}

TEST_F(PlaybackFfiTest, ReopenReplacesSession) {
  EclipsaStudioPlaybackOpenResult* r1 =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r1, nullptr);
  ASSERT_EQ(r1->status, 0);
  eclipsa_studio_playback_open_result_free(r1);

  // A second open should close the previous session internally and
  // succeed again.
  EclipsaStudioPlaybackOpenResult* r2 =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r2, nullptr);
  EXPECT_EQ(r2->status, 0);
  EXPECT_EQ(r2->num_audio_elements, 2u);
  eclipsa_studio_playback_open_result_free(r2);
}

TEST_F(PlaybackFfiTest, CloseIsIdempotent) {
  eclipsa_studio_playback_close();
  eclipsa_studio_playback_close();
  // No crash. Open still works afterwards.
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);
}

// eclipsa_studio_meter_reset_clips must clear sticky clip flags while the
// transport is playing (the old implementation silently skipped the
// reset during playback, so a latched clip light could only be cleared
// by pausing). During playback the clear is handed to the audio thread
// — the sole writer of clip[] — which applies it at the top of its
// next callback, so this path is race-free and we poll briefly for the
// effect. While paused the clear is immediate.
//
// NB: like the Dart UI, this test reads/writes the plain shared meter
// memory from the control thread while the audio thread runs, so it is
// not TSan-clean — same by-design pattern as the rest of the meter
// state (see meter_state.h) and the pre-existing loudness race test.
TEST_F(PlaybackFfiTest, MeterResetClipsClearsWhilePlaying) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);

  auto* state =
      const_cast<EclipsaStudioMeterState*>(eclipsa_studio_get_meter_state());
  ASSERT_NE(state, nullptr);
  ASSERT_GT(state->element_count, 0u);

  eclipsa_studio_transport_play();
  if (eclipsa_studio_transport_is_audio_thread_running()) {
    // Let the 100 ms fixture play past EOF first. The transport keeps
    // "playing" silence after the stream ends, so nothing can re-latch
    // the injected flag between the audio thread's clear and this
    // thread's read. Clearing mid-content was the flake: the decoded
    // tones peak >= 1.0, so the sticky clip latched right back.
    const auto eof_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (eclipsa_studio_transport_get_position_frames() < kSampleRate / 5 &&
           std::chrono::steady_clock::now() < eof_deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    state->elements[0].clip[0] = 1;
    eclipsa_studio_meter_reset_clips();
    // Consumed by the audio thread on its next block (~10 ms); allow a
    // generous deadline for slow CI callbacks.
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (state->elements[0].clip[0] != 0 &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(state->elements[0].clip[0], 0);
  }
  eclipsa_studio_transport_pause();
  // The user pause fades its final block (ES-530), so the transport
  // parks a callback later — wait for the position to stop advancing
  // before exercising the paused-path behavior below.
  wait_transport_parked();

  // Paused-path parity: the reset is immediate when not playing.
  state->elements[0].clip[0] = 1;
  eclipsa_studio_meter_reset_clips();
  EXPECT_EQ(state->elements[0].clip[0], 0);
}

// ES-530: a user pause fades the final block instead of hard-cutting
// mid-waveform. Transport semantics under that: the pause parks within
// about one callback (not instantly), and a quick pause→play must keep
// playing — the pending fade is cancelled by play, never consumed
// later as a stop against the resumed program.
TEST_F(PlaybackFfiTest, FadeStopParksAndQuickResumeKeepsPlaying) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);

  eclipsa_studio_transport_play();
  if (!eclipsa_studio_transport_is_audio_thread_running()) {
    GTEST_SKIP() << "no audio device — transport callbacks never fire";
  }

  // Position advances while playing (silence past EOF still counts).
  ASSERT_TRUE(wait_transport_advanced());

  eclipsa_studio_transport_pause();
  EXPECT_TRUE(wait_transport_parked()) << "pause never parked the transport";

  // Quick pause→play: the discarded fade must not stop the resumed
  // program on its first block.
  eclipsa_studio_transport_play();
  ASSERT_TRUE(wait_transport_advanced());
  eclipsa_studio_transport_pause();
  eclipsa_studio_transport_play();
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  EXPECT_TRUE(wait_transport_advanced())
      << "transport wedged by a stale fade-stop";

  // The app's stop path calls eclipsa_studio_meter_reset_levels() immediately
  // after the pause. The reset's quiesce barrier must wait the fade
  // out (not truncate it): by the time it returns, the transport is
  // parked for good, and the level meters are cleared.
  eclipsa_studio_transport_pause();
  eclipsa_studio_meter_reset_levels();
  const uint64_t at_reset = eclipsa_studio_transport_get_position_frames();
  std::this_thread::sleep_for(std::chrono::milliseconds(60));
  EXPECT_EQ(eclipsa_studio_transport_get_position_frames(), at_reset)
      << "transport still moving after the post-pause meter reset returned";
  const EclipsaStudioMeterState* state = eclipsa_studio_get_meter_state();
  ASSERT_NE(state, nullptr);
  EXPECT_FLOAT_EQ(state->elements[0].peak[0], 0.0f);
}

// ES-547: a play() landing while the final fade-out block is mid-ramp
// must never be overwritten by the fade's park (a parked engine under
// an app that believes it plays is a wedged transport), and a pause
// re-issued inside the same window must never be silently lost. This
// is a PROBABILISTIC guard: each cycle dwells somewhere in the span
// where the park lands — kTransportFadeOutMs of ramp plus up to two
// callback periods of quantization — so cycles hit every phase of the
// fade, but only unlucky micro-timing enters the exact [snapshot →
// park-CAS] window. It raises the odds far above app-driven timing;
// it cannot make the race deterministic (that would need a test seam
// injecting transitions from inside the fade block).
TEST_F(PlaybackFfiTest, FadeStopPlayHammerNeverWedges) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);

  eclipsa_studio_transport_play();
  if (!eclipsa_studio_transport_is_audio_thread_running()) {
    GTEST_SKIP() << "no audio device — transport callbacks never fire";
  }
  ASSERT_TRUE(wait_transport_advanced());

  // Park lands within the fade ramp plus up to two callback periods.
  // The period is nominal — the requested buffer size, which the
  // device backend may quantize — so the ceiling is approximate;
  // overshooting it is harmless (a fully-parked cycle).
  constexpr uint64_t kCallbackPeriodUs =
      uint64_t{kBufferSize} * 1'000'000 / kSampleRate;
  constexpr uint64_t kSweepCeilingUs =
      static_cast<uint64_t>(kTransportFadeOutMs * 1000.0f) +
      2 * kCallbackPeriodUs;
  constexpr int kCycles = 150;
  // Stride coprime to the ceiling (gcd(7807, 31332) == 1) so the
  // dwell sweeps the span near-uniformly instead of resonating with
  // the callback period.
  constexpr uint64_t kSweepStrideUs = 7807;
  static_assert(std::gcd(kSweepStrideUs, kSweepCeilingUs) == 1,
                "sweep must visit distinct phases across the span");

  for (int i = 0; i < kCycles; ++i) {
    eclipsa_studio_transport_pause();
    std::this_thread::sleep_for(std::chrono::microseconds(
        (static_cast<uint64_t>(i) * kSweepStrideUs) % kSweepCeilingUs));
    eclipsa_studio_transport_play();
  }

  // The last transition was a play: the position must advance.
  EXPECT_TRUE(wait_transport_advanced())
      << "transport wedged by a fade-stop racing play";

  // And the reverse: a final pause must park — a pause re-issued
  // inside the park window must not be consumed by a stale fade
  // against the wrong state (the lost-pause sibling of the wedge).
  eclipsa_studio_transport_pause();
  EXPECT_TRUE(wait_transport_parked())
      << "pause lost to a fade-stop racing play";
}

// ES-528: the pause-path reset exported as eclipsa_studio_meter_reset_levels
// zeroes the level meters through the same quiescence barrier as the
// full reset, but the sticky clip latches survive — they clear only
// via eclipsa_studio_meter_reset_clips or the full eclipsa_studio_meter_reset.
TEST_F(PlaybackFfiTest, MeterResetLevelsPreservesClipLatches) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  ASSERT_EQ(r->status, 0);
  eclipsa_studio_playback_open_result_free(r);

  auto* state =
      const_cast<EclipsaStudioMeterState*>(eclipsa_studio_get_meter_state());
  ASSERT_NE(state, nullptr);
  ASSERT_GT(state->element_count, 0u);

  state->elements[0].clip[0] = 1;
  state->elements[0].peak[0] = 0.5f;
  eclipsa_studio_meter_reset_levels();
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 1)
      << "levels reset wiped the clip latch";
  EXPECT_FLOAT_EQ(state->elements[0].peak[0], 0.0f);

  eclipsa_studio_meter_reset();
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 0)
      << "full reset left the clip latch";
}

TEST_F(PlaybackFfiTest, ElementIdsReportSlotOrderThroughCompaction) {
  // ES-531: hosts key UI state by engine slot, and eclipsa_studio_element_ids is
  // the engine-authoritative slot→id mapping they verify against.
  // remove_element compacts by swapping the LAST chain into the vacated
  // slot — the reported order must show exactly that.
  const std::string wav = test_wav::temp_dir() + "/ffi_ids_sine.wav";
  ASSERT_TRUE(test_wav::write_sine(wav, 1, 48000, 16, 440.f, 1.f));

  ASSERT_EQ(eclipsa_studio_element_add(wav.c_str(), 101), 0);
  ASSERT_EQ(eclipsa_studio_element_add(wav.c_str(), 102), 0);
  ASSERT_EQ(eclipsa_studio_element_add(wav.c_str(), 103), 0);

  uint32_t ids[8] = {};
  ASSERT_EQ(eclipsa_studio_element_ids(ids, 8), 3u);
  EXPECT_EQ(ids[0], 101u);
  EXPECT_EQ(ids[1], 102u);
  EXPECT_EQ(ids[2], 103u);

  eclipsa_studio_element_remove(101);  // Swap-with-last: 103 lands in slot 0.
  ASSERT_EQ(eclipsa_studio_element_ids(ids, 8), 2u);
  EXPECT_EQ(ids[0], 103u);
  EXPECT_EQ(ids[1], 102u);

  // Undersized buffer: full count returned, only capacity entries
  // written (the FFI contract Dart sizes its buffer by).
  uint32_t one[1] = {};
  EXPECT_EQ(eclipsa_studio_element_ids(one, 1), 2u);
  EXPECT_EQ(one[0], 103u);

  eclipsa_studio_element_remove(102);
  eclipsa_studio_element_remove(103);
  EXPECT_EQ(eclipsa_studio_element_ids(ids, 8), 0u);
}

TEST_F(PlaybackFfiTest, FreeNullResultIsSafe) {
  eclipsa_studio_playback_open_result_free(nullptr);
  SUCCEED();
}

TEST_F(PlaybackFfiTest, OpenCloseOpenCloseHoldsUp) {
  // Stress the open/close lifecycle to surface leaks or state carried
  // between sessions (caught by --config=asan separately).
  for (int i = 0; i < 5; ++i) {
    EclipsaStudioPlaybackOpenResult* r =
        eclipsa_studio_playback_open(fixture_.c_str());
    ASSERT_NE(r, nullptr) << "iteration " << i;
    ASSERT_EQ(r->status, 0) << "iteration " << i;
    eclipsa_studio_playback_open_result_free(r);
    eclipsa_studio_playback_close();
  }
}

// Regression for the buffer-size reconfigure bug: a buffer-size-only
// reconfigure (same device, same rate) must reinit OAR for the new
// block size. The old condition compared the granted size against
// g_buffer_size after it had already been overwritten with the
// request, so OAR silently kept its old block size — silence when the
// buffer grew, mis-sized blocks into the OBR library when it shrank.
TEST_F(PlaybackFfiTest, BufferSizeReconfigureReinitsOar) {
  if (eclipsa_studio_device_count() == 0) {
    GTEST_SKIP() << "no audio output devices in this environment";
  }
  ASSERT_EQ(eclipsa_studio_oar_buffer_size(),
            eclipsa_studio_current_buffer_size());

  const uint32_t device = eclipsa_studio_current_device_index();
  const int32_t rc =
      eclipsa_studio_engine_reconfigure(device, /*sample_rate=*/0,
                                        /*buffer_size=*/1024);
  if (rc != 0) {
    GTEST_SKIP() << "device reopen unavailable (rc=" << rc << ")";
  }
  // The device may legitimately grant a different size than requested;
  // what must hold is that OAR matches whatever is in effect.
  const uint32_t granted = eclipsa_studio_current_buffer_size();
  EXPECT_EQ(eclipsa_studio_oar_buffer_size(), granted);

  ASSERT_EQ(eclipsa_studio_engine_reconfigure(device, 0, kBufferSize), 0);
  EXPECT_EQ(eclipsa_studio_oar_buffer_size(),
            eclipsa_studio_current_buffer_size());

  if (granted == kBufferSize) {
    GTEST_SKIP() << "device clamped the buffer to its previous size — "
                    "regression path not exercised here";
  }
}

// Rate-mismatch test: a 48 kHz file on a 96 kHz engine opens cleanly —
// per-chain resamplers convert (this used to be rejected with -6).
// Own fixture so the engine inits at 96 kHz instead of kSampleRate.
class PlaybackFfiMismatchedRateTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ASSERT_EQ(eclipsa_studio_engine_init(96000, kBufferSize), 0);
    fixture_ = FindFixture("tones_100ms_3OA_stereo_opus.iamf");
    ASSERT_FALSE(fixture_.empty()) << "fixture missing";
  }
  void TearDown() override {
    eclipsa_studio_playback_close();
    eclipsa_studio_engine_shutdown();
  }

  std::string fixture_;
};

TEST_F(PlaybackFfiMismatchedRateTest, OpenSucceedsAndReportsFileRate) {
  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open(fixture_.c_str());
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(r->status, 0) << (r->error_message ? r->error_message : "");
  EXPECT_EQ(r->error_message, nullptr);
  // The result carries the FILE's rate; the Dart side rebases its
  // timeline onto the engine rate.
  EXPECT_EQ(r->sample_rate, 48000u);
  EXPECT_EQ(r->num_audio_elements, 2u);
  eclipsa_studio_playback_open_result_free(r);
}

// Init-ordering test: opening without a prior init should fail
// gracefully, not crash. This runs in its own test fixture so the
// standard SetUp/TearDown doesn't init first.
class PlaybackFfiUninitializedTest : public ::testing::Test {};

TEST_F(PlaybackFfiUninitializedTest, OpenBeforeInitFails) {
  // Confirm we're not carrying init state from another test — shut
  // down defensively.
  eclipsa_studio_engine_shutdown();

  EclipsaStudioPlaybackOpenResult* r =
      eclipsa_studio_playback_open("/ignored/path");
  ASSERT_NE(r, nullptr);
  EXPECT_LT(r->status, 0);
  EXPECT_NE(r->error_message, nullptr);
  eclipsa_studio_playback_open_result_free(r);
}

}  // namespace
