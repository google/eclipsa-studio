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

#include "graph/audio_graph.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <numbers>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "io/wav_stream.h"
#include "meters/bs1770_weights.h"
#include "renderer/oar_renderer.h"
#include "test/test_output_helper.h"
#include "test/test_wav_helper.h"

// Befriended by AudioGraph: stalls or releases an element's disk-thread
// stream (WavStream::set_stalled_for_testing()).
class AudioGraphTestPeer {
 public:
  static void StallWavStream(AudioGraph& graph, uint32_t id, bool stalled) {
    ElementChain* chain = graph.find_element(id);
    ASSERT_NE(chain, nullptr);
    ASSERT_NE(chain->wav_stream, nullptr);
    chain->wav_stream->set_stalled_for_testing(stalled);
  }
};

namespace {

// Runs `blocks` process() calls, waiting before each until the WAV
// elements' disk-thread rings can serve it, as the time between device
// callbacks would allow (AudioGraph::wait_for_wav_streams). A WAV
// element holds 4096 frames when added, 8 blocks of 512, and a seek
// holds the program until the disk thread has refilled.
void RunBlocks(AudioGraph& graph, int blocks, float* out, uint32_t frames,
               uint32_t channels) {
  for (int i = 0; i < blocks; ++i) {
    EXPECT_TRUE(graph.wait_for_wav_streams(frames));
    graph.process(out, frames, channels);
  }
}

class AudioGraphTest : public ::testing::Test {
 protected:
  void SetUp() override {
    dir_ = test_wav::temp_dir();
    sine_ = dir_ + "/graph_sine_1ch_48k.wav";
    ASSERT_TRUE(test_wav::write_sine(sine_, 1, 48000, 16, 440.f, 1.f));
  }

  std::string dir_, sine_;
  AudioGraph graph_;
};

TEST_F(AudioGraphTest, InitSucceeds) {
  EXPECT_TRUE(graph_.init(48000, 512, 2));
}

TEST_F(AudioGraphTest, AddElementReturnsZeroOnSuccess) {
  graph_.init(48000, 512, 2);
  EXPECT_EQ(graph_.add_element(1, sine_.c_str()), 0);
}

TEST_F(AudioGraphTest, AddNonExistentWavFails) {
  graph_.init(48000, 512, 2);
  EXPECT_LT(graph_.add_element(99, "/no/such/file.wav"), 0);
}

TEST_F(AudioGraphTest, ProcessWithOneSourceIsNonZero) {
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);

  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kChannels = 2;
  float out[kFrames * kChannels] = {};

  graph_.process(out, kFrames, kChannels);

  // The element is deliberately NOT registered with OAR here (the app
  // does that via a separate FFI call), so the output stays silent and
  // we verify via meter state. Output-level PCM coverage lives in the
  // *OutputIs* tests below (ES-88).
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_NE(state, nullptr);
  EXPECT_GT(state->elements[0].peak[0], 0.0f);
}

TEST_F(AudioGraphTest, MutedElementProducesNoOutput) {
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  graph_.set_element_mute(1, true);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.process(out, kFrames, kChannels);

  for (const auto& sample : out) {
    EXPECT_FLOAT_EQ(sample, 0.0f);
  }
}

TEST_F(AudioGraphTest, RemoveElementLeavesNoOutput) {
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  graph_.remove_element(1);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.process(out, kFrames, kChannels);

  for (const auto& sample : out) {
    EXPECT_FLOAT_EQ(sample, 0.0f);
  }
}

TEST_F(AudioGraphTest, MeterStateUpdatedAfterProcess) {
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.process(out, kFrames, kChannels);

  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_NE(state, nullptr);
  EXPECT_GT(state->frame_counter, 0u);
  EXPECT_EQ(state->element_count, 1u);
  // Linear peak should be > 0 for a sine wave.
  EXPECT_GT(state->elements[0].peak[0], 0.0f);
}

TEST_F(AudioGraphTest, ResampledElementProducesMeterEnergy) {
  // 44.1 kHz file into a 48 kHz engine — the graph should attach a
  // resampler in add_element and play normally rather than silently
  // pitching up. Meter peak should be non-zero (sine survives the
  // linear LPF) and consistent across consecutive callbacks.
  const std::string sine_441 = dir_ + "/graph_sine_1ch_441.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_441, 1, 44100, 16, 440.f, 1.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(2, sine_441.c_str()), 0);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  // Drive a few callbacks so the resampler's LPF reaches steady state
  // before we sample meter values.
  RunBlocks(graph_, 4, out, kFrames, kChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);
}

TEST_F(AudioGraphTest, ResampledSeekRestartsAtRequestedFrame) {
  // Seeking with a resampled chain must convert engine-frame target
  // back to WAV-frame target so the chain restarts at the same
  // playhead position the caller asked for.
  const std::string sine_441 = dir_ + "/graph_sine_1ch_441_2s.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_441, 1, 44100, 16, 440.f, 2.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(3, sine_441.c_str()), 0);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};

  // Seek to 1 second (48000 engine frames → 44100 WAV frames).
  graph_.seek(48000);
  RunBlocks(graph_, 4, out, kFrames, kChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);
}

TEST_F(AudioGraphTest, SetSampleRateRetargetsResampler) {
  // 44.1 kHz file at a 48 kHz engine (resampler attached), then the
  // engine retargets to 96 kHz. seek() takes engine-rate frames, so a
  // seek to 1.5 s only lands inside the 2 s file if the resampler was
  // re-inited at the new rate — through a stale 48 kHz out_rate the
  // same frame count converts to 3 s, past EOF, and the chain goes
  // silent.
  const std::string sine_441 = dir_ + "/graph_sine_1ch_441_2s_sr.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_441, 1, 44100, 16, 440.f, 2.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(4, sine_441.c_str()), 0);
  ASSERT_TRUE(graph_.set_sample_rate(96000));
  EXPECT_EQ(graph_.sample_rate(), 96000u);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.seek(144000);  // 1.5 s at 96 kHz.
  RunBlocks(graph_, 4, out, kFrames, kChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);
}

TEST_F(AudioGraphTest, SetSampleRateMatchingWavDropsResampler) {
  // 44.1 kHz file at a 48 kHz engine, then the engine retargets to the
  // file's native 44.1 kHz — the matched-rate fast path, no resampler.
  // A seek past the file's 88200-frame end must go silent; a leftover
  // 44.1→48 resampler would convert 90000 engine frames back to
  // ~82687 WAV frames, inside the file, and keep producing audio.
  const std::string sine_441 = dir_ + "/graph_sine_1ch_441_2s_drop.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_441, 1, 44100, 16, 440.f, 2.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(5, sine_441.c_str()), 0);
  ASSERT_TRUE(graph_.set_sample_rate(44100));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};

  // Positive control: in-bounds seek still produces audio.
  graph_.seek(66150);  // 1.5 s at 44.1 kHz.
  RunBlocks(graph_, 4, out, kFrames, kChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);

  // Past EOF at the native rate: silence.
  graph_.seek(90000);
  graph_.reset_meters();
  RunBlocks(graph_, 4, out, kFrames, kChannels);
  EXPECT_LT(graph_.meter_state()->elements[0].peak[0], 0.001f);
}

