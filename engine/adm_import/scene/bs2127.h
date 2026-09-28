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

// ITU-R BS.2127 (EBU ADM Renderer) allocentric Cartesian <-> egocentric polar
// coordinate conversion, §10 ("Conversion between Cartesian and polar").
//
// Cartesian ADM objects are authored in an *allocentric* room cube
// ([-1,1]^3, x=right,
// y=front, z=up). Mapping a cube point to a listener-relative direction is NOT
// `atan2` + vector-norm (that egocentric interpretation is the iamf-tools
// panner bug, and is also what OAR's own cart_to_polar does). BS.2127 instead
// warps the cube through a 5-sector piecewise mapping so e.g. the front-right
// corner [1,1,0] resolves to azimuth -30 (a real loudspeaker direction), not
// -45.
//
// We keep OLR as the panner (objects match Eclipsa Studio's monitoring), so the
// converter's job is purely to hand OLR the correct egocentric (az, el, dist).
// Ported from the EBU EAR reference (ear/core/objectbased/conversion.py,
// ear/core/geom.py); BSD-3-Clause. Computation is in double precision.

#ifndef ADM2IAMF_SCENE_BS2127_H_
#define ADM2IAMF_SCENE_BS2127_H_

namespace adm2iamf {
namespace bs2127 {

struct Cart {
  double x = 0.0;  // +right
  double y = 0.0;  // +front
  double z = 0.0;  // +up
};

struct Sph {
  double azimuth = 0.0;    // Degrees, + = left (ADM/OAR convention).
  double elevation = 0.0;  // Degrees, + = up.
  double distance = 0.0;   // Cube-relative; callers clamp to [0,1] (§7.3.1).
};

// Egocentric azimuth/elevation of a Cartesian point (the naive interpretation;
// exposed for tests and for the sector search). Matches OAR's utils.c.
double Azimuth(double x, double y);
double Elevation(double x, double y, double z);

// BS.2127 §10 conversions.
Cart PolarToCart(double azimuth, double elevation, double distance);
Sph CartToPolar(double x, double y, double z);

}  // namespace bs2127
}  // namespace adm2iamf

#endif  // ADM2IAMF_SCENE_BS2127_H_
