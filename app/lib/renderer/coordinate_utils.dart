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

import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';

/// # Coordinate Conventions
///
/// ## ADM / Audio Domain (source of truth for positions & algorithms)
///
/// ITU-R BS.2076 / ADM / EBU ADM convention:
///
/// - **Spherical**: azimuth (°), elevation (°), distance
///   - Azimuth: 0° = front, **positive = left** (counter-clockwise from above)
///   - Elevation: 0° = horizontal, positive = up, negative = down
///   - Distance: 1.0 = unit sphere
///
/// - **Cartesian** (right-handed, Y-up):
///   - +X = **left** (positive azimuth direction)
///   - +Y = **up**
///   - +Z = **front** (0° azimuth)
///
/// All audio algorithms, ADM import/export, and panning calculations
/// use this convention exclusively.
///
/// ## 3D Graphics / Visualizer Domain
///
/// Standard right-handed OpenGL / Three.js / Flutter convention:
///
/// - +X = **right**
/// - +Y = **up**
/// - +Z = **toward viewer** (out of screen)
/// - Camera default: positioned on +Z, looking toward origin
///
/// ## Conversion: Audio → Visualizer
///
/// ```
///   viz.x = -audio.x    (flip left→right)
///   viz.y =  audio.y    (Y-up preserved)
///   viz.z = -audio.z    (flip front→toward-viewer)
/// ```
///
/// Both systems are right-handed; the transform is a 180° rotation
/// around the Y axis (equivalent to negating X and Z).
///
/// ## Usage Rules
///
/// - `SceneData`, `AudioObject`, `SpeakerLayout` — ADM spherical degrees
/// - `CoordinateUtils.sphericalToCartesian` — ADM Cartesian
/// - `CoordinateUtils.audioToVisualizer` — converts to graphics coords
/// - `RenderableScene` positions — **always in visualizer coords**
/// - Renderers (software, three_js) — consume visualizer coords directly
/// - Never mix conventions within a single coordinate space
class CoordinateUtils {
  CoordinateUtils._();

  /// Spherical (degrees, ADM) → Cartesian (ADM).
  ///
  /// ADM Cartesian: +X=left, +Y=up, +Z=front.
  static Vector3 sphericalToCartesian(
    double azDeg,
    double elDeg,
    double distance,
  ) {
    final azRad = azDeg * degrees2Radians;
    final elRad = elDeg * degrees2Radians;
    final cosEl = math.cos(elRad);
    return Vector3(
      distance * cosEl * math.sin(azRad), // X: left (positive az = left)
      distance * math.sin(elRad), // Y: up
      distance * cosEl * math.cos(azRad), // Z: front
    );
  }

  /// Cartesian (ADM) → Spherical (degrees, ADM).
  static (double azDeg, double elDeg, double distance) cartesianToSpherical(
    Vector3 v,
  ) {
    final distance = v.length;
    if (distance < 1e-10) return (0, 0, 0);
    final elRad = math.asin((v.y / distance).clamp(-1.0, 1.0));
    final azRad = math.atan2(v.x, v.z);
    return (azRad * radians2Degrees, elRad * radians2Degrees, distance);
  }

  /// ADM Cartesian → Visualizer Cartesian.
  ///
  /// ADM:        +X=left,  +Y=up, +Z=front
  /// Visualizer: +X=right, +Y=up, +Z=toward viewer (out of screen)
  ///
  /// Transform: 180° rotation around Y axis (negate X and Z).
  static Vector3 audioToVisualizer(Vector3 audio) {
    return Vector3(-audio.x, audio.y, -audio.z);
  }

  /// Visualizer Cartesian → ADM Cartesian.
  static Vector3 visualizerToAudio(Vector3 viz) {
    return Vector3(-viz.x, viz.y, -viz.z);
  }

  /// Spherical (degrees, ADM) → Visualizer Cartesian (for renderers).
  static Vector3 sphericalToVisualizer(
    double azDeg,
    double elDeg,
    double distance,
  ) {
    return audioToVisualizer(sphericalToCartesian(azDeg, elDeg, distance));
  }
}