TEST_F(AudioGraphTest, SetSampleRateCreatesResamplerForMatchedChain) {
  // 48 kHz file at a 48 kHz engine (no resampler), then the engine
  // retargets to 96 kHz — a resampler must be created. The 2 s file
  // now spans 192000 engine frames; a seek to 1.5 s (144000) only
  // lands inside it through the new resampler. Without one the seek
  // hits the WAV cursor directly, clamps at the 96000-frame EOF, and
  // the chain goes silent.
  const std::string sine_48 = dir_ + "/graph_sine_1ch_48k_2s.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_48, 1, 48000, 16, 440.f, 2.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(6, sine_48.c_str()), 0);
  ASSERT_TRUE(graph_.set_sample_rate(96000));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.seek(144000);  // 1.5 s at 96 kHz.
  RunBlocks(graph_, 4, out, kFrames, kChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);
}

// Regression for the 96 kHz device / 48 kHz file click train: the
// resample path passes rin.frames to the resampler after the WAV read,
// so the read must set rin.frames on every call. WavStream::read sets
// out.frames = 0 on a zero-frame request. A read that returns without
// setting it leaves a stale count, which re-feeds already-consumed
// samples into the resampler on every callback where required_input()
// returns 0 (libsamplerate buffers the overfeed headroom internally, so
// that happens every few callbacks). The test renders the full chain
// (WavStream → resampler → OAR → output) and asserts the output is a
// continuous, pitch-correct sine; with a stale count the output
// measured about 185 discontinuities per second.
TEST_F(AudioGraphTest, SetSampleRateResampledOutputIsContinuous) {
  const std::string sine_12ch = dir_ + "/graph_sine_12ch_48k_4s.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_12ch, 12, 48000, 16, 440.f, 4.f));

  graph_.init(48000, 512, 2);
  // Register with OAR the way the app does (channel-based, 7.1.4) and
  // set the stereo monitoring layout with identity routing.
  ASSERT_TRUE(test_output::add_wav_element(graph_, 7, sine_12ch,
                                           test_output::kLayout714, 12));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  // The live reconfigure recipe: retarget the graph, reinit OAR.
  ASSERT_TRUE(graph_.set_sample_rate(96000));
  ASSERT_TRUE(graph_.oar_renderer()->reinit_for_format(96000, 512));
  graph_.seek(0);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  // Skip the mute-gain ramp (~145 ms), then collect ~1 s of channel 0.
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const std::vector<float> sig =
      test_output::collect_channel(graph_, 188, kFrames, kChannels, 0);

  // A 440 Hz sine at 96 kHz moves at most ≈ 0.0288·A per sample; any
  // larger sample-to-sample jump is a splice. The zero-crossing rate
  // pins pitch (880/s expected — re-fed input also drags the pitch
  // off).
  const auto stats = test_output::analyze_signal(sig, 96000, 0.08f);
  EXPECT_GT(stats.peak, 0.05f) << "no signal reached the output";
  EXPECT_EQ(stats.jumps, 0)
      << "discontinuities in resampled output, max_jump=" << stats.max_jump;
  EXPECT_NEAR(stats.zc_per_sec, 880.0, 10.0);
}

// ES-88 output-level baseline: a matched-rate stereo bed through the
// full chain (WAV → gains → OAR stereo target → identity routing).
// The rendered PCM itself must be a clean 440 Hz sine — level,
// continuity, and pitch — not just meter energy: meters tap the chain
// pre-OAR and stayed healthy through the ES-85 output breakage.
// A 7.1.5.4 element has 17 channels and a 10.2.9.3 element 24 (ES-864):
// both register with OAR at their own layout (oar_layout_t 12 and 11,
// renderer/channel_layouts.txt) and channel count, within
// kGraphMaxChannels, render on a stereo target, and have BS.1770 weights
// for the mix-bus meter.
TEST_F(AudioGraphTest, ExpandedElementLayoutsRegisterAndRender) {
  const struct {
    const char* name;
    int sub_type;
    uint32_t channels;
  } layouts[] = {{"7154", 12, 17}, {"10293", 11, 24}};
  for (const auto& l : layouts) {
    SCOPED_TRACE(l.name);
    const std::string wav = dir_ + "/graph_sine_" + l.name + "_48k.wav";
    ASSERT_TRUE(test_wav::write_sine_frames(wav, static_cast<int>(l.channels),
                                            48000, 16, 440.f, 48000,
                                            /*amplitude=*/0.1f));
    // AudioGraph carries about 25 MB of pre-allocated buffers: heap-allocate
    // it rather than put it on the stack.
    auto graph_ptr = std::make_unique<AudioGraph>();
    AudioGraph& graph = *graph_ptr;
    ASSERT_TRUE(graph.init(48000, 512, 2));
    ASSERT_TRUE(
        test_output::add_wav_element(graph, 1, wav, l.sub_type, l.channels));
    ASSERT_TRUE(
        test_output::set_layout_identity(graph, test_output::kLayoutStereo, 2));
    EXPECT_EQ(eclipsa_studio::Bs1770WeightsForLayout(
                  static_cast<uint32_t>(l.sub_type))
                  .size(),
              l.channels);

    constexpr uint32_t kFrames = 512, kChannels = 2;
    test_output::run_blocks(graph, test_output::kWarmupBlocks, kFrames,
                            kChannels);
    const auto sig =
        test_output::collect_channel(graph, 20, kFrames, kChannels, 0);
    const auto stats = test_output::analyze_signal(sig, 48000, 1.0f);
    EXPECT_GT(stats.peak, 0.01f) << "no signal reached the output";
  }
}

TEST_F(AudioGraphTest, MatchedRateStereoOutputIsCleanSine) {
  const std::string sine_2ch = dir_ + "/graph_sine_2ch_48k_2s.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine_2ch, 2, 48000, 16, 440.f,
                                          2 * 48000, /*amplitude=*/0.25f));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_2ch,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const auto sig =
      test_output::collect_channel(graph_, 90, kFrames, kChannels, 0);

  const float step = test_output::sine_max_step(440.f, 48000.f, 0.25f);
  const auto stats = test_output::analyze_signal(sig, 48000, 3.0f * step);
  EXPECT_GT(stats.peak, 0.05f) << "no signal reached the output";
  EXPECT_EQ(stats.jumps, 0) << "max_jump=" << stats.max_jump;
  EXPECT_NEAR(stats.zc_per_sec, 880.0, 10.0);
}

// ES-88: 44.1 kHz source in a 48 kHz engine — the everyday mismatch
// (44.1 k content on a 48 k device), upsampling by the awkward 160:147
// ratio. Distinct from the 48→96 retarget above. Only meter energy was
// asserted for this path before; the render must be splice-free and
// pitch-true at the output.
TEST_F(AudioGraphTest, Mismatched441OutputIsContinuous) {
  const std::string sine_441 = dir_ + "/graph_sine_2ch_441_3s.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine_441, 2, 44100, 16, 440.f,
                                          3 * 44100, /*amplitude=*/0.25f));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_441,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const auto sig =
      test_output::collect_channel(graph_, 90, kFrames, kChannels, 0);

  const float step = test_output::sine_max_step(440.f, 48000.f, 0.25f);
  const auto stats = test_output::analyze_signal(sig, 48000, 3.0f * step);
  EXPECT_GT(stats.peak, 0.05f) << "no signal reached the output";
  EXPECT_EQ(stats.jumps, 0) << "max_jump=" << stats.max_jump;
  EXPECT_NEAR(stats.zc_per_sec, 880.0, 10.0);
}

