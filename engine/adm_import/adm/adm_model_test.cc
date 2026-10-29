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

#include "adm_import/adm/adm_model.h"

#include <cstdint>
#include <string>
#include <utility>

#include "gtest/gtest.h"

namespace adm2iamf {
namespace adm {
namespace {

ChnaEntry Row(uint16_t track_index, std::string uid, std::string track_ref) {
  ChnaEntry e;
  e.track_index = track_index;
  e.uid = std::move(uid);
  e.track_ref = std::move(track_ref);
  return e;
}

// ModelIndex answers each lookup as the Model scan of the same name does:
// the first entry for a duplicated id, and no match for a chna row with
// track index 0.
TEST(ModelIndex, MatchesTheModelScans) {
  Model model;
  AudioPackFormat pack;
  pack.id = "AP_1";
  pack.name = "first";
  model.packs.push_back(pack);
  pack.name = "second";
  model.packs.push_back(pack);
  AudioChannelFormat channel;
  channel.id = "AC_1";
  channel.name = "first";
  model.channels.push_back(channel);
  channel.name = "second";
  model.channels.push_back(channel);
  model.chna = {
      Row(0, "ATU_1", "AT_00010001_01"),  // Unused row.
      Row(3, "ATU_1", "AT_00010001_01"),
      Row(4, "ATU_1", "AT_00010001_02"),  // Same UID and channel again.
      Row(5, "ATU_2", "AC_00010002"),
      Row(6, "ATU_3", "XX_1"),  // No channel id derivable.
  };

  const ModelIndex index(model);
  for (const char* id : {"AP_1", "AP_2"}) {
    EXPECT_EQ(index.Pack(id), model.Pack(id)) << id;
  }
  ASSERT_NE(index.Pack("AP_1"), nullptr);
  EXPECT_EQ(index.Pack("AP_1")->name, "first");
  for (const char* id : {"AC_1", "AC_2"}) {
    EXPECT_EQ(index.Channel(id), model.Channel(id)) << id;
  }
  ASSERT_NE(index.Channel("AC_1"), nullptr);
  EXPECT_EQ(index.Channel("AC_1")->name, "first");
  for (const char* uid : {"ATU_1", "ATU_2", "ATU_3", "ATU_4"}) {
    EXPECT_EQ(index.TrackIndexForUid(uid), model.TrackIndexForUid(uid)) << uid;
  }
  for (const char* id : {"AC_00010001", "AC_00010002", "AC_00010003", ""}) {
    EXPECT_EQ(index.TrackIndexForChannel(id), model.TrackIndexForChannel(id))
        << id;
  }
  EXPECT_EQ(index.TrackIndexForUid("ATU_1"), 3);
  EXPECT_EQ(index.TrackIndexForChannel("AC_00010001"), 3);
  EXPECT_EQ(index.TrackIndexForChannel(""), 6);
}

}  // namespace
}  // namespace adm
}  // namespace adm2iamf
