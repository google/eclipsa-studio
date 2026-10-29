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

#include <cstdint>
#include <string>
#include <vector>

#include "absl/base/no_destructor.h"
#include "absl/container/flat_hash_map.h"
#include "absl/container/flat_hash_set.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace adm {
namespace {

// BS.2094-2 common-definition DirectSpeakers channel IDs -> speaker label:
// the complete Table 1A (polar) and Table 1B (Cartesian cube) inventories.
// The label is all the adapter needs -- ResolveSpeakerLabel maps it to a
// position and flags LFE. AC_0001001a/1b (and their packs) are deprecated
// in BS.2094-2 and deliberately absent (unmapped IDs are reported, never
// mis-placed).
const absl::flat_hash_map<absl::string_view, absl::string_view>&
ChannelLabels() {
  static const absl::NoDestructor<
      absl::flat_hash_map<absl::string_view, absl::string_view>>
      kLabels({
          // Table 1A -- polar.
          {"AC_00010001", "M+030"},   // FrontLeft
          {"AC_00010002", "M-030"},   // FrontRight
          {"AC_00010003", "M+000"},   // FrontCentre
          {"AC_00010004", "LFE"},     // LowFrequencyEffects
          {"AC_00010005", "M+110"},   // SurroundLeft
          {"AC_00010006", "M-110"},   // SurroundRight
          {"AC_00010007", "M+022"},   // FrontLeftOfCentre
          {"AC_00010008", "M-022"},   // FrontRightOfCentre
          {"AC_00010009", "M+180"},   // BackCentre
          {"AC_0001000a", "M+090"},   // SideLeft
          {"AC_0001000b", "M-090"},   // SideRight
          {"AC_0001000c", "T+000"},   // TopCentre
          {"AC_0001000d", "U+030"},   // TopFrontLeft
          {"AC_0001000e", "U+000"},   // TopFrontCentre
          {"AC_0001000f", "U-030"},   // TopFrontRight
          {"AC_00010010", "U+110"},   // TopSurroundLeft
          {"AC_00010011", "U+180"},   // TopBackCentre
          {"AC_00010012", "U-110"},   // TopSurroundRight
          {"AC_00010013", "U+090"},   // TopSideLeft
          {"AC_00010014", "U-090"},   // TopSideRight
          {"AC_00010015", "B+000"},   // BottomFrontCentre
          {"AC_00010016", "B+045"},   // BottomFrontLeftMid
          {"AC_00010017", "B-045"},   // BottomFrontRightMid
          {"AC_00010018", "M+060"},   // FrontLeftWide
          {"AC_00010019", "M-060"},   // FrontRightWide
          {"AC_0001001c", "M+135"},   // BackLeftMid
          {"AC_0001001d", "M-135"},   // BackRightMid
          {"AC_0001001e", "U+135"},   // TopBackLeftMid
          {"AC_0001001f", "U-135"},   // TopBackRightMid
          {"AC_00010020", "LFE1"},    // LowFrequencyEffects1
          {"AC_00010021", "LFE2"},    // LowFrequencyEffects2
          {"AC_00010022", "U+045"},   // TopFrontLeftMid
          {"AC_00010023", "U-045"},   // TopFrontRightMid
          {"AC_00010024", "M+SC"},    // FrontLeftScreen
          {"AC_00010025", "M-SC"},    // FrontRightScreen
          {"AC_00010026", "M+045"},   // FrontLeftMid
          {"AC_00010027", "M-045"},   // FrontRightMid
          {"AC_00010028", "UH+180"},  // UpperTopBackCentre
          {"AC_00010029", "M+150"},   // BackLeft
          {"AC_0001002a", "M-150"},   // BackRight
          {"AC_0001002b", "B+030"},   // BottomFrontLeft
          {"AC_0001002c", "B-030"},   // BottomFrontRight
          // Table 1B -- Cartesian virtual cube.
          {"AC_00010801", "M_FL"},
          {"AC_00010802", "M_FR"},
          {"AC_00010803", "M_FC"},
          {"AC_00010804", "LFE"},
          {"AC_00010805", "M_BL"},
          {"AC_00010806", "M_BR"},
          {"AC_00010807", "M_FL50"},
          {"AC_00010808", "M_FR50"},
          {"AC_00010809", "M_BC"},
          {"AC_0001080a", "M_SL"},
          {"AC_0001080b", "M_SR"},
          {"AC_0001080c", "U_TC"},
          {"AC_0001080d", "U_FL"},
          {"AC_0001080e", "U_FC"},
          {"AC_0001080f", "U_FR"},
          {"AC_00010810", "U_BL"},
          {"AC_00010811", "U_BC"},
          {"AC_00010812", "U_BR"},
          {"AC_00010813", "U_SL"},
          {"AC_00010814", "U_SR"},
          {"AC_00010815", "B_FC"},
          {"AC_00010816", "B_FL"},
          {"AC_00010817", "B_FR"},
          {"AC_00010818", "M_FSL67"},
          {"AC_00010819", "M_FSR67"},
          {"AC_00010820", "LFE1"},
          {"AC_00010821", "LFE2"},
          {"AC_00010824", "M_FLSc"},
          {"AC_00010825", "M_FRSc"},
          {"AC_00010828", "U_BC67"},
          {"AC_00010829", "M_BL50"},
          {"AC_0001082a", "M_BR50"},
      });
  return *kLabels;
}

// Parses the 8 hex digits after the "XX_" prefix of an ADM common-definition id
// ("AP_yyyyxxxx" / "AC_yyyyxxxx") into (yyyy, xxxx). False if malformed.
bool ParseCommonDefId(absl::string_view id, uint32_t& yyyy, uint32_t& xxxx) {
  if (id.size() != 11 || id[2] != '_') return false;  // "AP_00010016"
  uint32_t value = 0;
  for (size_t i = 3; i < id.size(); ++i) {
    const char c = id[i];
    uint32_t d;
    if (c >= '0' && c <= '9') {
      d = static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      d = static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      d = static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return false;
    }
    value = (value << 4) | d;
  }
  yyyy = value >> 16;
  xxxx = value & 0xFFFF;
  return true;
}

// True for a common-definition pack of typeDefinition DirectSpeakers: the type
// nibble group yyyy == 0x0001 and the index xxxx is in the common-def range
// [0x0001, 0x0FFF] (>= 0x1000 is user-defined / inlined).
bool IsCommonDefDirectSpeakersPack(absl::string_view pack_id) {
  uint32_t yyyy, xxxx;
  if (!ParseCommonDefId(pack_id, yyyy, xxxx)) return false;
  return yyyy == 0x0001 && xxxx >= 0x0001 && xxxx <= 0x0FFF;
}

}  // namespace

