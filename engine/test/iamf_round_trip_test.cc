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

// Export → decode → rendered-PCM round trip for multi-presentation
// IAMF (ES-285, chips at ES-88).
//
// Encodes the multi_mix golden textproto (the app builder's exact
// output, pinned by app/test/export/user_metadata_golden_test.dart)
// through the real iamf-tools encoder — via the push-PCM export path
// the app ships (ES-480) — opens the result on the AudioGraph IAMF path,
// and asserts on PCM captured after OAR — not on meters, which tap
// pre-OAR and pre-mix-gain.
//
// The golden's shape: two stereo beds ("Bed" -> bed.wav, "Vocal" ->
// vocal.wav). MP1 "Main" (default): both elements, Bed at -3 dB,
// Vocal at 0 dB. MP2 "Vocal Only": Bed excluded, Vocal at +2 dB.
//
// The engine has no mix-presentation-selection API — the streaming
// decode always follows the default presentation, and switching is
// emulated by the app (set_iamf_stream_gains(false) + constant
// per-element gains + mix exclusion; see playback_session.dart's
// _applyMixToEngine). Phase B replays that exact call sequence, so
// this test also pins the emulation contract.
//
// Each source WAV carries a distinct sine (Bed 440 Hz, Vocal 2 kHz),
// so per-element energy in the rendered stereo mix is separable with a
// Goertzel probe. The capture window (12000 frames = 250 ms) holds an
// integer number of cycles of both tones — no window leakage.

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "graph/audio_graph.h"
#include "gtest/gtest.h"
#include "iamf/iamf_exporter.h"
#include "iamf/iamf_playback_session.h"
#include "renderer/oar_renderer.h"
#include "test/test_output_helper.h"
#include "test/test_wav_helper.h"

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kMaxFrames = 512;
constexpr uint32_t kOutChannels = 2;

// 3.072 s per source (144 coded frames of 1024), enough data for
// warm-up + capture + the ~145 ms exclusion ramp + re-capture without
// hitting ring EOF (where gain ramps freeze).
constexpr int kSourceFrames = 1024 * 144;

constexpr double kBedHz = 440.0;     // 110 cycles per capture window
constexpr double kVocalHz = 2000.0;  // 500 cycles per capture window
constexpr uint32_t kCaptureFrames = 12000;
constexpr int kCaptureBlocks = 24;  // 24 * 512 = 12288 >= kCaptureFrames

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

constexpr double kPi = 3.14159265358979323846;

