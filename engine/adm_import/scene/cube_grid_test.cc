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

#include "adm_import/scene/cube_grid.h"

#include <algorithm>
#include <cmath>
#include <set>
#include <string>

#include "gtest/gtest.h"

namespace adm2iamf {
namespace {

TEST(CubeGrid, TableCoversAllTable1BSlots) {
  // BS.2094-2 Table 1B defines 32 slots (29 speakers incl. the two
  // screen-edge slots, plus LFE/LFE1/LFE2).
  EXPECT_EQ(AllCubeSlots().size(), 32u);
  std::set<std::string> labels;
  for (const CubeSlot& s : AllCubeSlots()) {
    labels.insert(std::string(s.label));
  }
  EXPECT_EQ(labels.size(), 32u) << "duplicate labels";
  // Spot-check presence across layers.
  for (const char* l : {"M_FL", "M_BL50", "U_BC67", "B_FR", "LFE2", "M_FLSc",
                        "U_TC", "M_FSL67"}) {
    EXPECT_NE(CubeSlotByLabel(l), nullptr) << l;
  }
  EXPECT_EQ(CubeSlotByLabel("RC_L"), nullptr);
  EXPECT_EQ(CubeSlotByLabel("M+030"), nullptr);
}

TEST(CubeGrid, DistinctSlotsAreChebyshevSeparated) {
  // The classifier tolerance (0.15) must be under half the minimum
  // separation between distinct non-screen slot positions.
  const auto slots = AllCubeSlots();
  for (const CubeSlot& a : slots) {
    for (const CubeSlot& b : slots) {
      if (&a == &b || a.screen || b.screen) continue;
      const float d = std::max(
          {std::abs(a.x - b.x), std::abs(a.y - b.y), std::abs(a.z - b.z)});
      if (d == 0.0f) {
        // Only the LFE/bottom-front coincidences may collide.
        EXPECT_TRUE(a.is_lfe || b.is_lfe) << a.label << " vs " << b.label;
      } else {
        EXPECT_GE(d, 0.333f) << a.label << " vs " << b.label;
      }
    }
  }
}

// The four geometry cases that must reproduce the retired vendor label
// table for corpus files (RC_* beds carry these cube positions).
TEST(CubeGrid, ReproducesVendorTableGeometry) {
  const PackContext with_sides{/*has_sides=*/true};
  struct Case {
    float x, y, z;
    const char* polar;
    float az, el;
  };
  const Case kCases[] = {
      {-1, 1, 0, "M+030", 30, 0},   {1, 1, 0, "M-030", -30, 0},
      {-1, 0, 0, "M+090", 90, 0},   {1, 0, 0, "M-090", -90, 0},
      {-1, -1, 0, "M+135", 135, 0}, {1, -1, 0, "M-135", -135, 0},
      {-1, 0, 1, "U+090", 90, 30},  {1, 0, 1, "U-090", -90, 30},
  };
  for (const Case& c : kCases) {
    auto m = ClassifyCubePosition(c.x, c.y, c.z, false, with_sides);
    ASSERT_TRUE(m.has_value()) << c.polar;
    EXPECT_EQ(m->polar_label, c.polar);
    EXPECT_FLOAT_EQ(m->azimuth, c.az);
    EXPECT_FLOAT_EQ(m->elevation, c.el);
    EXPECT_FALSE(m->is_lfe);
  }
}

TEST(CubeGrid, PackContextDisambiguatesRears) {
  const PackContext no_sides;
  const PackContext with_sides{/*has_sides=*/true};
  // Middle rears: M±110 without side slots, M±135 with them.
  auto m = ClassifyCubePosition(-1, -1, 0, false, no_sides);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->polar_label, "M+110");
  EXPECT_FLOAT_EQ(m->azimuth, 110.0f);
  m = ClassifyCubePosition(-1, -1, 0, false, with_sides);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->polar_label, "M+135");
  // Upper rears follow the same rule (Table 2B per-pack columns).
  m = ClassifyCubePosition(1, -1, 1, false, no_sides);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->polar_label, "U-110");
  m = ClassifyCubePosition(1, -1, 1, false, with_sides);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->polar_label, "U-135");
  // Non-rear slots are unaffected by context.
  m = ClassifyCubePosition(-1, 1, 0, false, with_sides);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->polar_label, "M+030");
}

