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

// The OAR calls the audio thread makes each block must not allocate,
// from the first block after the renderer is built. Each test builds an
// OarRenderer and runs kBlocks blocks of the playing sequence of
// AudioGraph::process: for every element a mix-gain push, a position
// push for an object element and the PCM feed, then the output mix-gain
// push, render() and snapshot_limiter_env(). It then runs kBlocks blocks
// the way AudioGraph::drain_oar_tail_paused renders while paused: a zero
// feed for every element and render(), with no metadata pushes.
//
// Allocations are counted through the sanitizer malloc hooks
// (test/alloc_counter.h), so the tests run in the asan and tsan builds
// and are skipped in the others.
// tsan on macOS does not call the hooks for posix_memalign() and
// aligned_alloc(); nothing on this path calls them, and asan counts
// them. Each run first makes one allocation of its own and requires the
// hook to count it, so a hook that installs but is not called does not
// pass. The last playing block must hold signal, so a render that fails
// without allocating does not pass.

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"
#include "test/alloc_counter.h"

extern "C" {
#include "oar.h"
}

namespace {

constexpr uint32_t kRate = 48000;
constexpr uint32_t kFrames = 512;
constexpr int kBlocks = 32;

struct Element {
  uint32_t id;
  int type;      // 0 channel-based, 1 scene-based, 2 object-based.
  int sub_type;  // oar_layout_t, oar_hoa_t or the object count.
  uint32_t channels;
};

struct RunResult {
  uint64_t allocations = 0;
  // The hook counted the run's probe allocation.
  bool probe_counted = false;
  // The last playing block's output has a sample above -60 dBFS.
  bool audible = false;
};

// Builds the renderer with every element in `headphones_mode`, then
// counts the allocations of kBlocks playing blocks and kBlocks paused
// drain blocks.
RunResult Run(
    uint32_t layout, const std::vector<Element>& elements,
    oar_headphones_rendering_mode_t headphones_mode = ck_world_locked) {
  RunResult result;
  OarRenderer oar;
  oar.set_no_audio_thread();
  EXPECT_TRUE(oar.init(kRate, kFrames, layout));
  for (const Element& e : elements) {
    EXPECT_TRUE(oar.add_element(e.id, e.type, e.sub_type, e.channels));
    EXPECT_TRUE(oar.set_element_rendering_config(e.id, headphones_mode,
                                                 /*profile=*/0));
  }
  EXPECT_TRUE(oar.commit_rendering_config());

  std::vector<std::vector<float>> pcm;
  for (const Element& e : elements) {
    pcm.emplace_back(static_cast<size_t>(e.channels) * kFrames, 0.1f);
  }
  const std::vector<float> zeros(static_cast<size_t>(16) * kFrames, 0.0f);

  result.probe_counted = alloc_counter::Start();
  const float* out = nullptr;
  for (int b = 0; b < kBlocks; ++b) {
    for (size_t i = 0; i < elements.size(); ++i) {
      const Element& e = elements[i];
      oar.set_element_mix_gain(e.id, -1.0f, -1.0f, kFrames);
      if (e.type == 2) {
        const float az[2] = {-90.0f + 2.0f * b, 90.0f - 2.0f * b};
        const float el[2] = {10.0f, 30.0f};
        const float dist[2] = {1.0f, 0.5f};
        oar.set_element_object_positions(
            e.id, static_cast<uint32_t>(e.sub_type), az, el, dist, kFrames);
      }
      oar.update_element_data(e.id, pcm[i].data(), e.channels, kFrames,
                              kFrames);
    }
    oar.set_output_mix_gain(0.0f, 0.0f, kFrames);
    out = oar.render(kFrames);
    oar.snapshot_limiter_env();
  }
  if (out != nullptr) {
    const uint32_t samples = oar.channel_count() * kFrames;
    for (uint32_t k = 0; k < samples && !result.audible; ++k) {
      result.audible = std::fabs(out[k]) > 0.001f;
    }
  }
  for (int b = 0; b < kBlocks; ++b) {
    for (const Element& e : elements) {
      oar.update_element_data(e.id, zeros.data(), e.channels, kFrames, kFrames);
    }
    oar.render(kFrames);
  }
  result.allocations = alloc_counter::Stop();
  return result;
}

void ExpectNoAllocations(
    uint32_t layout, const std::vector<Element>& elements,
    oar_headphones_rendering_mode_t headphones_mode = ck_world_locked) {
  const RunResult r = Run(layout, elements, headphones_mode);
  EXPECT_TRUE(r.probe_counted);
  EXPECT_EQ(r.allocations, 0u);
  EXPECT_TRUE(r.audible);
}

class OarRenderAllocTest : public ::testing::Test {
 protected:
  void SetUp() override {
    if (!alloc_counter::kAvailable) {
      GTEST_SKIP() << "allocation counts need an asan or tsan build";
    }
  }
};

constexpr Element kBed714{1, 0, ck_oar_layout_714, 12};
constexpr Element kScene3oa{2, 1, ck_oar_3oa, 16};
constexpr Element kObject{3, 2, 1, 1};
constexpr Element kObjectPair{4, 2, 2, 2};

TEST_F(OarRenderAllocTest, ChannelBedOnLoudspeakers) {
  ExpectNoAllocations(ck_oar_layout_stereo, {kBed714});
  ExpectNoAllocations(ck_oar_layout_714, {kBed714});
}

TEST_F(OarRenderAllocTest, SceneOnLoudspeakers) {
  ExpectNoAllocations(ck_oar_layout_stereo, {kScene3oa});
  ExpectNoAllocations(ck_oar_layout_714, {kScene3oa});
}

TEST_F(OarRenderAllocTest, BedAndSceneTogetherOnLoudspeakers) {
  ExpectNoAllocations(ck_oar_layout_714, {kBed714, kScene3oa});
}

TEST_F(OarRenderAllocTest, ObjectsOnLoudspeakers) {
  const std::vector<Element> objects = {kObject, {5, 2, 1, 1}, kObjectPair};
  ExpectNoAllocations(ck_oar_layout_stereo, objects);
  ExpectNoAllocations(ck_oar_layout_714, objects);
  ExpectNoAllocations(ck_oar_layout_916, objects);
}

TEST_F(OarRenderAllocTest, BedSceneAndObjectsOnLoudspeakers) {
  ExpectNoAllocations(ck_oar_layout_714, {kBed714, kScene3oa, kObject});
}

TEST_F(OarRenderAllocTest, BinauralWorldLocked) {
  ExpectNoAllocations(ck_oar_layout_binaural, {kBed714});
  ExpectNoAllocations(ck_oar_layout_binaural, {kScene3oa});
  ExpectNoAllocations(ck_oar_layout_binaural,
                      {kBed714, kScene3oa, kObject, kObjectPair});
}

TEST_F(OarRenderAllocTest, BinauralHeadLocked) {
  ExpectNoAllocations(ck_oar_layout_binaural,
                      {kBed714, kScene3oa, kObject, kObjectPair},
                      ck_head_locked);
}

// ck_world_locked_restricted renders a channel-based element to stereo
// without OBR.
TEST_F(OarRenderAllocTest, BinauralStereoFallback) {
  ExpectNoAllocations(ck_oar_layout_binaural, {kBed714},
                      ck_world_locked_restricted);
}

}  // namespace
