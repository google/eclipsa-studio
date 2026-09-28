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

// Display-matrix helpers, kept free of FFmpeg includes so they are
// unit-testable without the decoder's FFmpeg dependency.

#ifndef ECLIPSA_STUDIO_VIDEO_ROTATION_H_
#define ECLIPSA_STUDIO_VIDEO_ROTATION_H_

#include <cmath>
#include <cstdint>

namespace eclipsa_studio::video {

// Converts the angle returned by FFmpeg's av_display_rotation_get() to the
// number of clockwise quarter turns (0-3) the decoded frame needs for
// display. av_display_rotation_get() returns the counterclockwise rotation
// of the display matrix in degrees, in [-180, 180], or NaN when the matrix
// is degenerate. A portrait phone recording stored as a landscape frame
// reports -90, which is 1 clockwise quarter turn. Angles that are not a
// multiple of 90 degrees round to the nearest quarter turn, with halves
// rounding away from zero. Non-finite input returns 0.
inline int QuarterTurnsClockwise(double ccw_degrees) {
  if (!std::isfinite(ccw_degrees)) return 0;
  const int turns = static_cast<int>(std::lround(-ccw_degrees / 90.0)) % 4;
  return turns < 0 ? turns + 4 : turns;
}

// Returns true when the 3x3 display matrix (FFmpeg's 16.16 fixed-point
// AV_PKT_DATA_DISPLAYMATRIX layout) flips the picture, i.e. its 2x2
// rotation/scale part has a negative determinant.
// av_display_rotation_get() reads a horizontal flip as a 180-degree turn,
// so a flipped matrix must not be converted with QuarterTurnsClockwise().
inline bool IsMirrored(const int32_t matrix[9]) {
  const int64_t det = static_cast<int64_t>(matrix[0]) * matrix[4] -
                      static_cast<int64_t>(matrix[1]) * matrix[3];
  return det < 0;
}

}  // namespace eclipsa_studio::video

#endif  // ECLIPSA_STUDIO_VIDEO_ROTATION_H_
