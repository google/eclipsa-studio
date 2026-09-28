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

#include "adm_import/scene/layouts.h"

#include "gtest/gtest.h"
#include "oar.h"

namespace adm2iamf {
namespace {

TEST(Layouts, ImportLayoutIsSevenOneFour) {
  const Layout& l714 = ImportLayout();
  EXPECT_EQ(l714.name, "7.1.4");
  EXPECT_EQ(l714.oar_layout, ck_oar_layout_714);
  EXPECT_EQ(l714.num_channels(), 12);
  EXPECT_EQ(l714.lfe_index(), 3);
  // Channel 0 is L at +30/0; the top-front pair sits at U+045/-045.
  EXPECT_FLOAT_EQ(l714.speakers[0].azimuth, 30.0f);
  EXPECT_FLOAT_EQ(l714.speakers[8].azimuth, 45.0f);
  EXPECT_FLOAT_EQ(l714.speakers[8].elevation, 30.0f);
}

TEST(SpeakerLabels, ResolvesStructuralItuLabels) {
  auto m = ResolveSpeakerLabel("M+030");
  ASSERT_TRUE(m.has_value());
  EXPECT_FLOAT_EQ(m->azimuth, 30.0f);
  EXPECT_FLOAT_EQ(m->elevation, 0.0f);
  EXPECT_FALSE(m->is_lfe);

  auto u = ResolveSpeakerLabel("U-045");
  ASSERT_TRUE(u.has_value());
  EXPECT_FLOAT_EQ(u->azimuth, -45.0f);
  EXPECT_FLOAT_EQ(u->elevation, 30.0f);

  auto b = ResolveSpeakerLabel("B+045");
  ASSERT_TRUE(b.has_value());
  EXPECT_FLOAT_EQ(b->elevation, -30.0f);

  auto uh = ResolveSpeakerLabel("UH+180");
  ASSERT_TRUE(uh.has_value());
  EXPECT_FLOAT_EQ(uh->azimuth, 180.0f);
  EXPECT_FLOAT_EQ(uh->elevation, 45.0f);

  auto t = ResolveSpeakerLabel("T+000");
  ASSERT_TRUE(t.has_value());
  EXPECT_FLOAT_EQ(t->elevation, 90.0f);

  auto sc = ResolveSpeakerLabel("M-SC");
  ASSERT_TRUE(sc.has_value());
  EXPECT_FLOAT_EQ(sc->azimuth, -25.0f);
  EXPECT_FLOAT_EQ(sc->elevation, 0.0f);
}

TEST(SpeakerLabels, ResolvesLfeSpellingsAndUrns) {
  for (const char* l : {"LFE", "LFE1", "LFE2"}) {
    auto lfe = ResolveSpeakerLabel(l);
    ASSERT_TRUE(lfe.has_value()) << l;
    EXPECT_TRUE(lfe->is_lfe) << l;
  }
  auto urn = ResolveSpeakerLabel("urn:itu:bs:2051:0:speaker:M+030");
  ASSERT_TRUE(urn.has_value());
  EXPECT_FLOAT_EQ(urn->azimuth, 30.0f);
  auto urn_lfe = ResolveSpeakerLabel("urn:itu:bs:2051:1:speaker:LFE");
  ASSERT_TRUE(urn_lfe.has_value());
  EXPECT_TRUE(urn_lfe->is_lfe);
}

TEST(SpeakerLabels, ResolvesCubeLabelsToGeneralDirections) {
  auto fl = ResolveSpeakerLabel("M_FL");
  ASSERT_TRUE(fl.has_value());
  EXPECT_EQ(fl->name, "M+030");
  EXPECT_FLOAT_EQ(fl->azimuth, 30.0f);

  auto bl = ResolveSpeakerLabel("M_BL");
  ASSERT_TRUE(bl.has_value());
  EXPECT_EQ(bl->name, "M+110");  // General (no pack context here).

  auto sl = ResolveSpeakerLabel("U_SL");
  ASSERT_TRUE(sl.has_value());
  EXPECT_FLOAT_EQ(sl->azimuth, 90.0f);
  EXPECT_FLOAT_EQ(sl->elevation, 30.0f);
}

TEST(SpeakerLabels, VendorAndGarbageLabelsAreUnrecognized) {
  EXPECT_FALSE(ResolveSpeakerLabel("RC_L").has_value());
  EXPECT_FALSE(ResolveSpeakerLabel("RoomCentricCenter").has_value());
  EXPECT_FALSE(ResolveSpeakerLabel("LFEch").has_value());
  EXPECT_FALSE(ResolveSpeakerLabel("garbage").has_value());
  EXPECT_FALSE(ResolveSpeakerLabel("").has_value());
}

}  // namespace
}  // namespace adm2iamf