// ES-88: seek during resampled playback. The seek path converts the
// engine-frame target back to WAV frames and resets the resampler;
// the post-seek render must come back as a clean continuous sine — a
// stale resampler FIFO would splice pre-seek samples into the new
// position.
TEST_F(AudioGraphTest, SeekWhileResamplingOutputIsContinuous) {
  const std::string sine_441 = dir_ + "/graph_sine_2ch_441_4s.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine_441, 2, 44100, 16, 440.f,
                                          4 * 44100, /*amplitude=*/0.25f));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_441,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  graph_.seek(48000);  // 1 s in engine frames.
  // The block straddling the seek is legitimately discontinuous (phase
  // jump to the new position); everything after it must be clean.
  test_output::run_blocks(graph_, 2, kFrames, kChannels);
  const auto sig =
      test_output::collect_channel(graph_, 90, kFrames, kChannels, 0);

  const float step = test_output::sine_max_step(440.f, 48000.f, 0.25f);
  const auto stats = test_output::analyze_signal(sig, 48000, 3.0f * step);
  EXPECT_GT(stats.peak, 0.05f) << "no signal after the seek";
  EXPECT_EQ(stats.jumps, 0) << "max_jump=" << stats.max_jump;
  EXPECT_NEAR(stats.zc_per_sec, 880.0, 10.0);
}

// ES-88: binaural output target. OBR spatializes a world-locked stereo
// bed through HRIRs; the signal at each ear is still a steady 440 Hz
// tone, so it must render continuous and pitch-true. A rate or config
// mismatch in the binaural pipeline shows up here as splices or
// silence — no other test renders program audio through the binaural
// target.
TEST_F(AudioGraphTest, BinauralLayoutOutputIsContinuous) {
  const std::string sine_2ch = dir_ + "/graph_sine_2ch_48k_2s_bin.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine_2ch, 2, 48000, 16, 440.f,
                                          2 * 48000, /*amplitude=*/0.25f));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_2ch,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(test_output::set_layout_identity(
      graph_, test_output::kLayoutBinaural, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const auto sig =
      test_output::collect_channel(graph_, 90, kFrames, kChannels, 0);

  // HRIR filtering scales the tone by an unknown gain, so bound the
  // per-sample step relative to the measured peak (second pass).
  const auto level = test_output::analyze_signal(sig, 48000, 1e9f);
  ASSERT_GT(level.peak, 0.02f) << "no signal reached the binaural output";
  const float step = test_output::sine_max_step(440.f, 48000.f, level.peak);
  const auto stats = test_output::analyze_signal(sig, 48000, 3.0f * step);
  EXPECT_EQ(stats.jumps, 0)
      << "max_jump=" << stats.max_jump << " peak=" << stats.peak;
  EXPECT_NEAR(stats.zc_per_sec, 880.0, 20.0);
}

// ES-88: layout switch mid-stream (stereo → 5.1 monitoring). The switch
// rebuilds OAR inside a fade-out/fade-in bracket; afterwards the
// render must resume as a clean sine on the new layout's channels,
// with the wider identity routing in effect.
TEST_F(AudioGraphTest, LayoutSwitchMidStreamOutputStaysClean) {
  const std::string sine_2ch = dir_ + "/graph_sine_2ch_48k_4s.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine_2ch, 2, 48000, 16, 440.f,
                                          4 * 48000, /*amplitude=*/0.25f));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_2ch,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  constexpr uint32_t kFrames = 512;
  const float step = test_output::sine_max_step(440.f, 48000.f, 0.25f);

  // Pre-switch: clean sine on the stereo target.
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames, 2);
  const auto pre = test_output::collect_channel(graph_, 45, kFrames, 2, 0);
  const auto pre_stats = test_output::analyze_signal(pre, 48000, 3.0f * step);
  ASSERT_GT(pre_stats.peak, 0.05f);
  ASSERT_EQ(pre_stats.jumps, 0) << "max_jump=" << pre_stats.max_jump;

  // Switch to 5.1 mid-stream; the device now runs 6 channels.
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayout51, 6));
  // Skip the post-rebuild fade-in (5 ms — inside the first block).
  test_output::run_blocks(graph_, 2, kFrames, 6);
  // Front-left carries the bed's L channel on the new layout.
  const auto post = test_output::collect_channel(graph_, 45, kFrames, 6, 0);
  const auto post_stats = test_output::analyze_signal(post, 48000, 3.0f * step);
  EXPECT_GT(post_stats.peak, 0.05f) << "no signal after the layout switch";
  EXPECT_EQ(post_stats.jumps, 0) << "max_jump=" << post_stats.max_jump;
  EXPECT_NEAR(post_stats.zc_per_sec, 880.0, 10.0);
}

TEST_F(AudioGraphTest, ResetMetersPreservingClipsKeepsLatches) {
  // ES-528: stopping playback resets the level meters but must keep the
  // sticky clip latches so overload markers survive a transport stop.
  // +12 dB on the near-full-scale sine pushes the element meter tap
  // well past 1.0 and trips the element latch; bypassing OAR (and its
  // limiter) routes the hot element straight to the output bus, so the
  // output latch trips too and both halves of the preserve are pinned.
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  graph_.set_element_gain(1, 12.0f);
  graph_.set_bypass_oar(true);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  // Let the gain ramp settle so the boosted signal crosses full scale.
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_EQ(static_cast<int>(state->elements[0].clip[0]), 1)
      << "fixture no longer clips";
  uint8_t out_clips[kChannels] = {};
  ASSERT_EQ(graph_.get_output_clips(out_clips, kChannels), kChannels);
  ASSERT_EQ(static_cast<int>(out_clips[0]), 1)
      << "bypassed output no longer clips";

  graph_.reset_meters(/*preserve_clips=*/true);
  EXPECT_FLOAT_EQ(state->elements[0].peak[0], 0.0f);
  EXPECT_FLOAT_EQ(state->elements[0].peak_hold[0], 0.0f);
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 1);
  ASSERT_EQ(graph_.get_output_clips(out_clips, kChannels), kChannels);
  EXPECT_EQ(static_cast<int>(out_clips[0]), 1);

  // The full reset still clears both latches.
  graph_.reset_meters();
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 0);
  ASSERT_EQ(graph_.get_output_clips(out_clips, kChannels), kChannels);
  EXPECT_EQ(static_cast<int>(out_clips[0]), 0);
}

TEST_F(AudioGraphTest, RemovedSlotDoesNotLeakMixExcludedToNextElement) {
  // A mix-excluded element is removed; its physical slot is later reused
  // by a freshly added element. The stale mix_excluded flag must not
  // survive the slot's reset — it would silence the new element via the
  // mute-gain path.
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  graph_.set_element_mix_excluded(1, true);
  graph_.remove_element(1);

  ASSERT_EQ(graph_.add_element(2, sine_.c_str()), 0);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  // Give a (wrongly) inherited exclusion time to ramp the mute gain
  // down, then measure: the new element must still meter as audible.
  RunBlocks(graph_, 30, out, kFrames, kChannels);
  graph_.reset_meters();
  RunBlocks(graph_, 1, out, kFrames, kChannels);
  EXPECT_GT(graph_.meter_state()->elements[0].peak[0], 0.01f);
}

