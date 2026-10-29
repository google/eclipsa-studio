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

// Output continuity across OAR rebuilds during playback (ES-987). A
// rebuild waits for the audio thread to fade the output out and to
// acknowledge, so the graph tests run process() on a second thread,
// standing in for the device callback, and record channel 0 of every
// block: the buffer the audio thread hands to the device. Three tests
// replay the engine calls the app makes for a Creator mix switch, a
// Playback mix switch and an element added during playback, in the
// app's order.
//
// A new OAR instance's first 240 output samples at 48 kHz are the
// limiter look-ahead's zeros. The graph ramps the instance's input up
// from silence over 10 ms, so the program reaches the output as a ramp.
// Without that ramp the program reached the output part-way through the
// output fade-in: at 512-frame blocks, at an output gain of 0.47.
//
// The element plays a 375 Hz cosine at amplitude 0.5. Its period of 128
// samples divides the 512-frame block, and the program reads whole
// blocks during a rebuild, so every block starts at the cosine's peak
// and the step where the program reaches the output is the same in
// every run.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <numbers>
#include <string>
#include <thread>
#include <vector>

#include "graph/audio_graph.h"
#include "gtest/gtest.h"
#include "meters/meter_state.h"
#include "renderer/channel_order.h"
#include "renderer/oar_renderer.h"
#include "test/test_output_helper.h"
#include "test/test_wav_helper.h"

// Befriended by OarRenderer: sets its create-failure test seam.
class OarRendererTestPeer {
 public:
  static void SetFailCreate(bool fail) {
    OarRenderer::fail_create_for_testing_.store(fail,
                                                std::memory_order_relaxed);
  }
};

namespace {

constexpr uint32_t kFrames = 512;
constexpr uint32_t kChannels = 2;
constexpr uint32_t kRate = 48000;
constexpr float kAmp = 0.5f;
constexpr float kFreq = 375.0f;
constexpr int kFileSeconds = 30;
// 26.7 s at 48 kHz: the loop stops before the file ends.
constexpr int kMaxBlocks = 2500;

// Runs graph->process() on its own thread, one block every 2 ms (about
// five times real time), and records channel 0 of each block, until it
// is destroyed or kMaxBlocks have run. The WAV disk thread wakes at
// least every 2 ms and keeps the element's 32768-frame ring (682 ms)
// filled; TearDown() checks that no read came up short.
class RecordingLoop {
 public:
  explicit RecordingLoop(AudioGraph* graph)
      : graph_(graph),
        recording_(static_cast<size_t>(kMaxBlocks) * kFrames, 0.0f) {
    // As when the device starts: the loudness fence then waits for the
    // audio thread's acknowledgement.
    graph_->set_audio_running(true);
    thread_ = std::thread([this] { Run(); });
  }
  RecordingLoop(const RecordingLoop&) = delete;
  RecordingLoop& operator=(const RecordingLoop&) = delete;
  ~RecordingLoop() {
    stop_.store(true, std::memory_order_relaxed);
    thread_.join();
    graph_->set_audio_running(false);
  }

  int blocks() const { return blocks_.load(std::memory_order_acquire); }

  // Waits until `block` blocks have run. Fails at once for a block past
  // kMaxBlocks, which the loop never reaches.
  bool WaitForBlock(int block) const {
    if (block > kMaxBlocks) {
      ADD_FAILURE() << "block " << block << " is past kMaxBlocks";
      return false;
    }
    while (blocks() < block) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
  }

  // Samples of blocks [first, last). Call after WaitForBlock(last).
  std::vector<float> Samples(int first, int last) const {
    return {recording_.begin() + static_cast<std::ptrdiff_t>(first) * kFrames,
            recording_.begin() + static_cast<std::ptrdiff_t>(last) * kFrames};
  }

