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

// Drift-killer for the OAR capability mapping (issue ES-330).
//
// Asserts the invariant *valid ⇒ renderable*: every audio-element shape
// expressible in an IAMF v1.x file — all non-reserved coded channel
// layouts (including Binaural and every Expanded sub-layout) and
// mono-mode ambisonics orders 0–4 — maps to an OAR element sub-renderer.
// This is the test that would have caught ES-326 (Binaural missing), the
// 7.1 / 7.1.2 / 3.1.2 blocks, and the fictitious 3OA cap before they
// shipped.

#include "renderer/oar_capability.h"

#include <cstdint>

#include "gtest/gtest.h"
#include "oar.h"

namespace {

TEST(OarCapability, EveryValidCodedChannelLayoutIsRenderable) {
  // Coded loudspeaker_layout 0–9: Mono, Stereo, 5.1, 5.1.2, 5.1.4, 7.1,
  // 7.1.2, 7.1.4, 3.1.2, Binaural.
  const int kExpectedSubType[] = {
      ck_oar_layout_mono,
      ck_oar_layout_stereo,
      ck_oar_layout_51,
      ck_oar_layout_512,
      ck_oar_layout_514,
      ck_oar_layout_71,
      ck_oar_layout_712,
      ck_oar_layout_714,
      ck_oar_layout_312,
      // Binaural bed registers as a stereo element (authoring-path
      // parity; see oar_capability.h).
      ck_oar_layout_stereo,
  };
  for (int32_t raw = 0; raw <= 9; ++raw) {
    const auto sub = OarSubTypeForCodedChannelLayout(raw, -1);
    ASSERT_TRUE(sub.has_value()) << "coded layout " << raw;
    EXPECT_EQ(*sub, kExpectedSubType[raw]) << "coded layout " << raw;
  }
}

TEST(OarCapability, EveryExpandedSubLayoutIsRenderable) {
  // Coded expanded_loudspeaker_layout 0–19, under loudspeaker_layout 15.
  const int kExpectedSubType[] = {
      ck_oar_layout_lfe,       ck_oar_layout_stereo_s,
      ck_oar_layout_stereo_ss, ck_oar_layout_stereo_rs,
      ck_oar_layout_stereo_tf, ck_oar_layout_stereo_tb,
      ck_oar_layout_top_4ch,   ck_oar_layout_3ch,
      ck_oar_layout_916,       ck_oar_layout_stereo_f,
      ck_oar_layout_stereo_si, ck_oar_layout_stereo_tpsi,
      ck_oar_layout_top_6ch,   ck_oar_layout_a293,
      ck_oar_layout_lfe_pair,  ck_oar_layout_bottom_3ch,
      ck_oar_layout_7154,      ck_oar_layout_bottom_4ch,
      ck_oar_layout_top_1ch,   ck_oar_layout_top_5ch,
  };
  for (int32_t expanded = 0; expanded <= 19; ++expanded) {
    const auto sub = OarSubTypeForCodedChannelLayout(15, expanded);
    ASSERT_TRUE(sub.has_value()) << "expanded layout " << expanded;
    EXPECT_EQ(*sub, kExpectedSubType[expanded])
        << "expanded layout " << expanded;
  }
}

TEST(OarCapability, ReservedLayoutsAreNotRenderable) {
  for (int32_t raw = 10; raw <= 14; ++raw) {
    EXPECT_FALSE(OarSubTypeForCodedChannelLayout(raw, -1).has_value())
        << "reserved layout " << raw;
  }
  EXPECT_FALSE(OarSubTypeForCodedChannelLayout(15, 20).has_value());
  EXPECT_FALSE(OarSubTypeForCodedChannelLayout(15, -1).has_value());
  EXPECT_FALSE(OarSubTypeForCodedChannelLayout(-1, -1).has_value());
  EXPECT_FALSE(OarSubTypeForCodedChannelLayout(16, -1).has_value());
}

TEST(OarCapability, AmbisonicsOrdersZeroThroughFourAreRenderable) {
  // The full range expressible in v1.x profiles: 5OA needs 36 channels,
  // Base-Enhanced caps an AE at 28.
  for (int32_t order = 0; order <= 4; ++order) {
    const auto sub = OarSubTypeForAmbisonicsOrder(order);
    ASSERT_TRUE(sub.has_value()) << "order " << order;
    EXPECT_EQ(*sub, order);
  }
  EXPECT_FALSE(OarSubTypeForAmbisonicsOrder(-1).has_value());
  EXPECT_FALSE(OarSubTypeForAmbisonicsOrder(5).has_value());
}

TEST(OarCapability, ElementDispatchMatchesKind) {
  // Channel kind consults the coded layout pair.
  EXPECT_EQ(OarSubTypeForElement(0, 1, -1, -1), ck_oar_layout_stereo);
  // Scene kind consults the ambisonics order.
  EXPECT_EQ(OarSubTypeForElement(1, -1, -1, 3), ck_oar_3oa);
  // Object and unknown kinds are never renderable.
  EXPECT_FALSE(OarSubTypeForElement(2, 1, -1, -1).has_value());
  EXPECT_FALSE(OarSubTypeForElement(-1, 1, -1, -1).has_value());
  EXPECT_FALSE(OarSubTypeForElement(3, 1, -1, -1).has_value());
}

}  // namespace