TEST_F(AudioGraphTest, CompactionPreservesMixExcluded) {
  // Removing an element compacts the array by moving the last chain into
  // the vacated slot. The moved chain's mix_excluded state must move
  // with it — dropping it would unmute an excluded element.
  const std::string sine_2s = dir_ + "/graph_sine_1ch_48k_2s_excl.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_2s, 1, 48000, 16, 440.f, 2.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_2s.c_str()), 0);
  ASSERT_EQ(graph_.add_element(2, sine_2s.c_str()), 0);
  graph_.set_element_mix_excluded(2, true);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  // Let element 2's mute ramp settle, then compact: element 2 moves
  // into slot 0.
  RunBlocks(graph_, 30, out, kFrames, kChannels);
  graph_.remove_element(1);

  // If the exclusion was dropped in the move, the mute gain ramps back
  // up over ~145 ms and the element becomes audible again.
  RunBlocks(graph_, 30, out, kFrames, kChannels);
  graph_.reset_meters();
  RunBlocks(graph_, 1, out, kFrames, kChannels);
  EXPECT_LT(graph_.meter_state()->elements[0].peak[0], 0.001f);
}

TEST_F(AudioGraphTest, CompactionPreservesChannelCount) {
  // move_from() must carry wav_channels: the audio thread re-seats
  // buf.channels from it every callback, so a stale value from the
  // vacated slot corrupts the moved element's channel count.
  const std::string sine_4ch = dir_ + "/graph_sine_4ch_48k.wav";
  ASSERT_TRUE(test_wav::write_sine(sine_4ch, 4, 48000, 16, 440.f, 1.f));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);     // mono
  ASSERT_EQ(graph_.add_element(2, sine_4ch.c_str()), 0);  // 4-channel
  graph_.remove_element(1);  // element 2 moves into slot 0

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.process(out, kFrames, kChannels);

  const EclipsaStudioMeterState* state = graph_.meter_state();
  EXPECT_EQ(state->element_count, 1u);
  EXPECT_EQ(state->elements[0].channel_count, 4u);
  // All four channels carry the sine.
  EXPECT_GT(state->elements[0].peak[3], 0.0f);
}

TEST_F(AudioGraphTest, CompactionDoesNotLeakClipLatchToMovedElement) {
  // ES-531: meter slots are keyed by physical slot index, but compaction
  // only moved the chain — the element moved into the vacated slot
  // inherited the removed element's meter values, including the sticky
  // clip[] latch: a false overload marker on an element that never
  // clipped, surviving until the user tapped a meter.
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  ASSERT_EQ(graph_.add_element(2, sine_.c_str()), 0);
  graph_.set_element_gain(1, 12.0f);  // Only element 1 clips.

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_EQ(static_cast<int>(state->elements[0].clip[0]), 1)
      << "fixture no longer clips";
  ASSERT_EQ(static_cast<int>(state->elements[1].clip[0]), 0);

  graph_.remove_element(1);  // Element 2's chain moves into slot 0.

  // Element 2 must not inherit element 1's latch, and the vacated tail
  // slot must not keep the moved-from meter data either.
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 0);
  EXPECT_EQ(static_cast<int>(state->elements[1].clip[0]), 0);
  EXPECT_FLOAT_EQ(state->elements[1].peak[0], 0.0f);
}

TEST_F(AudioGraphTest, CompactionPreservesClipLatch) {
  // Converse of the leak test above: the moved element's OWN clip latch
  // must travel with its chain — dropping it in the move would clear a
  // real overload marker just because a sibling element was removed.
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  ASSERT_EQ(graph_.add_element(2, sine_.c_str()), 0);
  graph_.set_element_gain(2, 12.0f);  // Only element 2 clips.

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_EQ(static_cast<int>(state->elements[1].clip[0]), 1)
      << "fixture no longer clips";

  graph_.remove_element(1);  // Element 2's chain moves into slot 0.
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 1);
}

TEST_F(AudioGraphTest, RemoveLastElementClearsMeterSlot) {
  // The no-compaction branch (removing the tail element) must zero the
  // slot's meters too — add_element does not clear the slot it reuses,
  // so a stale latch would attach to the next element added there.
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);
  graph_.set_element_gain(1, 12.0f);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);
  const EclipsaStudioMeterState* state = graph_.meter_state();
  ASSERT_EQ(static_cast<int>(state->elements[0].clip[0]), 1)
      << "fixture no longer clips";

  graph_.remove_element(1);
  EXPECT_EQ(static_cast<int>(state->elements[0].clip[0]), 0);
  EXPECT_FLOAT_EQ(state->elements[0].peak[0], 0.0f);
  EXPECT_FLOAT_EQ(state->elements[0].peak_hold[0], 0.0f);
}

// Shared ES-530 exercise: seed the OAR pipeline with sine program, mimic
// the audio thread's paused branch (one drain call per "callback")
// while seeking back to the file's silent opening, then resume and
// return the first resumed blocks. The fixture file opens with a
// silent second, so a clean resume carries no energy at all.
std::vector<float> paused_seek_resume_signal(AudioGraph& graph,
                                             const std::string& dir,
                                             uint32_t layout,
                                             uint32_t layout_channels,
                                             const char* tag) {
  const int sr = 48000;
  std::vector<int16_t> pcm(static_cast<size_t>(sr) * 2, 0);
  // First second: silence. Second second: loud 440 Hz sine.
  for (int i = sr; i < sr * 2; ++i) {
    pcm[static_cast<size_t>(i)] = static_cast<int16_t>(std::lround(
        std::sin(2.0 * std::numbers::pi * 440.0 * (i - sr) / sr) * 24000.0));
  }
  const std::string wav = dir + "/graph_silence_then_sine_" + tag + ".wav";
  EXPECT_TRUE(test_wav::write_frames_s16(wav, 1, sr, pcm));

  graph.init(48000, 512, 2);
  EXPECT_TRUE(
      test_output::add_wav_element(graph, 1, wav, test_output::kLayoutMono, 1));
  EXPECT_TRUE(test_output::set_layout_identity(graph, layout, layout_channels));
  // The drain short-circuits when the limiter carries no delay; this
  // exercise only means something with the 5 ms delay line in play.
  EXPECT_GT(graph.oar_renderer()->limiter_delay(), 0u);

  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kChannels = 2;
  // Play inside the sine region so the pipeline holds program audio
  // (warmup covers the mute ramp + OAR fade-in).
  graph.seek(static_cast<uint64_t>(sr) + sr / 2);
  test_output::run_blocks(graph, test_output::kWarmupBlocks, kFrames,
                          kChannels);

  // "Stop": the audio thread's paused branch drains one block per
  // callback until the zero-fed output goes silent. Seek back to the
  // silent opening while paused — WAV seeks are staged (ES-536) and the
  // paused hook applies them without a fade, exactly as the real
  // paused branch does every callback.
  int paused_callbacks = 0;
  while (!graph.oar_tail_drained() && paused_callbacks < 4096) {
    graph.drain_oar_tail_paused();
    ++paused_callbacks;
  }
  EXPECT_TRUE(graph.oar_tail_drained())
      << "drain did not converge in " << paused_callbacks << " callbacks";
  std::printf("  [%s] drain converged after %d paused callback(s)\n", tag,
              paused_callbacks);
  graph.seek(0);
  graph.consume_pending_seek_paused();
  return test_output::collect_channel(graph, 4, kFrames, kChannels, 0);
}

