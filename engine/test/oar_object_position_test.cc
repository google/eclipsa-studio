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

// Object-based elements and loudspeaker layouts: OAR's object-to-
// loudspeaker renderer (OLR) creates its per-object processing only
// when position metadata arrives, so an object element that never
// receives a position renders silence on every speaker layout. The
// engine's audio thread therefore pushes the element's polar position
// every callback (AudioGraph::process). These tests pin both halves at
// the OarRenderer level: silence before any position push (the
// regression — Object · Mono was inaudible on stereo monitoring), and
// audible output once positions flow.

#include <cmath>
#include <cstdint>
#include <vector>

#include "gtest/gtest.h"
#include "renderer/oar_renderer.h"

namespace {

constexpr uint32_t kRate = 48000;
constexpr uint32_t kFrames = 512;
constexpr uint32_t kStereoLayout = 2;  // oar_layout_t: stereo

float peak_abs(const float* data, uint32_t samples) {
  float peak = 0.0f;
  for (uint32_t i = 0; i < samples; ++i) {
    peak = std::max(peak, std::fabs(data[i]));
  }
  return peak;
}

std::vector<float> sine_block(float amplitude) {
  std::vector<float> block(kFrames);
  for (uint32_t f = 0; f < kFrames; ++f) {
    block[f] = amplitude * std::sin(2.0f * 3.14159265f * 1000.0f *
                                    static_cast<float>(f) / kRate);
  }
  return block;
}

TEST(OarObjectPositionTest, MonoObjectSilentOnStereoWithoutPositions) {
  OarRenderer r;
  ASSERT_TRUE(r.init(kRate, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(/*element_id=*/1, /*type=object*/ 2,
                            /*sub_type=num_objects*/ 1, /*channels=*/1));
  ASSERT_EQ(r.channel_count(), 2u);

  const std::vector<float> sine = sine_block(0.5f);

  // Without any position metadata OLR has no processing channel for
  // the object, so the render stays exactly silent — the bug this
  // test pins (Object · Mono inaudible on stereo monitoring).
  //
  // Note there is no recovery assertion here on purpose: OLR keeps its
  // position timeline in lockstep with its render offset, so positions
  // that START arriving only after position-less renders on the same
  // instance never catch up (verified while writing this test). That
  // is why AudioGraph::process pushes positions BEFORE render() from
  // the very first callback of every OAR instance — the state this
  // test renders is unreachable in the product, and the audible path
  // is covered by the tests below.
  float pre_peak = 0.0f;
  for (int block = 0; block < 4; ++block) {
    r.update_element_data(1, sine.data(), 1, kFrames, kFrames);
    const float* out = r.render(kFrames);
    ASSERT_NE(out, nullptr);
    pre_peak = std::max(pre_peak, peak_abs(out, 2 * kFrames));
  }
  EXPECT_EQ(pre_peak, 0.0f) << "object rendered audio with no position "
                               "metadata — OLR behavior changed; the "
                               "per-callback push may be removable";
}

TEST(OarObjectPositionTest, MonoObjectAudibleWhenPositionedFromFirstBlock) {
  OarRenderer r;
  ASSERT_TRUE(r.init(kRate, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=object*/ 2, 1, 1));

  const std::vector<float> sine = sine_block(0.5f);

  // Push a front-center position each block before rendering — the
  // exact sequence the audio thread performs — and the object is
  // audible on both stereo channels.
  const float az = 0.0f;
  const float el = 0.0f;
  const float dist = 1.0f;
  float left_peak = 0.0f;
  float right_peak = 0.0f;
  for (int block = 0; block < 8; ++block) {
    r.set_element_object_positions(1, 1, &az, &el, &dist, kFrames);
    r.update_element_data(1, sine.data(), 1, kFrames, kFrames);
    const float* out = r.render(kFrames);
    ASSERT_NE(out, nullptr);
    left_peak = std::max(left_peak, peak_abs(out, kFrames));
    right_peak = std::max(right_peak, peak_abs(out + kFrames, kFrames));
  }
  EXPECT_GT(left_peak, 0.01f);
  EXPECT_GT(right_peak, 0.01f);
}

TEST(OarObjectPositionTest, HardLeftPositionFavorsLeftChannel) {
  OarRenderer r;
  ASSERT_TRUE(r.init(kRate, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=object*/ 2, 1, 1));

  const std::vector<float> sine = sine_block(0.5f);

  // +90° azimuth in the IAMF/OAR polar convention is hard left (the
  // angle grows counter-clockwise from front-center). If this ever
  // fails with the channels swapped, the app-side azimuth sign is
  // wrong, not this plumbing.
  const float az = 90.0f;
  const float el = 0.0f;
  const float dist = 1.0f;
  float left_peak = 0.0f;
  float right_peak = 0.0f;
  for (int block = 0; block < 8; ++block) {
    r.set_element_object_positions(1, 1, &az, &el, &dist, kFrames);
    r.update_element_data(1, sine.data(), 1, kFrames, kFrames);
    const float* out = r.render(kFrames);
    ASSERT_NE(out, nullptr);
    left_peak = std::max(left_peak, peak_abs(out, kFrames));
    right_peak = std::max(right_peak, peak_abs(out + kFrames, kFrames));
  }
  EXPECT_GT(left_peak, 0.01f);
  EXPECT_GT(left_peak, right_peak * 4.0f)
      << "hard-left object should render dominantly to the left channel";
}

TEST(OarObjectPositionTest, DualObjectRendersBothPositions) {
  OarRenderer r;
  ASSERT_TRUE(r.init(kRate, kFrames, kStereoLayout));
  ASSERT_TRUE(r.add_element(1, /*type=object*/ 2, /*num_objects*/ 2,
                            /*channels=*/2));

  // Two planar channels: object 0 carries the sine, object 1 silence.
  std::vector<float> data(2 * kFrames, 0.0f);
  const std::vector<float> sine = sine_block(0.5f);
  std::copy(sine.begin(), sine.end(), data.begin());

  const float az[2] = {90.0f, -90.0f};
  const float el[2] = {0.0f, 0.0f};
  const float dist[2] = {1.0f, 1.0f};
  float peak = 0.0f;
  for (int block = 0; block < 8; ++block) {
    r.set_element_object_positions(1, 2, az, el, dist, kFrames);
    r.update_element_data(1, data.data(), 2, kFrames, kFrames);
    const float* out = r.render(kFrames);
    ASSERT_NE(out, nullptr);
    peak = std::max(peak, peak_abs(out, 2 * kFrames));
  }
  EXPECT_GT(peak, 0.01f);
}

}  // namespace