// Goertzel magnitude of `freq_hz` over the first kCaptureFrames samples
// of `x`, normalized so a unit-amplitude sine reports ~1.0.
double ToneMagnitude(const std::vector<float>& x, double freq_hz) {
  const size_t n = std::min<size_t>(x.size(), kCaptureFrames);
  const double w = 2.0 * kPi * freq_hz / kSampleRate;
  const double c = 2.0 * std::cos(w);
  double s1 = 0.0, s2 = 0.0;
  for (size_t i = 0; i < n; ++i) {
    const double s0 = x[i] + c * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const double mag2 = s1 * s1 + s2 * s2 - c * s1 * s2;
  return std::sqrt(std::max(0.0, mag2)) / (static_cast<double>(n) / 2.0);
}

double Db(double ratio) { return 20.0 * std::log10(ratio); }

class IamfRoundTripTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(graph_.init(kSampleRate, kMaxFrames, kOutChannels));

    const std::string golden = FindFixture("golden/multi_mix.textproto");
    ASSERT_FALSE(golden.empty()) << "golden fixture missing";
    std::ifstream f(golden);
    std::stringstream config;
    config << f.rdbuf();

    const std::string tmp = test_wav::temp_dir();
    // 0.25 amplitude: the summed phases must stay clear of OAR's output
    // limiter, or cross-phase level comparisons get skewed.
    ASSERT_TRUE(test_wav::write_sine_frames(tmp + "/bed.wav", 2, kSampleRate,
                                            16, static_cast<float>(kBedHz),
                                            kSourceFrames, 0.25f));
    ASSERT_TRUE(test_wav::write_sine_frames(tmp + "/vocal.wav", 2, kSampleRate,
                                            16, static_cast<float>(kVocalHz),
                                            kSourceFrames, 0.25f));

    iamf_path_ = tmp + "/multi_mix.iamf";
    std::vector<eclipsa_studio::IamfExporter::PushElement> elements(2);
    elements[0].wav_basename = "bed.wav";
    elements[0].stream.input_wav_path = tmp + "/bed.wav";
    elements[0].stream.pad_to_frames = kSourceFrames;
    elements[0].stream.output_sample_rate = kSampleRate;
    elements[1].wav_basename = "vocal.wav";
    elements[1].stream.input_wav_path = tmp + "/vocal.wav";
    elements[1].stream.pad_to_frames = kSourceFrames;
    elements[1].stream.output_sample_rate = kSampleRate;
    eclipsa_studio::IamfExporter exporter;
    ASSERT_EQ(exporter.EncodePush(config.str(), iamf_path_, elements), 0);
  }

  // Mirror the FFI layer's OAR registration (eclipsa_studio_playback_open) so
  // the render path produces output, like in the app. Both golden AEs
  // are stereo channel beds: eclipsa_studio_playback_open maps their upstream
  // OutputLayout (SoundSystemA_0_2_0) to OAR sub_type 2, then commits
  // the rendering config — without the commit OAR stays silent.
  void RegisterAes() {
    uint32_t ids[8] = {};
    const uint32_t n = graph_.iamf_element_ids(ids, 8);
    auto* oar = graph_.oar_renderer();
    auto* sess = graph_.iamf_session();
    for (uint32_t i = 0; i < n; ++i) {
      const auto info = sess->ae_info(i);
      ASSERT_EQ(info.kind, 0) << "expected a channel-based AE";
      ASSERT_EQ(info.num_channels, 2u);
      ASSERT_TRUE(oar->add_element(ids[i], /*type=*/0,
                                   /*sub_type=*/2, /*num_channels=*/2));
    }
    ASSERT_TRUE(oar->commit_rendering_config());
  }

  void WaitBuffered() {
    auto* session = graph_.iamf_session();
    ASSERT_NE(session, nullptr);
    for (uint32_t i = 0; i < session->num_audio_elements(); ++i) {
      ASSERT_TRUE(session->wait_for_buffered(i, kMaxFrames, 2000))
          << "AE " << i << " never buffered";
    }
  }

  // Process `blocks` callbacks, appending channel 0 of the rendered
  // stereo output to `capture` (nullptr = discard).
  void ProcessBlocks(int blocks, std::vector<float>* capture) {
    auto* session = graph_.iamf_session();
    std::vector<float> out(kMaxFrames * kOutChannels, 0.0f);
    for (int b = 0; b < blocks; ++b) {
      for (uint32_t i = 0; i < session->num_audio_elements(); ++i) {
        ASSERT_TRUE(session->wait_for_buffered(i, kMaxFrames, 2000));
      }
      graph_.process(out.data(), kMaxFrames, kOutChannels);
      if (capture != nullptr) {
        for (uint32_t fr = 0; fr < kMaxFrames; ++fr) {
          capture->push_back(out[fr * kOutChannels]);
        }
      }
    }
  }

  AudioGraph graph_;
  std::string iamf_path_;
};

