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

// Shared object-motion evaluation: turn a dynamic object's keyframe timeline
// into an interpolated (position, gain) at a given frame. Used by every render
// backend and the probe so motion semantics -- jumpPosition snaps,
// interpolationLength ramps -- are identical regardless of where the source
// is ultimately projected.
//
// Interpolation runs in the authored coordinate system: polar keyframe pairs
// blend shortest-arc in azimuth, cartesian pairs blend linearly in room-cube
// space (BS.2127's own rule for `cartesian` objects). A timeline that switches
// systems mid-object is out-of-spec; at such a boundary the previous position
// is converted into the current keyframe's system with the layout-independent
// BS.2127 section 10 fixed map (this module is deliberately layout-blind, so
// the render-time layout-anchored conversion cannot apply here). Known
// consequence: on layouts where the anchored map differs from the fixed map
// (e.g. 7.1.4), the rendered position can step at the first frame of such a
// ramp — the previous block rendered anchored, but the lerp starts from its
// fixed-map image. Accepted for out-of-spec input; pinned by test.

#ifndef ADM2IAMF_RENDER_OBJECT_MOTION_H_
#define ADM2IAMF_RENDER_OBJECT_MOTION_H_

#include <cstdint>
#include <vector>

#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"

namespace adm2iamf {

// An interpolated source position (in its authored coordinate system) and its
// linear gain at a point in time.
struct PosGain {
  ObjectPosition position;
  float gain = 1.0f;
};

// Frame index (sample, at `sample_rate`) at which each keyframe begins. The
// returned vector is parallel to `timeline`.
std::vector<uint64_t> KeyframeStartFrames(
    const std::vector<ObjectKeyframe>& timeline, uint32_t sample_rate);

// Index of the active keyframe at `frame`: the last keyframe whose start_frame
// is <= frame (0 if `frame` precedes the first). `start_frame` must be sorted
// ascending (as produced by KeyframeStartFrames). O(log n) and stateless, so
// callers may evaluate blocks in any order or more than once -- unlike a
// monotonic cursor, this is reentrant.
size_t ActiveKeyframe(const std::vector<uint64_t>& start_frame, uint64_t frame);

// Evaluates the timeline at `frame`. `cur` is the index of the active keyframe
// (the last one whose start_frame <= frame), typically obtained from
// ActiveKeyframe. `start_frame` comes from KeyframeStartFrames. Honors
// jumpPosition (snap) and interpolationLength (else the block duration) for the
// ramp from the previous keyframe.
PosGain EvalObjectTimeline(const std::vector<ObjectKeyframe>& timeline,
                           const std::vector<uint64_t>& start_frame, size_t cur,
                           uint64_t frame, uint32_t sample_rate);

}  // namespace adm2iamf

#endif  // ADM2IAMF_RENDER_OBJECT_MOTION_H_
