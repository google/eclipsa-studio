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

// The profile-blind canonical scene: every input reduces to a positioned
// source — static bed channels at their speaker positions plus dynamic
// objects. The channel-bed renderer (and the parked adm-lab bakes, ES-569)
// consume this and are unaware of ADM or profile.

#ifndef ADM2IAMF_SCENE_SCENE_H_
#define ADM2IAMF_SCENE_SCENE_H_

#include <optional>
#include <string>
#include <vector>

#include "adm_import/scene/layouts.h"

namespace adm2iamf {

// Per-object/per-bed binaural render mode (research §8). Unused in-tree:
// kept, with its Source/ObjectSource fields, for the parked adm-lab binaural
// bake (ES-569), which routes Near/Mid/Far through OBR and folds Off to stereo.
// Do not delete or change the kMid default without checking adm-lab's bakes/.
//
// kMid is the default: the mode is not carried in the ADM `axml` (it lives
// in proprietary sidecar metadata, whose decode is deferred until custom
// labeled-object masters land). Until then every source defaults to Mid and
// a global override selects another mode.
enum class BinauralMode { kOff, kNear, kMid, kFar };

// A static positioned source (one bed channel).
struct Source {
  std::string label;    // Diagnostic, e.g. the channel name / "M+030".
  Polar position;       // Egocentric polar (ignored when is_lfe).
  bool is_lfe = false;  // Routed to the target LFE, never panned.
  float gain = 1.0f;    // Linear; folds in ADM object/block gain.
  int track_index = 0;  // 1-based WAV track carrying this source's mono PCM.
  BinauralMode binaural_mode = BinauralMode::kMid;  // Binaural bed routing.
};

// A room-cube cartesian position (ADM allocentric, BS.2127 convention):
// x right, y front, z up, each nominally in [-1, 1].
struct Cube {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};

// An object position in the system it was authored in. Cartesian-authored
// blocks keep their cube coordinates so the render backends convert per
// target layout at render time (OAR's layout-anchored conversion, ES-567);
// polar-authored blocks stay polar and are never converted.
struct ObjectPosition {
  bool cartesian = false;
  Polar polar;  // Active when !cartesian.
  Cube cube;    // Active when cartesian.
};

// One position/gain segment of a dynamic object (an audioBlockFormat), timed in
// seconds. Positions stay in their authored coordinate system (see
// ObjectPosition); interpolation and any cartesian->polar conversion happen at
// render time.
struct ObjectKeyframe {
  double start_s = 0.0;
  double duration_s = 0.0;    // Meaningful only when has_duration.
  bool has_duration = false;  // False => runs to end of file.
  ObjectPosition position;
  float gain = 1.0f;  // Linear; folds in object + block gain.
  bool jump = false;  // jumpPosition: snap vs interpolate from prev.
  std::optional<double> interp_length_s;
};

// A dynamic object: a mono source moving along a position/gain timeline.
struct ObjectSource {
  std::string label;
  int track_index = 0;  // 1-based WAV track.
  int importance = 10;  // ADM importance (0..10); used by the filter.
  std::vector<ObjectKeyframe> timeline;  // Ordered by start_s; >= 1 entry.
  BinauralMode binaural_mode = BinauralMode::kMid;  // Binaural bed routing.
};

// How a bed channel's direction/LFE routing was determined, in resolution
// priority order.
enum class ResolutionMethod {
  kLfeFrequency,      // <frequency typeDefinition="lowPass"> marker.
  kLfeLabel,          // Recognized LFE speaker label (or channel name).
  kPolar,             // Explicit egocentric polar block position.
  kSpecLabel,         // Recognized BS.2051/2094 speaker label.
  kCubeSlot,          // Cartesian position matched a Table 1B cube slot.
  kLfeCube,           // Cartesian position matched an LFE cube slot.
  kPhysicalFallback,  // Off-grid cartesian: naive physical direction.
  kUnresolved,        // No usable information; channel dropped.
  kUnsupportedPack,   // Pack type the importer cannot render (HOA, Matrix,
                      // Binaural, undefined); channel dropped (ES-623).
};

constexpr const char* ResolutionMethodName(ResolutionMethod m) {
  switch (m) {
    case ResolutionMethod::kLfeFrequency:
      return "lfe_frequency";
    case ResolutionMethod::kLfeLabel:
      return "lfe_label";
    case ResolutionMethod::kPolar:
      return "polar";
    case ResolutionMethod::kSpecLabel:
      return "spec_label";
    case ResolutionMethod::kCubeSlot:
      return "cube_slot";
    case ResolutionMethod::kLfeCube:
      return "lfe_cube";
    case ResolutionMethod::kPhysicalFallback:
      return "physical_fallback";
    case ResolutionMethod::kUnresolved:
      return "unresolved";
    case ResolutionMethod::kUnsupportedPack:
      return "unsupported_pack";
  }
  return "unresolved";
}

// Per-channel record of how (or why not) a bed channel resolved. One entry
// per bed channel, plus entries for dropped object channels, so failures
// and fallbacks always surface — not only when the whole scene is empty.
struct ChannelResolution {
  std::string channel_id;     // audioChannelFormat id.
  std::string channel_name;   // audioChannelFormat name (may be empty).
  std::string speaker_label;  // speakerLabel as authored (may be empty).
  ResolutionMethod method = ResolutionMethod::kUnresolved;
  bool resolved = false;
  bool is_lfe = false;
  bool fallback = false;       // Lenient/fallback path — worth a warning.
  bool lfe_ambiguous = false;  // Cube slot coincides with an LFE slot.
  bool divergence = false;     // Label direction disagreed with the polar
                               // position by more than 5 degrees.
  std::string note;            // Human-readable detail for warnings.
  // Index into Scene::sources of the source this channel produced, or -1
  // when it produced none (unresolved, or no WAV track bound). Consumers
  // pair a source with its record through this rather than by assuming the
  // two vectors advance in lockstep.
  int source_index = -1;
};

struct Scene {
  std::vector<Source> sources;        // Static bed channels.
  std::vector<ObjectSource> objects;  // Dynamic objects.
  // One record per bed channel (and per dropped object channel).
  std::vector<ChannelResolution> resolutions;
  // Object keyframe coordinate values that lay outside the room cube and
  // were clamped to it (clamping changes the authored direction, so the
  // probe surfaces this as a warning; the spec does not bound X/Y/Z, so the
  // audit deliberately does not flag them).
  int clamped_object_values = 0;
};

}  // namespace adm2iamf

#endif  // ADM2IAMF_SCENE_SCENE_H_