TEST_F(IamfRoundTripTest, PresentationGainsReachRenderedPcm) {
  ASSERT_GT(graph_.open_iamf(iamf_path_.c_str()), 0)
      << graph_.last_iamf_error();
  RegisterAes();
  WaitBuffered();

  uint32_t ids[4] = {};
  ASSERT_EQ(graph_.iamf_element_ids(ids, 4), 2u);

  // ── Phase A: default presentation (MP1 "Main"), stream gains on ──
  // Warm up a few callbacks so the stream's per-TU gain fan-out has
  // reached the chains, then capture.
  std::vector<float> pcm_a;
  ProcessBlocks(4, nullptr);
  ProcessBlocks(kCaptureBlocks, &pcm_a);

  const double bed_a = ToneMagnitude(pcm_a, kBedHz);
  const double vocal_a = ToneMagnitude(pcm_a, kVocalHz);
  ASSERT_GT(bed_a, 1e-4);
  ASSERT_GT(vocal_a, 1e-4);
  // MP1 gains: Bed -3 dB, Vocal 0 dB. Both sources are equal-amplitude
  // sines and OAR's stereo render treats them identically, so the
  // rendered level difference is exactly the element mix gain delta.
  EXPECT_NEAR(Db(vocal_a / bed_a), 3.0, 1.0);

  // The stream fan-out also identifies which chain is which — the Bed
  // chain carries MP1's -3 dB.
  const bool first_is_bed = graph_.element_mix_gain_db(ids[0]) < -1.0f;
  const uint32_t bed_id = first_is_bed ? ids[0] : ids[1];
  const uint32_t vocal_id = first_is_bed ? ids[1] : ids[0];
  EXPECT_NEAR(graph_.element_mix_gain_db(bed_id), -3.0f, 0.1f);
  EXPECT_NEAR(graph_.element_mix_gain_db(vocal_id), 0.0f, 0.1f);

  // ── Phase B: emulate selecting MP2 "Vocal Only", exactly as the
  // app's _applyMixToEngine does: gate off stream gains, set the
  // folded constant gains (element +2 dB + output 0 dB) through the
  // same slew-ramped setter the app calls, exclude the absent
  // element. ──
  graph_.set_iamf_stream_gains(false);
  graph_.set_element_mix_gain(vocal_id, 2.0f);
  graph_.set_element_mix_excluded(bed_id, true);
  // Let the ~145 ms mute ramp and the gain slew settle over processed
  // frames, then
  // capture straight from the still-running stream. Deliberately no
  // seek anywhere in this test: seek() is asynchronous — the rings
  // keep serving pre-seek audio until the I/O thread swaps them — so
  // a capture can straddle the splice, and a mid-window sine phase
  // discontinuity skews the Goertzel magnitude by a couple of dB
  // (reproducible under parallel test load, where the I/O thread
  // lags). The 3 s fixture fits all phases without rewinding.
  ProcessBlocks(17, nullptr);

  std::vector<float> pcm_b;
  ProcessBlocks(kCaptureBlocks, &pcm_b);

  const double bed_b = ToneMagnitude(pcm_b, kBedHz);
  const double vocal_b = ToneMagnitude(pcm_b, kVocalHz);
  // The excluded element is silent in the render (>= 60 dB down).
  EXPECT_LT(bed_b, bed_a * 1e-3);
  // The included element moved 0 dB -> +2 dB relative to Phase A.
  EXPECT_NEAR(Db(vocal_b / vocal_a), 2.0, 1.0);

  // ── Phase C: back to the default presentation — stream gains
  // reclaim the chains and the excluded element returns. ──
  graph_.set_element_mix_excluded(bed_id, false);
  graph_.set_iamf_stream_gains(true);
  ProcessBlocks(17, nullptr);  // un-mute ramp + gain reclaim

  std::vector<float> pcm_c;
  ProcessBlocks(kCaptureBlocks, &pcm_c);
  const double bed_c = ToneMagnitude(pcm_c, kBedHz);
  const double vocal_c = ToneMagnitude(pcm_c, kVocalHz);
  EXPECT_NEAR(Db(vocal_c / bed_c), 3.0, 1.0);
  EXPECT_NEAR(Db(bed_c / bed_a), 0.0, 1.0);
}

// ES-88: signal integrity of the IAMF ring-source path. The decode I/O
// thread fills per-AE rings that the audio thread drains through OAR;
// a ring wrap, short-read, or re-feed bug splices the rendered PCM —
// exactly the class of output breakage meters can't see. The rendered
// two-tone mix's largest legal per-sample step is the sum of each
// tone's slew bound (amp·2π·f/rate, amplitudes measured from the
// capture itself so the bound tracks the presentation gains); anything
// bigger is a splice.
TEST_F(IamfRoundTripTest, RenderedPcmIsContinuous) {
  ASSERT_GT(graph_.open_iamf(iamf_path_.c_str()), 0)
      << graph_.last_iamf_error();
  RegisterAes();
  WaitBuffered();

  // Warm past the element mute-gain ramp (~145 ms), then capture
  // ~0.5 s. ProcessBlocks waits for ring data before every block, so
  // any short read the capture sees is a graph bug, not test-host
  // scheduling.
  ProcessBlocks(17, nullptr);
  std::vector<float> sig;
  ProcessBlocks(kCaptureBlocks * 2, &sig);

  const double bed = ToneMagnitude(sig, kBedHz);
  const double vocal = ToneMagnitude(sig, kVocalHz);
  ASSERT_GT(bed + vocal, 1e-3) << "no signal reached the output";

  const float step = static_cast<float>(
      2.0 * kPi * (kBedHz * bed + kVocalHz * vocal) / kSampleRate);
  const auto stats = test_output::analyze_signal(sig, kSampleRate, 3.0f * step);
  EXPECT_EQ(stats.jumps, 0)
      << "discontinuities in rendered IAMF output, "
      << "max_jump=" << stats.max_jump << " bound=" << step;
}

}  // namespace