TEST_F(AudioGraphTest, ResumeAfterPausedSeekDoesNotReplayStaleTail) {
  // ES-530: play → stop → seek to a silent position → play again must
  // not emit leftover pre-stop audio. Mechanism: the OAR limiter's
  // delay line (5 ms, the libiamf reference limiter) holds the
  // pre-stop program across the pause — the paused branch never
  // rendered OAR, so
  // nothing drained it, and the tail played as a burst at the head of
  // the resumed output.
  const auto sig = paused_seek_resume_signal(
      graph_, dir_, test_output::kLayoutStereo, 2, "stereo");

  // Position 0 opens a full second of silence, so every sample of the
  // resumed output must be silent; any energy is a stale-tail replay.
  // The failure message doubles as the burst measurement the issue
  // asks for (count / extent / peak).
  uint32_t nonzero = 0;
  uint32_t last_idx = 0;
  float peak = 0.0f;
  for (size_t i = 0; i < sig.size(); ++i) {
    if (std::fabs(sig[i]) > 1e-4f) {
      ++nonzero;
      last_idx = static_cast<uint32_t>(i);
      peak = std::max(peak, std::fabs(sig[i]));
    }
  }
  EXPECT_EQ(nonzero, 0u) << "stale burst: " << nonzero
                         << " samples audible, last at sample " << last_idx
                         << ", peak " << peak << " (limiter delay "
                         << graph_.oar_renderer()->limiter_delay()
                         << " frames)";

  // Positive control: the drain must not have broken playback itself —
  // seek into the sine region and program audio must return. Without
  // this, an implementation that muted the output forever would pass
  // the silence assertion above.
  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kChannels = 2;
  graph_.seek(48000 + 24000);
  test_output::run_blocks(graph_, 2, kFrames, kChannels);
  const auto program =
      test_output::collect_channel(graph_, 8, kFrames, kChannels, 0);
  const auto stats = test_output::analyze_signal(program, 48000, 1.0f);
  EXPECT_GT(stats.peak, 0.05f) << "program did not resume after the drain";
}

TEST_F(AudioGraphTest, WavSeekWhilePlayingFadesTheSplice) {
  // ES-536: a manual playhead move during WAV playback used to
  // hard-splice old program to new — an audible click, the last
  // unfaded transport edge. Staged seeks now run the ES-473 machinery:
  // ~10 ms fade-out, one held block, ~10 ms fade-in. Pin it at the
  // output: seeking from the sine region into the silent region must
  // ramp down without any per-sample jump beyond what the fade and the
  // sine itself can produce, and seeking back must bring program
  // audio back (the fade-in half).
  const int sr = 48000;
  std::vector<int16_t> pcm(static_cast<size_t>(sr) * 2, 0);
  for (int i = sr; i < sr * 2; ++i) {
    pcm[static_cast<size_t>(i)] = static_cast<int16_t>(std::lround(
        std::sin(2.0 * std::numbers::pi * 440.0 * (i - sr) / sr) * 16000.0));
  }
  const std::string wav = dir_ + "/graph_seek_fade.wav";
  ASSERT_TRUE(test_wav::write_frames_s16(wav, 1, sr, pcm));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, wav,
                                           test_output::kLayoutMono, 1));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  constexpr uint32_t kFrames = 512;
  constexpr uint32_t kChannels = 2;
  graph_.seek(static_cast<uint64_t>(sr) + sr / 2);
  graph_.consume_pending_seek_paused();  // Position before "play".
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);

  // Seek to the silent opening MID-PLAYBACK (no paused hook) and
  // collect across the splice: fade-out block, held block, then
  // silence from position 0.
  graph_.seek(0);
  const auto splice =
      test_output::collect_channel(graph_, 6, kFrames, kChannels, 0);

  // No hard step anywhere: the largest per-sample move is bounded by
  // the sine's own slope plus the fade ramp's per-sample step scaled
  // by the amplitude. A butt-joint splice jumps by up to ~2×amplitude
  // (~0.9 here); allow a small multiple of the legitimate bound.
  const float amp = 16000.0f / 32768.0f;
  const float sine_step = test_output::sine_max_step(440.f, 48000.f, amp);
  const float fade_step =
      amp / (0.010f * 48000.0f);  // kSeekFadeSeconds worth of ramp
  const auto stats =
      test_output::analyze_signal(splice, sr, sine_step + 4.0f * fade_step);
  EXPECT_EQ(stats.jumps, 0)
      << "splice discontinuity: max_jump=" << stats.max_jump;
  // Positive control: the fade-out block genuinely carried the old
  // program — an implementation that muted everything would pass the
  // jump and tail assertions alone.
  EXPECT_GT(stats.peak, 0.05f) << "no program audio reached the splice";
  // The tail of the collection is genuinely silent program.
  float tail_peak = 0.0f;
  for (size_t i = splice.size() - kFrames; i < splice.size(); ++i) {
    tail_peak = std::max(tail_peak, std::fabs(splice[i]));
  }
  EXPECT_LT(tail_peak, 1e-4f) << "seek did not land in the silent region";

  // Fade-in half: seek back into the sine region while still
  // "playing"; program audio must return within a few blocks.
  graph_.seek(static_cast<uint64_t>(sr) + sr / 2);
  test_output::run_blocks(graph_, 4, kFrames, kChannels);
  const auto back =
      test_output::collect_channel(graph_, 4, kFrames, kChannels, 0);
  float back_peak = 0.0f;
  for (const float s : back) back_peak = std::max(back_peak, std::fabs(s));
  EXPECT_GT(back_peak, 0.05f) << "program did not return after seeking back";
}

// ES-836: a WAV element's ring is filled by the disk thread, so right
// after a seek it still holds frames from the old position. A resume
// straight after a paused seek, before the disk thread has applied it,
// must hold the element muted rather than play those frames. The file
// is silent for its first second and a sine after it; the element plays
// the sine, seeks while paused into the silence, and resumes at once.
TEST_F(AudioGraphTest, ResumeRightAfterPausedWavSeekPlaysNoStaleFrames) {
  const int sr = 48000;
  std::vector<int16_t> pcm(static_cast<size_t>(sr) * 2, 0);
  for (int i = sr; i < sr * 2; ++i) {
    pcm[static_cast<size_t>(i)] = static_cast<int16_t>(std::lround(
        std::sin(2.0 * std::numbers::pi * 440.0 * (i - sr) / sr) * 16000.0));
  }
  const std::string wav = dir_ + "/graph_paused_seek_stale.wav";
  ASSERT_TRUE(test_wav::write_frames_s16(wav, 1, sr, pcm));

  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, wav.c_str()), 0);
  constexpr uint32_t kFrames = 512, kChannels = 2;
  std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);

  graph_.seek(static_cast<uint64_t>(sr) + sr / 4);
  graph_.consume_pending_seek_paused();
  RunBlocks(graph_, 8, out.data(), kFrames, kChannels);
  ASSERT_GT(graph_.meter_state()->elements[0].peak[0], 0.1f);

  // Paused seek into the silence, then resume with no wait: every block
  // reads silence or is held muted, never the sine left in the ring.
  graph_.seek(0);
  graph_.consume_pending_seek_paused();
  for (int i = 0; i < 16; ++i) {
    graph_.process(out.data(), kFrames, kChannels);
    EXPECT_LT(graph_.meter_state()->elements[0].peak[0], 1e-4f)
        << "block " << i;
  }
}

// ── Joining the program (ES-986) ───────────────────────────────────────────

