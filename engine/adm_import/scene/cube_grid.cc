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
#include <optional>

#include "absl/strings/string_view.h"
#include "absl/types/span.h"

namespace adm2iamf {
namespace {

// BS.2094-2 Table 1B, one row per slot, with the Table 2B general playback
// value and its BS.2051 direction. Rear slots (M_BL/M_BR/U_BL/U_BR) store
// the no-sides value (±110); ResolveCubeSlot() swaps in ±135 when the pack
// context says the pack has side slots. LFE directions are the Table 1A
// polar-twin positions (unused for rendering — LFE has no direction).
constexpr CubeSlot kSlots[] = {
    // label, x, y, z, polar_label, az, el, is_lfe, screen
    {"M_FL", -1.0f, 1.0f, 0.0f, "M+030", 30.0f, 0.0f, false, false},
    {"M_FR", 1.0f, 1.0f, 0.0f, "M-030", -30.0f, 0.0f, false, false},
    {"M_FC", 0.0f, 1.0f, 0.0f, "M+000", 0.0f, 0.0f, false, false},
    {"LFE", 0.0f, 1.0f, -1.0f, "LFE", 0.0f, -30.0f, true, false},
    {"M_BL", -1.0f, -1.0f, 0.0f, "M+110", 110.0f, 0.0f, false, false},
    {"M_BR", 1.0f, -1.0f, 0.0f, "M-110", -110.0f, 0.0f, false, false},
    {"M_FL50", -0.5f, 1.0f, 0.0f, "M+030", 30.0f, 0.0f, false, false},
    {"M_FR50", 0.5f, 1.0f, 0.0f, "M-030", -30.0f, 0.0f, false, false},
    {"M_BC", 0.0f, -1.0f, 0.0f, "M+180", 180.0f, 0.0f, false, false},
    {"M_SL", -1.0f, 0.0f, 0.0f, "M+090", 90.0f, 0.0f, false, false},
    {"M_SR", 1.0f, 0.0f, 0.0f, "M-090", -90.0f, 0.0f, false, false},
    {"U_TC", 0.0f, 0.0f, 1.0f, "T+000", 0.0f, 90.0f, false, false},
    {"U_FL", -1.0f, 1.0f, 1.0f, "U+030", 30.0f, 30.0f, false, false},
    {"U_FC", 0.0f, 1.0f, 1.0f, "U+000", 0.0f, 30.0f, false, false},
    {"U_FR", 1.0f, 1.0f, 1.0f, "U-030", -30.0f, 30.0f, false, false},
    {"U_BL", -1.0f, -1.0f, 1.0f, "U+110", 110.0f, 30.0f, false, false},
    {"U_BC", 0.0f, -1.0f, 1.0f, "U+180", 180.0f, 30.0f, false, false},
    {"U_BR", 1.0f, -1.0f, 1.0f, "U-110", -110.0f, 30.0f, false, false},
    {"U_SL", -1.0f, 0.0f, 1.0f, "U+090", 90.0f, 30.0f, false, false},
    {"U_SR", 1.0f, 0.0f, 1.0f, "U-090", -90.0f, 30.0f, false, false},
    {"B_FC", 0.0f, 1.0f, -1.0f, "B+000", 0.0f, -30.0f, false, false},
    {"B_FL", -1.0f, 1.0f, -1.0f, "B+045", 45.0f, -30.0f, false, false},
    {"B_FR", 1.0f, 1.0f, -1.0f, "B-045", -45.0f, -30.0f, false, false},
    {"M_FSL67", -1.0f, 0.667f, 0.0f, "M+060", 60.0f, 0.0f, false, false},
    {"M_FSR67", 1.0f, 0.667f, 0.0f, "M-060", -60.0f, 0.0f, false, false},
    {"LFE1", -1.0f, 1.0f, -1.0f, "LFE1", 45.0f, -30.0f, true, false},
    {"LFE2", 1.0f, 1.0f, -1.0f, "LFE2", -45.0f, -30.0f, true, false},
    // Screen-edge slots: X is "screen edge, or ±0.5 if unknown" — nominal
    // only, so excluded from position matching. Azimuth ±25 is the Table 1A
    // screen-unknown default for M±SC.
    {"M_FLSc", -0.5f, 1.0f, 0.0f, "M+SC", 25.0f, 0.0f, false, true},
    {"M_FRSc", 0.5f, 1.0f, 0.0f, "M-SC", -25.0f, 0.0f, false, true},
    {"U_BC67", 0.0f, -0.667f, 1.0f, "UH+180", 180.0f, 45.0f, false, false},
    {"M_BL50", -0.5f, -1.0f, 0.0f, "M+150", 150.0f, 0.0f, false, false},
    {"M_BR50", 0.5f, -1.0f, 0.0f, "M-150", -150.0f, 0.0f, false, false},
};

// Chebyshev tolerance for slot matching: less than half the minimum
// distinct-slot separation (1/3, e.g. U_BC at y=-1 vs U_BC67 at y=-0.667),
// so a within-tolerance match is unique.
constexpr float kTolerance = 0.15f;

float Chebyshev(const CubeSlot& s, float x, float y, float z) {
  return std::max({std::abs(s.x - x), std::abs(s.y - y), std::abs(s.z - z)});
}

CubeMatch MakeMatch(const CubeSlot& slot, const PackContext& context) {
  CubeMatch m;
  m.slot = &slot;
  m.polar_label = slot.polar_label;
  m.azimuth = slot.azimuth;
  m.elevation = slot.elevation;
  m.is_lfe = slot.is_lfe;
  // Table 2B's contextual rears: ±110 with no side slots, ±135 with them.
  if (context.has_sides) {
    if (slot.label == "M_BL") {
      m.polar_label = "M+135";
      m.azimuth = 135.0f;
    } else if (slot.label == "M_BR") {
      m.polar_label = "M-135";
      m.azimuth = -135.0f;
    } else if (slot.label == "U_BL") {
      m.polar_label = "U+135";
      m.azimuth = 135.0f;
    } else if (slot.label == "U_BR") {
      m.polar_label = "U-135";
      m.azimuth = -135.0f;
    }
  }
  return m;
}

}  // namespace

absl::Span<const CubeSlot> AllCubeSlots() { return kSlots; }

const CubeSlot* CubeSlotByLabel(absl::string_view label) {
  for (const CubeSlot& s : kSlots) {
    if (s.label == label) return &s;
  }
  return nullptr;
}

CubeMatch ResolveCubeSlot(const CubeSlot& slot, const PackContext& context) {
  return MakeMatch(slot, context);
}

std::optional<CubeMatch> ClassifyCubePosition(float x, float y, float z,
                                              bool prefer_lfe,
                                              const PackContext& context) {
  x = std::clamp(x, -1.0f, 1.0f);
  y = std::clamp(y, -1.0f, 1.0f);
  z = std::clamp(z, -1.0f, 1.0f);

  // Nearest speaker slot and nearest LFE slot, tracked separately so the
  // coincident pairs (B_FC≡LFE, B_FL≡LFE1, B_FR≡LFE2) can be arbitrated.
  const CubeSlot* speaker = nullptr;
  float speaker_d = kTolerance;
  const CubeSlot* lfe = nullptr;
  float lfe_d = kTolerance;
  for (const CubeSlot& s : kSlots) {
    if (s.screen) continue;
    const float d = Chebyshev(s, x, y, z);
    if (s.is_lfe) {
      if (d <= lfe_d) {
        lfe = &s;
        lfe_d = d;
      }
    } else if (d <= speaker_d) {
      speaker = &s;
      speaker_d = d;
    }
  }

  if (prefer_lfe && lfe != nullptr) return MakeMatch(*lfe, context);
  if (speaker != nullptr) {
    CubeMatch m = MakeMatch(*speaker, context);
    m.lfe_ambiguous = lfe != nullptr;
    return m;
  }
  if (lfe != nullptr) return MakeMatch(*lfe, context);
  return std::nullopt;
}

}  // namespace adm2iamf