TEST(CubeGrid, ToleranceBoundary) {
  const PackContext ctx;
  // Within tolerance: snaps to the slot.
  auto m = ClassifyCubePosition(-0.9f, 1.0f, 0.1f, false, ctx);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->slot->label, "M_FL");
  // Beyond tolerance on every axis: off-grid.
  EXPECT_FALSE(ClassifyCubePosition(-0.8f, 0.5f, 0.5f, false, ctx));
  EXPECT_FALSE(ClassifyCubePosition(-0.25f, 1.0f, 0.0f, false, ctx));
  // Out-of-range input clamps onto the grid.
  m = ClassifyCubePosition(-1.3f, 1.2f, 0.0f, false, ctx);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->slot->label, "M_FL");
}

TEST(CubeGrid, LfeCollisionsArbitratedByPreference) {
  const PackContext ctx;
  struct Case {
    float x;
    const char* lfe_label;
    const char* speaker_label;
  };
  const Case kCases[] = {
      {0.0f, "LFE", "B_FC"},
      {-1.0f, "LFE1", "B_FL"},
      {1.0f, "LFE2", "B_FR"},
  };
  for (const Case& c : kCases) {
    auto as_lfe = ClassifyCubePosition(c.x, 1, -1, /*prefer_lfe=*/true, ctx);
    ASSERT_TRUE(as_lfe.has_value());
    EXPECT_EQ(as_lfe->slot->label, c.lfe_label);
    EXPECT_TRUE(as_lfe->is_lfe);
    EXPECT_FALSE(as_lfe->lfe_ambiguous);

    auto as_spk = ClassifyCubePosition(c.x, 1, -1, /*prefer_lfe=*/false, ctx);
    ASSERT_TRUE(as_spk.has_value());
    EXPECT_EQ(as_spk->slot->label, c.speaker_label);
    EXPECT_FALSE(as_spk->is_lfe);
    EXPECT_TRUE(as_spk->lfe_ambiguous);
  }
  // prefer_lfe with no LFE slot nearby still matches the speaker slot.
  auto m = ClassifyCubePosition(-1, 1, 0, /*prefer_lfe=*/true, ctx);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->slot->label, "M_FL");
  EXPECT_FALSE(m->is_lfe);
}

TEST(CubeGrid, ScreenSlotsResolveByLabelOnly) {
  // (−0.5, 1, 0) is both M_FL50 and the nominal M_FLSc position; position
  // classification must pick the concrete slot.
  const PackContext ctx;
  auto m = ClassifyCubePosition(-0.5f, 1.0f, 0.0f, false, ctx);
  ASSERT_TRUE(m.has_value());
  EXPECT_EQ(m->slot->label, "M_FL50");
  // By label, the screen slot resolves to the M+SC direction.
  const CubeSlot* sc = CubeSlotByLabel("M_FLSc");
  ASSERT_NE(sc, nullptr);
  auto r = ResolveCubeSlot(*sc, ctx);
  EXPECT_EQ(r.polar_label, "M+SC");
  EXPECT_FLOAT_EQ(r.azimuth, 25.0f);
}

TEST(CubeGrid, ResolveCubeSlotAppliesContext) {
  const CubeSlot* bl = CubeSlotByLabel("M_BL");
  ASSERT_NE(bl, nullptr);
  EXPECT_EQ(ResolveCubeSlot(*bl, PackContext{false}).polar_label, "M+110");
  EXPECT_EQ(ResolveCubeSlot(*bl, PackContext{true}).polar_label, "M+135");
}

}  // namespace
}  // namespace adm2iamf
