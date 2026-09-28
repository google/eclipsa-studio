/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// BS.2094-2 Table 1B: the Cartesian "virtual cube" loudspeaker grid, and the
// Table 2B mapping from cube slots to BS.2051 loudspeaker directions.
//
// Cartesian DirectSpeakers channels place loudspeakers on a canonical cube
// grid (X left -1 .. right +1, Y back -1 .. front +1, Z bottom -1 .. top +1).
// Each grid slot has a Table 1B label (M_FL, U_BL, LFE1, ...) and Table 2B
// gives the BS.2051 loudspeaker it plays back on. A few slots are
// pack-contextual: the rear slots map to M/U±135 when the pack also occupies
// the side slots (±1,0,0) and to M/U±110 otherwise — Table 2B's per-pack
// columns encode exactly this split. PackContext carries that bit.
//
// Angle convention matches layouts.h/OAR: azimuth positive = left, degrees.

#ifndef ADM2IAMF_SCENE_CUBE_GRID_H_
#define ADM2IAMF_SCENE_CUBE_GRID_H_

#include <optional>

#include "absl/strings/string_view.h"
#include "absl/types/span.h"

namespace adm2iamf {

// One Table 1B grid slot with its Table 2B *general* playback direction.
struct CubeSlot {
  absl::string_view label;        // Table 1B speakerLabel, e.g. "M_FL".
  float x, y, z;                  // Virtual-cube coordinates.
  absl::string_view polar_label;  // Table 2B general value, e.g. "M+030".
  float azimuth, elevation;       // Nominal direction of polar_label.
  bool is_lfe;
  bool screen;  // Screen-edge slot (M_FLSc/M_FRSc): position is nominal
                // only, so the slot is excluded from position matching.
};

// Pack-level facts that disambiguate Table 2B's contextual slots.
struct PackContext {
  // The pack also occupies the side slots (±1,0,0) — i.e. it is a
  // 7.x/9.x/13.x/15.x/22.x-style layout whose rears sit at ±135, not ±110.
  bool has_sides = false;
};

// A classified cube position / resolved slot.
struct CubeMatch {
  const CubeSlot* slot = nullptr;  // The matched Table 1B slot.
  absl::string_view polar_label;   // After pack-context disambiguation.
  float azimuth = 0.0f;            // Direction of polar_label.
  float elevation = 0.0f;
  bool is_lfe = false;
  // A speaker slot was chosen but an LFE slot shares the same cube position
  // (B_FC≡LFE, B_FL≡LFE1, B_FR≡LFE2) — the choice needs corroboration.
  bool lfe_ambiguous = false;
};

// All Table 1B slots (BS.2094-2 §4.1.1).
absl::Span<const CubeSlot> AllCubeSlots();

// Looks up a Table 1B label ("M_FL", "LFE1", ...); nullptr if not one.
const CubeSlot* CubeSlotByLabel(absl::string_view label);

// Applies the pack-context disambiguation to a slot.
CubeMatch ResolveCubeSlot(const CubeSlot& slot, const PackContext& context);

// Classifies a cube position to its nearest grid slot. Components are
// clamped to [-1, 1]; the nearest slot by Chebyshev distance wins when
// within tolerance 0.15 (less than half the minimum slot separation of
// 1/3, so the match is unique); nullopt beyond. Where an LFE slot and a
// speaker slot coincide, prefer_lfe picks the LFE slot; otherwise the
// speaker slot is returned with lfe_ambiguous set.
std::optional<CubeMatch> ClassifyCubePosition(float x, float y, float z,
                                              bool prefer_lfe,
                                              const PackContext& context);

}  // namespace adm2iamf

#endif  // ADM2IAMF_SCENE_CUBE_GRID_H_
