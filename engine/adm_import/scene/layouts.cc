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

#include <optional>
#include <string>
#include <vector>

#include "absl/strings/string_view.h"
#include "adm_import/adm/adm_vocabulary.h"
#include "adm_import/scene/cube_grid.h"
// oar.h (for the layout enum) comes via layouts.h, wrapped in extern "C".

namespace adm2iamf {
namespace {

// Shorthand speaker constructors matching OAR's layout.c positions.
Speaker M(absl::string_view n, float az) {
  return {std::string(n), az, 0.0f, false};
}
Speaker U(absl::string_view n, float az) {
  return {std::string(n), az, 30.0f, false};
}
Speaker Lfe(absl::string_view n) {
  return {std::string(n), 45.0f, -30.0f, true};
}

}  // namespace

// Order/angles copied verbatim from OAR layout.c (ck_oar_layout_714).
const Layout& ImportLayout() {
  static const Layout* layout = new Layout{
      "7.1.4",
      ck_oar_layout_714,
      {M("M+030", 30), M("M-030", -30), M("M+000", 0), Lfe("LFE1"),
       M("M+090", 90), M("M-090", -90), M("M+135", 135), M("M-135", -135),
       U("U+045", 45), U("U-045", -45), U("U+135", 135), U("U-135", -135)}};
  return *layout;
}

namespace {

// Maps a structurally-parsed BS.2051 label to a position. The shared
// grammar lives in adm_vocabulary so the audit classifies exactly the shapes
// this accepts; here the layer prefix only picks the nominal elevation
// (M=0, U=+30, UH=+45, B=-30, T=+90).
std::optional<Speaker> ParseItuLabel(absl::string_view label) {
  const std::optional<adm::vocab::SpeakerLabelParts> parts =
      adm::vocab::ParseSpeakerLabelGrammar(label);
  if (!parts.has_value()) return std::nullopt;

  Speaker s;
  s.name = std::string(label);
  s.is_lfe = false;
  if (parts->layer == "M") {
    s.elevation = 0.0f;
  } else if (parts->layer == "UH") {
    s.elevation = 45.0f;
  } else if (parts->layer == "U") {
    s.elevation = 30.0f;
  } else if (parts->layer == "B") {
    s.elevation = -30.0f;
  } else {  // "T"
    s.elevation = 90.0f;
  }
  // BS.2051 screen-edge pair; ±25 is the BS.2094 screen-unknown default.
  s.azimuth =
      static_cast<float>(parts->sign * (parts->screen ? 25 : parts->azimuth));
  return s;
}

}  // namespace

int Layout::lfe_index() const {
  for (int i = 0; i < static_cast<int>(speakers.size()); ++i) {
    if (speakers[i].is_lfe) return i;
  }
  return -1;
}

std::optional<Speaker> ResolveSpeakerLabel(absl::string_view label) {
  const absl::string_view bare = adm::vocab::StripSpeakerLabelUrn(label);
  // The three spec LFE spellings (BS.2094-2 Tables 1A/1B).
  if (bare == "LFE" || bare == "LFE1" || bare == "LFE2") {
    Speaker s;
    s.name = std::string(bare);
    s.is_lfe = true;
    return s;
  }
  // Table 1B cube labels resolve through the cube grid (general Table 2B
  // direction; context-aware resolution happens in the adapter, which has
  // the pack in hand).
  if (const CubeSlot* slot = CubeSlotByLabel(bare)) {
    const CubeMatch m = ResolveCubeSlot(*slot, PackContext{});
    Speaker s;
    s.name = std::string(m.polar_label);
    s.azimuth = m.azimuth;
    s.elevation = m.elevation;
    s.is_lfe = m.is_lfe;
    return s;
  }
  return ParseItuLabel(bare);
}

}  // namespace adm2iamf
