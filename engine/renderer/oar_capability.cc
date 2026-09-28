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

#include "renderer/oar_capability.h"

#include "oar.h"

std::optional<int> OarSubTypeForCodedChannelLayout(
    int32_t loudspeaker_layout_raw, int32_t expanded_loudspeaker_layout_raw) {
  switch (loudspeaker_layout_raw) {
    case 0:
      return ck_oar_layout_mono;
    case 1:
      return ck_oar_layout_stereo;
    case 2:
      return ck_oar_layout_51;
    case 3:
      return ck_oar_layout_512;
    case 4:
      return ck_oar_layout_514;
    case 5:
      return ck_oar_layout_71;
    case 6:
      return ck_oar_layout_712;
    case 7:
      return ck_oar_layout_714;
    case 8:
      return ck_oar_layout_312;
    case 9:
      // Binaural bed → stereo element, matching the authoring path (see
      // the header note). ck_oar_layout_binaural stays output-only here.
      return ck_oar_layout_stereo;
    case 15:  // Expanded — dispatch on expanded_loudspeaker_layout.
      switch (expanded_loudspeaker_layout_raw) {
        case 0:
          return ck_oar_layout_lfe;
        case 1:
          return ck_oar_layout_stereo_s;
        case 2:
          return ck_oar_layout_stereo_ss;
        case 3:
          return ck_oar_layout_stereo_rs;
        case 4:
          return ck_oar_layout_stereo_tf;
        case 5:
          return ck_oar_layout_stereo_tb;
        case 6:
          return ck_oar_layout_top_4ch;
        case 7:
          return ck_oar_layout_3ch;
        case 8:
          return ck_oar_layout_916;
        case 9:
          return ck_oar_layout_stereo_f;
        case 10:
          return ck_oar_layout_stereo_si;
        case 11:
          return ck_oar_layout_stereo_tpsi;
        case 12:
          return ck_oar_layout_top_6ch;
        case 13:
          return ck_oar_layout_a293;
        case 14:
          return ck_oar_layout_lfe_pair;
        case 15:
          return ck_oar_layout_bottom_3ch;
        case 16:
          return ck_oar_layout_7154;
        case 17:
          return ck_oar_layout_bottom_4ch;
        case 18:
          return ck_oar_layout_top_1ch;
        case 19:
          return ck_oar_layout_top_5ch;
        default:
          return std::nullopt;  // Reserved expanded values (20+).
      }
    default:
      return std::nullopt;  // Reserved loudspeaker_layout values (10–14).
  }
}

std::optional<int> OarSubTypeForAmbisonicsOrder(int32_t order) {
  if (order < ck_oar_zoa || order > ck_oar_4oa) return std::nullopt;
  return order;
}

std::optional<int> OarSubTypeForElement(int32_t kind,
                                        int32_t loudspeaker_layout_raw,
                                        int32_t expanded_loudspeaker_layout_raw,
                                        int32_t ambisonics_order) {
  switch (kind) {
    case 0:
      return OarSubTypeForCodedChannelLayout(loudspeaker_layout_raw,
                                             expanded_loudspeaker_layout_raw);
    case 1:
      return OarSubTypeForAmbisonicsOrder(ambisonics_order);
    default:
      return std::nullopt;
  }
}
