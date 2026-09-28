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

#include "adm_import/adm/common_definitions.h"

#include <string>
#include <vector>

#include "adm_import/adm/adm_model.h"
#include "gtest/gtest.h"

namespace adm2iamf {
namespace adm {
namespace {

// A bed object that references the common-def 7.1.2 pack AP_00010016 with 10
// track UIDs, plus a chna binding each UID to a common-def channel -- exactly
// how a real EBU master carries a bed (nothing inlined in the axml).
Model BedReferencingCommonDef() {
  Model model;
  AudioObject bed;
  bed.id = "AO_BED";
  bed.name = "Bed_1";
  bed.pack_format_id_refs = {"AP_00010016"};
  const char* acs[10] = {"AT_00010001_01", "AT_00010002_01", "AT_00010003_01",
                         "AT_00010004_01", "AT_0001000a_01", "AT_0001000b_01",
                         "AT_0001001c_01", "AT_0001001d_01", "AT_00010013_01",
                         "AT_00010014_01"};
  for (int i = 0; i < 10; ++i) {
    const std::string uid = "ATU_0000000" + std::to_string(i + 1);
    bed.track_uid_refs.push_back(uid);
    ChnaEntry e;
    e.track_index = static_cast<uint16_t>(i + 1);
    e.uid = uid;
    e.track_ref = acs[i];
    e.pack_ref = "AP_00010016";
    model.chna.push_back(e);
  }
  model.objects.push_back(std::move(bed));
  return model;
}

TEST(CommonDefinitions, SynthesizesPackAndChannelsFromChna) {
  Model model = BedReferencingCommonDef();
  ASSERT_EQ(model.Pack("AP_00010016"), nullptr);  // not present before

  auto unresolved = ResolveCommonDefinitions(model);
  EXPECT_TRUE(unresolved.empty());

  const AudioPackFormat* pack = model.Pack("AP_00010016");
  ASSERT_NE(pack, nullptr);
  EXPECT_EQ(pack->type, TypeDefinition::kDirectSpeakers);
  ASSERT_EQ(pack->channel_format_id_refs.size(), 10u);
  EXPECT_EQ(pack->channel_format_id_refs.front(), "AC_00010001");

  // Each synthesized channel carries its ITU speaker label (positions stay in
  // the layout table). Spot-check the corners.
  auto label = [&](const char* id) -> std::string {
    const AudioChannelFormat* c = model.Channel(id);
    return c && !c->blocks.empty() ? c->blocks.front().speaker_label : "";
  };
  EXPECT_EQ(label("AC_00010001"), "M+030");  // FL
  EXPECT_EQ(label("AC_00010004"), "LFE");    // LFE (Table 1A spelling)
  EXPECT_EQ(label("AC_0001000a"), "M+090");  // Lss
  EXPECT_EQ(label("AC_0001001c"), "M+135");  // Lrs
  EXPECT_EQ(label("AC_00010013"), "U+090");  // Lts (top-side)
}

TEST(CommonDefinitions, CoversFullTable1AAnd1B) {
  Model model;
  AudioObject bed;
  bed.id = "AO_BED";
  bed.pack_format_id_refs = {"AP_00010017"};  // common-def 7.1.4 pack
  const char* acs[4] = {
      "AC_00010022_00",  // Table 1A U+045, AC_-style chna ref with suffix
      "AT_00010028_01",  // UH+180
      "AT_00010816_01",  // Table 1B B_FL
      "AT_0001082a_01",  // Table 1B M_BR50
  };
  for (int i = 0; i < 4; ++i) {
    const std::string uid = "ATU_0000000" + std::to_string(i + 1);
    bed.track_uid_refs.push_back(uid);
    ChnaEntry e;
    e.track_index = static_cast<uint16_t>(i + 1);
    e.uid = uid;
    e.track_ref = acs[i];
    e.pack_ref = "AP_00010017";
    model.chna.push_back(e);
  }
  model.objects.push_back(std::move(bed));

  auto unresolved = ResolveCommonDefinitions(model);
  EXPECT_TRUE(unresolved.empty());
  auto label = [&](const char* id) -> std::string {
    const AudioChannelFormat* c = model.Channel(id);
    return c && !c->blocks.empty() ? c->blocks.front().speaker_label : "";
  };
  EXPECT_EQ(label("AC_00010022"), "U+045");
  EXPECT_EQ(label("AC_00010028"), "UH+180");
  EXPECT_EQ(label("AC_00010816"), "B_FL");
  EXPECT_EQ(label("AC_0001082a"), "M_BR50");
}

TEST(CommonDefinitions, LeavesInlinedAndUserPacksUntouched) {
  Model model;
  // A user-defined (inlined) Objects pack -- xxxx = 0x1001 > 0x0FFF.
  AudioObject obj;
  obj.id = "AO_OBJ";
  obj.pack_format_id_refs = {"AP_00031001"};
  model.objects.push_back(obj);
  AudioPackFormat inlined;
  inlined.id = "AP_00031001";
  inlined.type = TypeDefinition::kObjects;
  model.packs.push_back(inlined);

  auto unresolved = ResolveCommonDefinitions(model);
  EXPECT_TRUE(unresolved.empty());
  EXPECT_EQ(model.packs.size(), 1u);  // nothing synthesized
  EXPECT_TRUE(model.channels.empty());
}

TEST(CommonDefinitions, ReportsUnmappedCommonDefChannels) {
  Model model;
  AudioObject bed;
  bed.id = "AO_BED";
  bed.pack_format_id_refs = {"AP_00010003"};  // common-def 5.1 pack
  bed.track_uid_refs = {"ATU_1"};
  model.objects.push_back(bed);
  ChnaEntry e;
  e.track_index = 1;
  e.uid = "ATU_1";
  e.track_ref = "AT_00010066_01";  // not in the seeded table
  e.pack_ref = "AP_00010003";
  model.chna.push_back(e);

  auto unresolved = ResolveCommonDefinitions(model);
  ASSERT_EQ(unresolved.size(), 1u);
  EXPECT_EQ(unresolved.front(), "AC_00010066");
  // The pack is still created (so resolvable siblings would render); the
  // unmapped channel is simply not synthesized.
  EXPECT_NE(model.Pack("AP_00010003"), nullptr);
  EXPECT_EQ(model.Channel("AC_00010066"), nullptr);
}

}  // namespace
}  // namespace adm
}  // namespace adm2iamf