 private:
  void Run() {
    std::vector<float> out(static_cast<size_t>(kFrames) * kChannels);
    for (int b = 0; b < kMaxBlocks && !stop_.load(std::memory_order_relaxed);
         ++b) {
      graph_->process(out.data(), kFrames, kChannels);
      for (uint32_t f = 0; f < kFrames; ++f) {
        recording_[static_cast<size_t>(b) * kFrames + f] = out[f * kChannels];
      }
      blocks_.store(b + 1, std::memory_order_release);
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
  }

  AudioGraph* graph_;
  std::vector<float> recording_;
  std::atomic<bool> stop_{false};
  std::atomic<int> blocks_{0};
  std::thread thread_;
};

// Writes a stereo WAV of kFileSeconds of the kFreq cosine at
// `amplitude` on both channels.
bool WriteCosine(const std::string& path, float amplitude) {
  std::vector<int16_t> pcm(static_cast<size_t>(kRate) * kFileSeconds * 2);
  for (size_t i = 0; i < pcm.size() / 2; ++i) {
    const auto s = static_cast<int16_t>(
        std::lround(amplitude * 32767.0 *
                    std::cos(2.0 * std::numbers::pi * kFreq *
                             static_cast<double>(i) / kRate)));
    pcm[2 * i] = s;
    pcm[2 * i + 1] = s;
  }
  return test_wav::write_frames_s16(path, 2, kRate, pcm);
}

class AudioGraphRebuildFadeTest : public ::testing::Test {
 protected:
  void SetUp() override {
    const std::string wav = test_wav::temp_dir() + "/rebuild_fade_cosine.wav";
    ASSERT_TRUE(WriteCosine(wav, kAmp));
    // Heap-allocated: AudioGraph pre-allocates several MB of element
    // buffers, too large for the stack.
    graph_ = std::make_unique<AudioGraph>();
    ASSERT_TRUE(graph_->init(kRate, kFrames, kChannels));
    ASSERT_TRUE(test_output::add_wav_element(*graph_, 1, wav,
                                             test_output::kLayoutStereo, 2));
    ASSERT_TRUE(test_output::set_layout_identity(
        *graph_, test_output::kLayoutStereo, kChannels));
    ASSERT_TRUE(graph_->wait_for_wav_streams(kFrames));
  }

  void TearDown() override {
    // A short read would put a step in the recording of its own.
    EXPECT_EQ(static_cast<uint64_t>(graph_->meter_state()->ring_underrun_count),
              0u);
  }

  // Commits a rendering-config change for element 1, which rebuilds the
  // OAR instance, and checks that it did.
  void RebuildWithConfig(uint32_t mode, uint32_t profile) {
    OarRenderer* oar = graph_->oar_renderer();
    const uint32_t generation = oar->instance_generation();
    ASSERT_TRUE(oar->set_element_rendering_config(1, mode, profile));
    ASSERT_TRUE(oar->commit_rendering_config());
    EXPECT_EQ(oar->instance_generation(), generation + 1);
  }

  // One element's settings in a Creator mix (MixElementSettings).
  struct MixSettings {
    uint32_t id;
    bool included;
    float gain_db;
    uint32_t headphones_mode;
  };

  // The calls _pushActiveMixSettings() (app/lib/widgets/app_shell.dart)
  // makes when the active mix changes, through the functions its FFI
  // calls reach.
  void PushCreatorMix(const std::vector<MixSettings>& mix) {
    OarRenderer* oar = graph_->oar_renderer();
    for (const MixSettings& s : mix) {
      graph_->set_element_mix_excluded(s.id, !s.included);
      graph_->set_element_mix_gain(s.id, s.gain_db);
      ASSERT_TRUE(oar->set_element_rendering_config(s.id, s.headphones_mode,
                                                    /*profile=*/0));
    }
    ASSERT_TRUE(oar->commit_rendering_config());
    graph_->resync_loudness_meter_if_stale();
    graph_->set_output_mix_gain(0.0f);
  }

  // The calls _applyMixToEngine() (app/lib/playback/playback_session.dart)
  // makes on a switch to a mix presentation that is not the file's
  // default, for a mix that keeps element 1 at 0 dB with its rendering
  // config unchanged.
  void ApplyPlaybackMix() {
    OarRenderer* oar = graph_->oar_renderer();
    ASSERT_TRUE(graph_->set_monitoring_layout(test_output::kLayoutStereo));
    graph_->set_iamf_stream_gains(false);
    graph_->set_element_mix_gain(1, 0.0f);
    graph_->set_element_mix_excluded(1, false);
    graph_->set_output_mix_gain(0.0f);
    ASSERT_TRUE(oar->set_element_rendering_config(1, /*mode=*/1,
                                                  /*profile=*/0));
    ASSERT_TRUE(oar->commit_rendering_config());
    graph_->resync_loudness_meter_if_stale();
  }

