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

// Equivalence canary for the cartesian->polar conversion path (ES-567).
//
// Eclipsa Studio never passes cartesian-typed position metadata into an
// oar_t: its meaning depends on the fork-only conversion mode, so against
// upstream oar it would silently render differently instead of failing.
// All production conversion instead goes through the fork's public helper
// (oar_position_anchors_create + oar_cartesian_to_polar), and OAR is fed
// polar only. This test is the ONE deliberate exception: it drives the
// in-renderer cartesian path and the helper-then-polar path over the same
// moving object and asserts bit-identical output, pinning the fork's
// equivalence promise on every oar pin bump (the drift-killer pattern of
// oar_limiter_thd_test).

#include <cstdint>
#include <cstring>
#include <vector>

#include "gtest/gtest.h"

extern "C" {
#include "oar.h"
}

namespace {

constexpr uint32_t kBlock = 512;
constexpr uint32_t kBlocks = 32;
constexpr uint32_t kRate = 48000;
constexpr uint32_t kElemId = 1;

oar_t* MakeOar(uint32_t* num_out) {
  oar_config_t cfg = {};
  cfg.target_layout = ck_oar_layout_714;
  cfg.samples_per_channel = kBlock;
  cfg.sampling_rate = kRate;
  oar_t* oar = oar_create(&cfg);
  if (oar == nullptr) return nullptr;
  const int gid = oar_add_audio_group(oar);
  oar_audio_element_config_t ecfg;
  std::memset(&ecfg, 0, sizeof(ecfg));
  ecfg.type = ck_object_based;
  ecfg.obc.num_objects = 1;
  if (gid < 0 || oar_add_audio_element(oar, static_cast<uint32_t>(gid), kElemId,
                                       &ecfg) != 0) {
    oar_destroy(oar);
    return nullptr;
  }
  *num_out = oar_get_number_of_output_channels(oar);
  return oar;
}

// The block's cube position: a diagonal sweep front-left-top toward
// rear-right-bottom, crossing walls, the interior, and both height signs.
cartesian_t PosAt(uint32_t block) {
  const float t = static_cast<float>(block) / (kBlocks - 1);
  return {-1.0f + 2.0f * t, 1.0f - 2.0f * t, 1.0f - 1.5f * t};
}

TEST(OarCartConversionCanary, InRendererCartesianEqualsHelperThenPolar) {
  uint32_t num_out_a = 0;
  uint32_t num_out_b = 0;
  oar_t* cart = MakeOar(&num_out_a);   // Fed ck_cartesian, layout mode.
  oar_t* polar = MakeOar(&num_out_b);  // Fed pre-converted ck_polar.
  ASSERT_NE(cart, nullptr);
  ASSERT_NE(polar, nullptr);
  ASSERT_EQ(num_out_a, num_out_b);
  ASSERT_EQ(oar_set_position_conversion(cart, ck_oar_pos_conv_layout), 0);

  oar_position_anchors_t* anchors =
      oar_position_anchors_create(ck_oar_layout_714);
  ASSERT_NE(anchors, nullptr);

  std::vector<float> in(kBlock, 0.25f);
  std::vector<float> out_a(static_cast<size_t>(num_out_a) * kBlock);
  std::vector<float> out_b(out_a.size());

  for (uint32_t block = 0; block < kBlocks; ++block) {
    const cartesian_t pos = PosAt(block);

    oar_audio_block_t ib = {in.data(), 1, kBlock};
    ASSERT_EQ(oar_update_audio_element_data(cart, kElemId, &ib), 0);
    ASSERT_EQ(oar_update_audio_element_data(polar, kElemId, &ib), 0);

    oar_metadata_t md;
    std::memset(&md, 0, sizeof(md));
    md.type = ck_metadata_object_positions;
    md.duration = static_cast<int>(kBlock);
    md.object_positions.param_type = ck_param_constant;
    md.object_positions.num_objects = 1;

    md.object_positions.position_type = ck_cartesian;
    md.object_positions.cartesian_positions[0] = pos;
    ASSERT_EQ(oar_update_audio_element_metadata(cart, kElemId, &md), 0);

    md.object_positions.position_type = ck_polar;
    md.object_positions.polar_positions[0] =
        oar_cartesian_to_polar(anchors, ck_oar_pos_conv_layout, pos);
    ASSERT_EQ(oar_update_audio_element_metadata(polar, kElemId, &md), 0);

    oar_audio_block_t ob_a = {out_a.data(), num_out_a, kBlock};
    oar_audio_block_t ob_b = {out_b.data(), num_out_b, kBlock};
    ASSERT_EQ(oar_render(cart, &ob_a), 0);
    ASSERT_EQ(oar_render(polar, &ob_b), 0);

    for (size_t i = 0; i < out_a.size(); ++i) {
      ASSERT_EQ(out_a[i], out_b[i]) << "block=" << block << " i=" << i;
    }
  }

  oar_position_anchors_destroy(anchors);
  oar_destroy(cart);
  oar_destroy(polar);
}

}  // namespace