// Two elements play the same mono file with OAR bypassed, so each
// element's channels 0 and 1 reach output channels 0 and 1 unchanged.
// Element 1 plays on channel 0; element 2's input routing sends the file
// to channel 1. The file is noise, so neighbouring frames differ by
// about 0.3 on average: the two channels match sample for sample only
// when both elements read the same file frame. The match allows 1e-4,
// because a joined element's mute gain settles at 0.99997 rather than
// 1.0 (dsp::Gain's one-pole ramp stops when its step rounds away in
// float32).
class JoinTest : public AudioGraphTest {
 protected:
  static constexpr uint32_t kFrames = 512;
  static constexpr uint32_t kChannels = 2;
  // kJoinLeadSeconds (0.17 s) at 48 kHz, rounded up to 512-frame blocks.
  static constexpr int kLeadBlocks = 16;

  void SetUp() override {
    AudioGraphTest::SetUp();
    noise_ = dir_ + "/graph_join_noise.wav";
    ASSERT_TRUE(WriteNoise(noise_, 48000, 300000));
    graph_.init(48000, kFrames, kChannels);
    graph_.set_bypass_oar(true);
    out_.assign(static_cast<size_t>(kFrames) * kChannels, 0.0f);
  }

  // Mono float32 noise in [-0.5, 0.5), the same sequence every time.
  static bool WriteNoise(const std::string& path, int rate, uint32_t frames) {
    std::vector<float> samples(frames);
    uint32_t x = 12345;
    for (float& v : samples) {
      x = x * 1664525u + 1013904223u;
      v = static_cast<float>(x >> 8) / 16777216.0f - 0.5f;
    }
    return test_wav::write_float32_frames(path, 1, rate, samples);
  }

  // Adds element `id` from `path`; with `on_channel_1` its input routing
  // sends the file to output channel 1 and leaves channel 0 silent.
  void Add(uint32_t id, const std::string& path, bool on_channel_1) {
    ASSERT_EQ(graph_.add_element(id, path.c_str()), 0);
    if (on_channel_1) {
      const int8_t map[2] = {-1, 0};
      graph_.set_element_routing(id, map, 2);
    }
  }

  // Element 1 on channel 0, playing from file frame 24000.
  void StartFirstElement(const std::string& path) {
    ASSERT_NO_FATAL_FAILURE(Add(1, path, /*on_channel_1=*/false));
    graph_.seek(24000);
    graph_.consume_pending_seek_paused();
    Run(10);
  }

  void Run(int blocks, uint32_t frames = kFrames) {
    RunBlocks(graph_, blocks, out_.data(), frames, kChannels);
  }

  float Out(uint32_t ch, uint32_t f) const {
    return out_[static_cast<size_t>(f) * kChannels + ch];
  }

  // Element 1 on channel 0 from file frame 24000, element 2 on channel
  // 1 joined and in step with it.
  void StartBothElements() {
    ASSERT_NO_FATAL_FAILURE(StartFirstElement(noise_));
    ASSERT_NO_FATAL_FAILURE(Add(2, noise_, /*on_channel_1=*/true));
    Run(kLeadBlocks + 48);
    ASSERT_NO_FATAL_FAILURE(ExpectInStep());
  }

  // Stalls or releases element `id`'s disk-thread stream.
  void Stall(uint32_t id, bool stalled) {
    ASSERT_NO_FATAL_FAILURE(
        AudioGraphTestPeer::StallWavStream(graph_, id, stalled));
  }

  // The last block's channels 0 and 1 carry the same samples within
  // `tolerance`, and channel 0 carries the program.
  void ExpectInStep(float tolerance = 1e-4f, uint32_t frames = kFrames) {
    float diff = 0.0f;
    float peak = 0.0f;
    for (uint32_t f = 0; f < frames; ++f) {
      diff = std::max(diff, std::fabs(Out(1, f) - Out(0, f)));
      peak = std::max(peak, std::fabs(Out(0, f)));
    }
    EXPECT_GT(peak, 0.1f);
    EXPECT_LT(diff, tolerance);
  }

  std::string noise_;
  std::vector<float> out_;
};

// An element added while the program plays is silent for the join lead,
// fades in from silence, and then plays in step with the element
// already playing.
TEST_F(JoinTest, ElementAddedDuringPlaybackPlaysInStep) {
  ASSERT_NO_FATAL_FAILURE(StartFirstElement(noise_));
  ASSERT_NO_FATAL_FAILURE(Add(2, noise_, /*on_channel_1=*/true));
  for (int b = 0; b < kLeadBlocks; ++b) {
    Run(1);
    for (uint32_t f = 0; f < kFrames; ++f) {
      ASSERT_EQ(Out(1, f), 0.0f) << "block " << b << " frame " << f;
    }
  }
  // Fading in: never louder than the playing element, never opposite in
  // sign.
  for (int b = 0; b < 8; ++b) {
    Run(1);
    for (uint32_t f = 0; f < kFrames; ++f) {
      ASSERT_LE(std::fabs(Out(1, f)), std::fabs(Out(0, f)) + 1e-6f);
      ASSERT_GE(Out(1, f) * Out(0, f), 0.0f) << "block " << b;
    }
  }
  Run(40);
  ExpectInStep();
}

// A seek while the new element is still joining moves it with the
// others, and it plays in step from the seek target.
TEST_F(JoinTest, SeekDuringAJoinMovesTheJoiningElement) {
  ASSERT_NO_FATAL_FAILURE(StartFirstElement(noise_));
  ASSERT_NO_FATAL_FAILURE(Add(2, noise_, /*on_channel_1=*/true));
  Run(2);
  graph_.seek(72000);
  Run(60);
  ExpectInStep();
}

// An element added while paused follows the seek the app sends on play,
// like the elements already there.
TEST_F(JoinTest, ElementAddedWhilePausedFollowsTheSeekOnPlay) {
  ASSERT_NO_FATAL_FAILURE(StartFirstElement(noise_));
  ASSERT_NO_FATAL_FAILURE(Add(2, noise_, /*on_channel_1=*/true));
  graph_.seek(48000);
  graph_.consume_pending_seek_paused();
  Run(40);
  ExpectInStep();
}

// An element added while a seek holds the program joins that hold and
// comes in with the others when it ends, without a further lead.
TEST_F(JoinTest, ElementAddedDuringASeekHoldJoinsTheHold) {
  ASSERT_NO_FATAL_FAILURE(StartFirstElement(noise_));
  graph_.seek(48000);
  Run(2);  // The fade-out block, then the block that posts the seek.
  ASSERT_NO_FATAL_FAILURE(Add(2, noise_, /*on_channel_1=*/true));
  // Element 2's mute gain was never snapped, so the two match exactly,
  // through the seek's fade-in too.
  Run(3);
  ExpectInStep(1e-6f);
}

// A 44.1 kHz element joining a 48 kHz graph lands within half a file
// frame of a 44.1 kHz element already playing: the join rounds its
// target to a whole file frame, as a seek does, while the playing
// element's resampler carries a fractional position. The file is a
// 100 Hz sine at amplitude 0.5, so half a file frame differs by up to
// 3.6e-3 and one engine frame by up to 6.5e-3.
TEST_F(JoinTest, ResampledElementJoinsInStep) {
  const std::string sine = dir_ + "/graph_join_sine_441.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine, 1, 44100, 16, 100.f, 2 * 44100,
                                          /*amplitude=*/0.5f));
  ASSERT_NO_FATAL_FAILURE(StartFirstElement(sine));
  ASSERT_NO_FATAL_FAILURE(Add(2, sine, /*on_channel_1=*/true));
  Run(1);
  for (uint32_t f = 0; f < kFrames; ++f) ASSERT_EQ(Out(1, f), 0.0f);
  Run(60);
  ExpectInStep(4.5e-3f);
}

