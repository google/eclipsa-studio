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

#include "adm_import/render/object_motion.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "adm_import/scene/bs2127.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"

namespace adm2iamf {
namespace {

// Shortest-arc angular interpolation (degrees). Computed in double to avoid
// the float cancellation near ±180 that could otherwise flip the pan direction
// on rounding; the exact-180° tie is pinned to the positive direction so a
// front-to-back sweep always travels the same way for the same input.
float LerpAngle(float a, float b, double t) {
  double d = std::fmod(static_cast<double>(b) - a + 540.0, 360.0) - 180.0;
  if (d <= -180.0) d = 180.0;
  return static_cast<float>(a + d * t);
}

float Lerp(float a, float b, double t) {
  return static_cast<float>(a + (b - a) * t);
}

// Coordinate-system boundary conversions for out-of-spec mixed timelines,
// via the layout-independent §10 fixed map (see the header note).
Cube AsCube(const ObjectPosition& p) {
  if (p.cartesian) return p.cube;
  bs2127::Cart c =
      bs2127::PolarToCart(p.polar.azimuth, p.polar.elevation, p.polar.distance);
  return {static_cast<float>(c.x), static_cast<float>(c.y),
          static_cast<float>(c.z)};
}

Polar AsPolar(const ObjectPosition& p) {
  if (!p.cartesian) return p.polar;
  bs2127::Sph s = bs2127::CartToPolar(p.cube.x, p.cube.y, p.cube.z);
  return {static_cast<float>(s.azimuth), static_cast<float>(s.elevation),
          std::clamp(static_cast<float>(s.distance), 0.0f, 1.0f)};
}

}  // namespace

std::vector<uint64_t> KeyframeStartFrames(
    const std::vector<ObjectKeyframe>& timeline, uint32_t sample_rate) {
  std::vector<uint64_t> start_frame(timeline.size());
  for (size_t i = 0; i < timeline.size(); ++i) {
    start_frame[i] =
        static_cast<uint64_t>(std::llround(timeline[i].start_s * sample_rate));
  }
  return start_frame;
}

size_t ActiveKeyframe(const std::vector<uint64_t>& start_frame,
                      uint64_t frame) {
  // First keyframe starting strictly after `frame`; the one before it is the
  // last that has started. Before the first keyframe, clamp to index 0.
  auto it = std::upper_bound(start_frame.begin(), start_frame.end(), frame);
  if (it == start_frame.begin()) return 0;
  return static_cast<size_t>(it - start_frame.begin() - 1);
}

PosGain EvalObjectTimeline(const std::vector<ObjectKeyframe>& timeline,
                           const std::vector<uint64_t>& start_frame, size_t cur,
                           uint64_t frame, uint32_t sample_rate) {
  const ObjectKeyframe& k = timeline[cur];
  if (cur == 0 || k.jump) return {k.position, k.gain};

  double interp_s = k.interp_length_s.has_value() ? *k.interp_length_s
                    : k.has_duration              ? k.duration_s
                                                  : 0.0;
  const uint64_t interp_frames =
      static_cast<uint64_t>(std::llround(interp_s * sample_rate));
  if (interp_frames == 0) return {k.position, k.gain};

  const double t = std::min(1.0, static_cast<double>(frame - start_frame[cur]) /
                                     static_cast<double>(interp_frames));
  const ObjectKeyframe& prev = timeline[cur - 1];
  ObjectPosition p;
  if (k.position.cartesian) {
    // Cube-space lerp: a straight line in the room stays a straight line.
    const Cube a = AsCube(prev.position);
    const Cube& b = k.position.cube;
    p.cartesian = true;
    p.cube = {Lerp(a.x, b.x, t), Lerp(a.y, b.y, t), Lerp(a.z, b.z, t)};
  } else {
    const Polar a = AsPolar(prev.position);
    const Polar& b = k.position.polar;
    p.polar.azimuth = LerpAngle(a.azimuth, b.azimuth, t);
    p.polar.elevation = Lerp(a.elevation, b.elevation, t);
    p.polar.distance = Lerp(a.distance, b.distance, t);
  }
  return {p, Lerp(prev.gain, k.gain, t)};
}

}  // namespace adm2iamf