std::vector<std::string> ResolveCommonDefinitions(Model& model) {
  std::vector<std::string> unresolved;

  // UID, pack and channel lookups go through hash maps (ES-849).
  // audioTrackUID -> derived audioChannelFormat id ("AC_..."), first chna
  // row wins.
  absl::flat_hash_map<std::string, std::string> channel_id_for_uid;
  channel_id_for_uid.reserve(model.chna.size());
  for (const ChnaEntry& e : model.chna) {
    channel_id_for_uid.try_emplace(e.uid, e.ChannelFormatId());
  }
  // Ids already in the model. Each set grows with every pack and channel
  // this function appends.
  absl::flat_hash_set<std::string> pack_ids;
  pack_ids.reserve(model.packs.size());
  for (const AudioPackFormat& p : model.packs) pack_ids.insert(p.id);
  absl::flat_hash_set<std::string> channel_ids;
  channel_ids.reserve(model.channels.size());
  for (const AudioChannelFormat& c : model.channels) channel_ids.insert(c.id);

  for (const AudioObject& obj : model.objects) {
    for (const std::string& pack_ref : obj.pack_format_id_refs) {
      if (pack_ids.contains(pack_ref)) continue;  // Already inlined.
      if (!IsCommonDefDirectSpeakersPack(pack_ref)) continue;

      // Derive the pack's channel list, in order, from the referencing object's
      // track UIDs (each binds to a common-def channel via the chna table).
      AudioPackFormat pack;
      pack.id = pack_ref;
      pack.type = TypeDefinition::kDirectSpeakers;
      for (const std::string& uid : obj.track_uid_refs) {
        const auto uid_it = channel_id_for_uid.find(uid);
        if (uid_it == channel_id_for_uid.end() || uid_it->second.empty()) {
          continue;
        }
        const std::string& ac_id = uid_it->second;
        pack.channel_format_id_refs.push_back(ac_id);

        if (channel_ids.contains(ac_id)) continue;  // Already present.
        const auto& labels = ChannelLabels();
        const auto it = labels.find(ac_id);
        if (it == labels.end()) {
          unresolved.push_back(ac_id);
          continue;  // Leave the ref; the adapter skips what it can't resolve.
        }
        AudioChannelFormat ch;
        ch.id = ac_id;
        ch.name = std::string(it->second);
        ch.type = TypeDefinition::kDirectSpeakers;
        AudioBlockFormat block;
        block.speaker_label = std::string(it->second);
        ch.blocks.push_back(std::move(block));
        model.channels.push_back(std::move(ch));
        channel_ids.insert(ac_id);
      }
      model.packs.push_back(std::move(pack));
      pack_ids.insert(pack_ref);
    }
  }

  return unresolved;
}

}  // namespace adm
}  // namespace adm2iamf