// A join whose frame the program passes, because the block size changed
// to one that does not divide the distance, joins again and plays in
// step.
TEST_F(JoinTest, JoinAgainAfterTheBlockSizeChanges) {
  ASSERT_NO_FATAL_FAILURE(StartFirstElement(noise_));
  ASSERT_NO_FATAL_FAILURE(Add(2, noise_, /*on_channel_1=*/true));
  Run(1);
  constexpr uint32_t kOddFrames = 441;
  Run(80, kOddFrames);
  ExpectInStep(1e-4f, kOddFrames);
}

// An element whose disk-thread stream stalls for longer than its ring
// (32768 frames) underruns and falls behind the program by the length
// of the starvation. It joins the program again once the stream
// recovers, and plays in step with the other element.
TEST_F(JoinTest, ElementStarvedLongerThanTheRingJoinsAgain) {
  ASSERT_NO_FATAL_FAILURE(StartBothElements());
  const uint64_t underruns_before = graph_.meter_state()->ring_underrun_count;
  ASSERT_NO_FATAL_FAILURE(Stall(2, true));
  // 96 blocks: the ring drains after at most 64, and the element is
  // starved for the rest.
  Run(96);
  EXPECT_GT(graph_.meter_state()->ring_underrun_count, underruns_before);
  for (uint32_t f = 0; f < kFrames; ++f) ASSERT_EQ(Out(1, f), 0.0f);
  ASSERT_NO_FATAL_FAILURE(Stall(2, false));
  Run(120);
  ExpectInStep();
}

// A seek while an element's stream is stalled: the hold's watchdog gives
// up after 250 ms with the element's seek still unapplied. Once the
// stream recovers, the element joins the program again instead of
// playing from the seek target behind it.
TEST_F(JoinTest, SeekUnappliedWhenTheHoldEndsJoinsAgain) {
  ASSERT_NO_FATAL_FAILURE(StartBothElements());
  ASSERT_NO_FATAL_FAILURE(Stall(2, true));
  graph_.seek(96000);
  // The fade-out block, the block that posts the seek, and the hold
  // until its watchdog gives up (250 ms, 24 blocks).
  Run(30);
  for (uint32_t f = 0; f < kFrames; ++f) ASSERT_EQ(Out(1, f), 0.0f);
  ASSERT_NO_FATAL_FAILURE(Stall(2, false));
  Run(120);
  ExpectInStep();
}

TEST_F(AudioGraphTest, BinauralResumeAfterPausedSeekDecaysBelowAudibility) {
  // ES-530 (review finding): binaural rendering is a convolution, so a
  // zero-fed render emits a decaying reverb tail instead of going
  // silent in one block — the drain must be free to run across many
  // paused callbacks, and a resume-at-silence must land below
  // audibility. A resume-time flush bounded to a few blocks left a
  // -31 dBFS wash across the whole first resumed block here.
  const auto sig = paused_seek_resume_signal(
      graph_, dir_, test_output::kLayoutBinaural, 2, "binaural");

  float peak = 0.0f;
  for (const float s : sig) peak = std::max(peak, std::fabs(s));
  // -80 dBFS: comfortably below audibility for program material.
  EXPECT_LT(peak, 1e-4f) << "resumed binaural output carries "
                         << 20.0 * std::log10(peak) << " dBFS of residue";
}

TEST_F(AudioGraphTest, GainChangeAffectsMeterPeak) {
  graph_.init(48000, 512, 2);
  ASSERT_EQ(graph_.add_element(1, sine_.c_str()), 0);

  constexpr uint32_t kFrames = 512, kChannels = 2;
  float out[kFrames * kChannels] = {};
  graph_.process(out, kFrames, kChannels);

  // Record meter peak at unity gain.
  float peak_unity = graph_.meter_state()->elements[0].peak[0];

  // Seek back and set -60 dB gain (near silence).
  graph_.seek(0);
  graph_.reset_meters();
  graph_.set_element_gain(1, -60.0f);

  graph_.process(out, kFrames, kChannels);
  float peak_quiet = graph_.meter_state()->elements[0].peak[0];

  EXPECT_GT(peak_unity, peak_quiet);
}

}  // namespace

// ES-629 monitor DIM: a -20 dB cut on the device buffer applied after the
// render and every meter tap. The rendered level drops by 20 dB, the
// output meters keep reading the undimmed render, neither edge clicks,
// and release restores the level.
TEST_F(AudioGraphTest, MonitorDimCutsOutputBy20dBAfterTheMeterTap) {
  const std::string sine_2ch = dir_ + "/graph_sine_2ch_48k_4s.wav";
  ASSERT_TRUE(test_wav::write_sine_frames(sine_2ch, 2, 48000, 16, 440.f,
                                          4 * 48000, /*amplitude=*/0.25f));

  graph_.init(48000, 512, 2);
  ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_2ch,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(
      test_output::set_layout_identity(graph_, test_output::kLayoutStereo, 2));

  constexpr uint32_t kFrames = 512, kChannels = 2;
  constexpr float kJump = 0.08f;
  test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                          kChannels);

  const auto undimmed = test_output::analyze_signal(
      test_output::collect_channel(graph_, 20, kFrames, kChannels, 0), 48000,
      kJump);
  ASSERT_GT(undimmed.peak, 0.05f) << "no signal reached the output";
  float meter_undimmed[2] = {};
  ASSERT_EQ(graph_.get_output_peaks(meter_undimmed, 2), 2u);

  // Engage. The 15 ms ramp spans two 512-frame blocks at 48 kHz;
  // collect across the edge and require no discontinuity.
  graph_.set_monitor_dim(true);
  EXPECT_TRUE(graph_.monitor_dim());
  const auto engage = test_output::analyze_signal(
      test_output::collect_channel(graph_, 4, kFrames, kChannels, 0), 48000,
      kJump);
  EXPECT_EQ(engage.jumps, 0) << "engage clicked, max_jump=" << engage.max_jump;

  const auto dimmed = test_output::analyze_signal(
      test_output::collect_channel(graph_, 20, kFrames, kChannels, 0), 48000,
      kJump);
  const float depth_db = 20.f * std::log10(dimmed.peak / undimmed.peak);
  EXPECT_NEAR(depth_db, -20.f, 0.3f);
  float meter_dimmed[2] = {};
  ASSERT_EQ(graph_.get_output_peaks(meter_dimmed, 2), 2u);
  EXPECT_NEAR(meter_dimmed[0], meter_undimmed[0], 0.01f)
      << "the output meter must read the undimmed render";

  // Release: no click, and the level comes back.
  graph_.set_monitor_dim(false);
  const auto release = test_output::analyze_signal(
      test_output::collect_channel(graph_, 4, kFrames, kChannels, 0), 48000,
      kJump);
  EXPECT_EQ(release.jumps, 0)
      << "release clicked, max_jump=" << release.max_jump;
  const auto restored = test_output::analyze_signal(
      test_output::collect_channel(graph_, 20, kFrames, kChannels, 0), 48000,
      kJump);
  EXPECT_NEAR(restored.peak, undimmed.peak, 0.01f);
}