  // The calls _syncElementToEngine() (app/lib/views/elements_view.dart)
  // makes for a new stereo element, through the functions its FFI calls
  // reach.
  void AddStereoElement(uint32_t id, const std::string& wav) {
    OarRenderer* oar = graph_->oar_renderer();
    ASSERT_EQ(graph_->add_element(id, wav.c_str()), 0);
    graph_->set_element_scene(id, false);
    graph_->set_element_object(id, false);
    ASSERT_TRUE(oar->add_element(id, /*type=*/0, test_output::kLayoutStereo,
                                 /*channels=*/2));
    graph_->resync_loudness_meter_if_stale();
    graph_->set_element_channel_order(id, eclipsa_studio::kChannelOrderOar);
    ASSERT_TRUE(oar->commit_rendering_config());
    graph_->resync_loudness_meter_if_stale();
    graph_->set_element_gain(id, 0.0f);
    graph_->set_element_mute(id, false);
    graph_->set_element_solo(id, false);
    graph_->set_element_routing(id, nullptr, 0);
  }

  std::unique_ptr<AudioGraph> graph_;
};

// Largest |x[i] - x[i-1]| over the signal.
float MaxStep(const std::vector<float>& signal) {
  float max_step = 0.0f;
  for (size_t i = 1; i < signal.size(); ++i) {
    max_step = std::max(max_step, std::fabs(signal[i] - signal[i - 1]));
  }
  return max_step;
}

float Peak(const std::vector<float>& signal) {
  float peak = 0.0f;
  for (const float s : signal) peak = std::max(peak, std::fabs(s));
  return peak;
}

// Each check below brackets a control call with the block counts read
// before it (`pre`) and after it returns (`post`). The new instance
// renders from block `post` on, however long the rebuild took, so the
// step window is [pre - 2, post + 30) and the settled window is
// [post + 30, post + 60).

// A rendering-config commit during playback rebuilds the instance. On
// the stereo layout the output is the cosine itself, so no per-sample
// step may exceed its own slope plus a few steps of the 10 ms input
// fade.
TEST_F(AudioGraphRebuildFadeTest, RebuildDuringPlaybackHasNoStep) {
  RecordingLoop loop(graph_.get());
  ASSERT_TRUE(loop.WaitForBlock(40));
  const int pre = loop.blocks();
  ASSERT_NO_FATAL_FAILURE(RebuildWithConfig(/*mode=*/0, /*profile=*/0));
  const int post = loop.blocks();
  ASSERT_TRUE(loop.WaitForBlock(post + 60));

  const float cosine_step = test_output::sine_max_step(kFreq, kRate, kAmp);
  const float fade_step = kAmp / (0.010f * kRate);
  // Without the input fade the step measured 0.23.
  EXPECT_LE(MaxStep(loop.Samples(pre - 2, post + 30)),
            cosine_step + 4.0f * fade_step);
  // The program came back after the rebuild.
  EXPECT_GT(Peak(loop.Samples(post + 30, post + 60)), 0.9f * kAmp);
}

// The monitoring target switches Creator makes through
// set_layout_and_routing() (the monitoring config listener in
// app/lib/widgets/app_shell.dart), from stereo to binaural and back,
// and a filter-profile commit on binaural, where the new instance also
// starts with empty convolution state. The binaural render is not the
// plain cosine, so its bound is the rendered signal's own largest step
// once the rebuild has settled, with a 1.5x margin. Without the input
// fade the step measured 0.18 on the switch to binaural, 0.17 on the
// commit and 0.23 on the switch back to stereo, against bounds of
// 0.042, 0.064 and 0.064.
TEST_F(AudioGraphRebuildFadeTest, LayoutSwitchesAndBinauralCommitHaveNoStep) {
  RecordingLoop loop(graph_.get());
  ASSERT_TRUE(loop.WaitForBlock(40));
  int pre = loop.blocks();
  ASSERT_TRUE(test_output::set_layout_identity(
      *graph_, test_output::kLayoutBinaural, kChannels));
  int post = loop.blocks();
  ASSERT_TRUE(loop.WaitForBlock(post + 60));
  const float switch_settled = MaxStep(loop.Samples(post + 30, post + 60));
  EXPECT_LE(MaxStep(loop.Samples(pre - 2, post + 30)), 1.5f * switch_settled);

  pre = loop.blocks();
  ASSERT_NO_FATAL_FAILURE(RebuildWithConfig(/*mode=*/1, /*profile=*/2));
  post = loop.blocks();
  ASSERT_TRUE(loop.WaitForBlock(post + 60));
  const std::vector<float> settled = loop.Samples(post + 30, post + 60);
  EXPECT_LE(MaxStep(loop.Samples(pre - 2, post + 30)),
            1.5f * std::max(switch_settled, MaxStep(settled)));
  EXPECT_GT(Peak(settled), 0.1f);

  pre = loop.blocks();
  ASSERT_TRUE(test_output::set_layout_identity(
      *graph_, test_output::kLayoutStereo, kChannels));
  post = loop.blocks();
  ASSERT_TRUE(loop.WaitForBlock(post + 60));
  const float cosine_step = test_output::sine_max_step(kFreq, kRate, kAmp);
  const float fade_step = kAmp / (0.010f * kRate);
  EXPECT_LE(MaxStep(loop.Samples(pre - 2, post + 30)),
            std::max(1.5f * MaxStep(settled), cosine_step + 4.0f * fade_step));
  EXPECT_GT(Peak(loop.Samples(post + 30, post + 60)), 0.9f * kAmp);
}

// A Creator mix switch whose mixes give element 2 different headphones
// rendering modes, so the commit rebuilds the instance. Element 1 plays
// the cosine at amplitude 0.5 and element 2 at 0.25, in phase. Mix A
// has element 1 at 0 dB and excludes element 2; mix B has element 1 at
// -6 dB and includes element 2, so both mixes settle at amplitude 0.5.
// The exclusion and gain changes ramp over about 145 ms, so the bound
// is the larger settled step with a 1.5x margin, 0.037. Without the
// input fade the step measured 0.19 on the switch to B and 0.28 on the
// switch back.
TEST_F(AudioGraphRebuildFadeTest, CreatorMixSwitchHasNoStep) {
  const std::string quiet = test_wav::temp_dir() + "/rebuild_fade_quiet.wav";
  ASSERT_TRUE(WriteCosine(quiet, kAmp / 2.0f));
  ASSERT_TRUE(test_output::add_wav_element(*graph_, 2, quiet,
                                           test_output::kLayoutStereo, 2));
  ASSERT_TRUE(graph_->wait_for_wav_streams(kFrames));
  const std::vector<MixSettings> mix_a = {{1, true, 0.0f, 1},
                                          {2, false, 0.0f, 1}};
  const std::vector<MixSettings> mix_b = {{1, true, -6.0f, 1},
                                          {2, true, 0.0f, 0}};
  ASSERT_NO_FATAL_FAILURE(PushCreatorMix(mix_a));

  RecordingLoop loop(graph_.get());
  ASSERT_TRUE(loop.WaitForBlock(60));
  float settled_before = MaxStep(loop.Samples(30, 60));
  for (const auto* mix : {&mix_b, &mix_a}) {
    const uint32_t generation = graph_->oar_renderer()->instance_generation();
    const int pre = loop.blocks();
    ASSERT_NO_FATAL_FAILURE(PushCreatorMix(*mix));
    const int post = loop.blocks();
    EXPECT_EQ(graph_->oar_renderer()->instance_generation(), generation + 1);
    ASSERT_TRUE(loop.WaitForBlock(post + 60));
    const std::vector<float> settled = loop.Samples(post + 30, post + 60);
    const float settled_after = MaxStep(settled);
    EXPECT_LE(MaxStep(loop.Samples(pre - 2, post + 30)),
              1.5f * std::max(settled_before, settled_after));
    EXPECT_GT(Peak(settled), 0.9f * kAmp);
    settled_before = settled_after;
  }
}

// A Playback mix-presentation switch sets the monitoring layout the
// instance already renders. It keeps the instance, so the output has
// no gap.
TEST_F(AudioGraphRebuildFadeTest, PlaybackMixSwitchKeepsTheInstance) {
  RecordingLoop loop(graph_.get());
  ASSERT_TRUE(loop.WaitForBlock(40));
  const uint32_t generation = graph_->oar_renderer()->instance_generation();
  const int pre = loop.blocks();
  ASSERT_NO_FATAL_FAILURE(ApplyPlaybackMix());
  EXPECT_EQ(graph_->oar_renderer()->instance_generation(), generation);
  ASSERT_TRUE(loop.WaitForBlock(pre + 20));
  for (int b = pre; b < pre + 20; ++b) {
    EXPECT_GT(Peak(loop.Samples(b, b + 1)), 0.9f * kAmp) << "block " << b;
  }
}

// An element added during playback rebuilds the instance when its type
// is set. Element 1 plays the cosine at amplitude 0.5; element 2, at
// 0.25, joins at the playhead (ES-986) and ramps in, after which the two
// play in phase at amplitude 0.75. The join waits for the disk thread
// and takes longer when the ring is not primed in time, so the settled
// window starts 300 blocks after the call. Without the input fade the
// step measured 0.23 against a bound of 0.055.
TEST_F(AudioGraphRebuildFadeTest, ElementAddedDuringPlaybackHasNoStep) {
  const std::string quiet = test_wav::temp_dir() + "/rebuild_fade_quiet.wav";
  ASSERT_TRUE(WriteCosine(quiet, kAmp / 2.0f));
  RecordingLoop loop(graph_.get());
  ASSERT_TRUE(loop.WaitForBlock(60));
  const float settled_before = MaxStep(loop.Samples(30, 60));
  const uint32_t generation = graph_->oar_renderer()->instance_generation();
  const int pre = loop.blocks();
  ASSERT_NO_FATAL_FAILURE(AddStereoElement(2, quiet));
  const int post = loop.blocks();
  EXPECT_EQ(graph_->oar_renderer()->instance_generation(), generation + 1);
  ASSERT_TRUE(loop.WaitForBlock(post + 330));
  const std::vector<float> settled = loop.Samples(post + 300, post + 330);
  EXPECT_LE(MaxStep(loop.Samples(pre - 2, post + 300)),
            1.5f * std::max(settled_before, MaxStep(settled)));
  EXPECT_GT(Peak(settled), 0.9f * 1.5f * kAmp);
}

// A set_layout() call that finds no instance, because the last create
// failed, builds one even when the layout is unchanged.
TEST(OarRendererSetLayoutTest, SameLayoutAfterAFailedCreateRebuilds) {
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.init(kRate, kFrames, test_output::kLayoutStereo));
  OarRendererTestPeer::SetFailCreate(true);
  const bool failed_switch = r.set_layout(test_output::kLayout714);
  OarRendererTestPeer::SetFailCreate(false);
  EXPECT_FALSE(failed_switch);
  EXPECT_EQ(r.channel_count(), 0u);

  const uint32_t generation = r.instance_generation();
  EXPECT_TRUE(r.set_layout(test_output::kLayout714));
  EXPECT_EQ(r.instance_generation(), generation + 1);
  EXPECT_EQ(r.channel_count(), 12u);
}

// While offline-exclusive mode is held a layout switch is deferred.
// Setting the same layout again keeps the deferral, and the exit builds
// that layout.
TEST(OarRendererSetLayoutTest, SameLayoutWhileOfflineExclusiveIsDeferred) {
  OarRenderer r;
  r.set_no_audio_thread();
  ASSERT_TRUE(r.init(kRate, kFrames, test_output::kLayoutStereo));
  r.begin_offline_exclusive();
  EXPECT_TRUE(r.set_layout(test_output::kLayout714));
  EXPECT_TRUE(r.set_layout(test_output::kLayout714));
  EXPECT_EQ(r.channel_count(), 2u);
  EXPECT_TRUE(r.end_offline_exclusive());
  EXPECT_EQ(r.channel_count(), 12u);
}

}  // namespace
