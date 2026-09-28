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

#include "meters/bs1770_weights.h"

namespace eclipsa_studio {

std::vector<float> Bs1770WeightsForLayout(uint32_t layout) {
  // OAR layout enum values (from liboar/include/oar.h, oar_layout_t).
  constexpr uint32_t kMono = 1;
  constexpr uint32_t kStereo = 2;   // Sound System A (0+2+0)
  constexpr uint32_t k51 = 3;       // Sound System B (0+5+0)
  constexpr uint32_t k512 = 4;      // Sound System C (2+5+0)
  constexpr uint32_t k514 = 5;      // Sound System D (4+5+0)
  constexpr uint32_t k71 = 6;       // Sound System I (0+7+0)
  constexpr uint32_t k712 = 7;      // IAMF extension
  constexpr uint32_t k714 = 8;      // Sound System J (4+7+0)
  constexpr uint32_t k312 = 9;      // IAMF extension
  constexpr uint32_t k916 = 10;     // IAMF extension
  constexpr uint32_t kA293 = 11;    // Sound System H (9+10+3, 22.2)
  constexpr uint32_t k7154 = 12;    // IAMF extension (7.1.5.4)
  constexpr uint32_t kE451 = 0x81;  // Sound System E (4+5+1)
  constexpr uint32_t kF370 = 0x82;  // Sound System F (3+7+0, two LFEs)
  constexpr uint32_t kG490 = 0x83;  // Sound System G (4+9+0)
  constexpr uint32_t kBinaural = 0xFF;

  switch (layout) {
    case kMono:
      return {1.0f};
    case kStereo:
    case kBinaural:
      return {1.0f, 1.0f};
    case k51:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f};
    case k512:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f, 1.0f, 1.0f};
    case k514:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f, 1.0f, 1.0f, 1.0f, 1.0f};
    case kE451:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f,
              1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    case kF370:
      // Order: FC, FL, FR, TpFL, TpFR, SiL, SiR, BL, BR, TpBC, LFE1, LFE2.
      return {1.0f,  1.0f, 1.0f, 1.0f, 1.0f, 1.41f,
              1.41f, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f};
    case kG490:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f, 1.0f,
              1.0f, 1.0f, 1.0f, 1.0f, 1.0f,  1.0f,  1.0f};
    case k71:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f, 1.0f, 1.0f};
    case k712:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f, 1.0f, 1.0f, 1.0f, 1.0f};
    case k714:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f,
              1.0f, 1.0f, 1.0f, 1.0f, 1.0f,  1.0f};
    case k312:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f};
    case k916:
      // FL/FR at ±60° get 1.41 (wide fronts); SiL/SiR at ±90° get 1.41.
      return {1.41f, 1.41f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f,
              1.41f, 1.41f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    case kA293:
      // 22.2: two LFEs (positions 3 and 9); wide fronts + sides at 1.41.
      return {1.41f, 1.41f, 1.0f,  0.0f,  1.0f, 1.0f, 1.0f, 1.0f,
              1.0f,  0.0f,  1.41f, 1.41f, 1.0f, 1.0f, 1.0f, 1.0f,
              1.0f,  1.0f,  1.0f,  1.0f,  1.0f, 1.0f, 1.0f, 1.0f};
    case k7154:
      return {1.0f, 1.0f, 1.0f, 0.0f, 1.41f, 1.41f, 1.0f, 1.0f, 1.0f,
              1.0f, 1.0f, 1.0f, 1.0f, 1.0f,  1.0f,  1.0f, 1.0f};
    default:
      return {};
  }
}

}  // namespace eclipsa_studio