namespace {

// ES-999 output-channel solo and mute. The test element is the same sine
// on both channels and the stereo render keeps them equal, so while one
// channel plays at unity the ratio of the other to it is that channel's
// solo/mute gain at each frame.
class OutputSoloMuteTest : public AudioGraphTest {
 protected:
  static constexpr uint32_t kFrames = 512, kChannels = 2;
  // 15 ms at 48 kHz.
  static constexpr float kRampFrames = 720.0f;

  void SetUp() override {
    AudioGraphTest::SetUp();
    const std::string sine_2ch = dir_ + "/graph_sine_2ch_48k_4s.wav";
    ASSERT_TRUE(test_wav::write_sine_frames(sine_2ch, 2, 48000, 16, 440.f,
                                            4 * 48000, /*amplitude=*/0.25f));
    graph_.init(48000, kFrames, kChannels);
    ASSERT_TRUE(test_output::add_wav_element(graph_, 1, sine_2ch,
                                             test_output::kLayoutStereo, 2));
    ASSERT_TRUE(test_output::set_layout_identity(
        graph_, test_output::kLayoutStereo, 2));
    test_output::run_blocks(graph_, test_output::kWarmupBlocks, kFrames,
                            kChannels);
  }

  // One block of the interleaved device output.
  std::vector<float> Block() {
    std::vector<float> out(static_cast<size_t>(kFrames) * kChannels, 0.0f);
    EXPECT_TRUE(graph_.wait_for_wav_streams(kFrames));
    graph_.process(out.data(), kFrames, kChannels);
    return out;
  }

  // Peak of device channel `ch` over `blocks` blocks.
  float Peak(int blocks, uint32_t ch) {
    return test_output::analyze_signal(
               test_output::collect_channel(graph_, blocks, kFrames, kChannels,
                                            ch),
               48000, /*jump_threshold=*/1.0f)
        .peak;
  }

  // Requires channel `ramped` to follow the 15 ms linear ramp relative to
  // channel `unity` over `out`, whose first frame is `first` frames after
  // the change: gain 1 - (f + 1) / 720 down, (f + 1) / 720 up.
  void ExpectRamp(const std::vector<float>& out, uint32_t unity,
                  uint32_t ramped, uint32_t first, bool down) {
    int checked = 0;
    for (uint32_t f = 0; f < kFrames; ++f) {
      const float ref = out[f * kChannels + unity];
      if (std::fabs(ref) < 0.01f) continue;
      const float t =
          std::min(1.0f, static_cast<float>(first + f + 1) / kRampFrames);
      ASSERT_NEAR(out[f * kChannels + ramped] / ref, down ? 1.0f - t : t, 2e-3f)
          << "frame " << first + f << " after the change";
      ++checked;
    }
    EXPECT_GT(checked, 200);
  }
};

// A mute ramps the channel to silence over 15 ms and holds it there, the
// other channel keeps its level, the output meters keep reading the
// render, and clearing it ramps the channel back up.
TEST_F(OutputSoloMuteTest, MuteRampsAChannelOutAfterTheMeterTap) {
  const float full0 = Peak(20, 0);
  const float full1 = Peak(20, 1);
  ASSERT_GT(full0, 0.05f) << "no signal reached the output";
  ASSERT_NEAR(full1, full0, 0.01f);
  float meter_full[2] = {};
  ASSERT_EQ(graph_.get_output_peaks(meter_full, 2), 2u);

  graph_.set_output_solo_mute(/*soloed=*/0, /*muted=*/1ull << 1);
  EXPECT_EQ(graph_.output_silenced(), 1ull << 1);
  ExpectRamp(Block(), /*unity=*/0, /*ramped=*/1, /*first=*/0, true);
  ExpectRamp(Block(), 0, 1, kFrames, true);
  EXPECT_EQ(Peak(20, 1), 0.0f);
  EXPECT_NEAR(Peak(20, 0), full0, 0.01f);
  float meter_muted[2] = {};
  ASSERT_EQ(graph_.get_output_peaks(meter_muted, 2), 2u);
  EXPECT_NEAR(meter_muted[1], meter_full[1], 0.01f)
      << "the output meter must read the render without the cut";

  graph_.set_output_solo_mute(0, 0);
  EXPECT_EQ(graph_.output_silenced(), 0u);
  ExpectRamp(Block(), 0, 1, 0, /*down=*/false);
  ExpectRamp(Block(), 0, 1, kFrames, /*down=*/false);
  EXPECT_NEAR(Peak(20, 1), full1, 0.01f);
}

// A solo silences every channel that is not soloed, and mute wins over
// solo.
TEST_F(OutputSoloMuteTest, SoloSilencesTheOtherChannels) {
  const float full1 = Peak(20, 1);
  ASSERT_GT(full1, 0.05f) << "no signal reached the output";

  graph_.set_output_solo_mute(/*soloed=*/1ull << 1, /*muted=*/0);
  EXPECT_EQ(graph_.output_silenced() & 0x3u, 1ull << 0);
  ExpectRamp(Block(), /*unity=*/1, /*ramped=*/0, /*first=*/0, true);
  ExpectRamp(Block(), 1, 0, kFrames, true);
  EXPECT_EQ(Peak(20, 0), 0.0f);
  EXPECT_NEAR(Peak(20, 1), full1, 0.01f);

  graph_.set_output_solo_mute(/*soloed=*/1ull << 1, /*muted=*/1ull << 1);
  EXPECT_EQ(graph_.output_silenced() & 0x3u, 0x3u);
  Block();
  Block();
  EXPECT_EQ(Peak(20, 1), 0.0f);
  EXPECT_EQ(Peak(20, 0), 0.0f);
}

// A change made while no program reaches the device is complete at the
// next program block: settle_output_solo_mute(), which the paused branch
// of the audio callback calls, and a calibration-noise block both set
// the gain at once, so a muted channel is silent from its first frame.
TEST_F(OutputSoloMuteTest, ChangeWithoutProgramHoldsFromTheFirstBlock) {
  graph_.set_output_solo_mute(/*soloed=*/0, /*muted=*/1ull << 1);
  graph_.settle_output_solo_mute();
  auto out = Block();
  float peak0 = 0.0f;
  for (uint32_t f = 0; f < kFrames; ++f) {
    peak0 = std::max(peak0, std::fabs(out[f * kChannels + 0]));
    ASSERT_EQ(out[f * kChannels + 1], 0.0f) << "frame " << f;
  }
  EXPECT_GT(peak0, 0.05f);

  graph_.set_output_solo_mute(0, 0);
  graph_.settle_output_solo_mute();
  out = Block();
  for (uint32_t f = 0; f < kFrames; ++f) {
    ASSERT_NEAR(out[f * kChannels + 1], out[f * kChannels + 0], 1e-6f)
        << "frame " << f;
  }

  // Muted under calibration noise, which carries no program.
  graph_.set_noise(/*row=*/1, /*channel=*/0, /*amp=*/0.1f);
  graph_.set_output_solo_mute(0, 1ull << 1);
  Block();
  graph_.set_noise(/*off=*/0, 0, 0.0f);
  out = Block();
  for (uint32_t f = 0; f < kFrames; ++f) {
    ASSERT_EQ(out[f * kChannels + 1], 0.0f) << "frame " << f;
  }
}

}  // namespace
