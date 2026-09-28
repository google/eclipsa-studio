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

#include "adm_import/scene/bs2127.h"

#include <cmath>

#include "gtest/gtest.h"

namespace adm2iamf {
namespace bs2127 {
namespace {

// The headline behavior: the front-right cube corner [1,1,0] maps to azimuth
// -30 (a real loudspeaker direction), NOT the naive atan2 result of -45.
TEST(Bs2127, CornersMapToNominalSpeakerAzimuths) {
  struct Case {
    double x, y, z, az, el, d;
  };
  const Case cases[] = {
      {0, 1, 0, 0, 0, 1},      // front centre
      {1, 1, 0, -30, 0, 1},    // front right
      {-1, 1, 0, 30, 0, 1},    // front left
      {1, -1, 0, -110, 0, 1},  // back right
      {-1, -1, 0, 110, 0, 1},  // back left
  };
  for (const Case& c : cases) {
    Sph s = CartToPolar(c.x, c.y, c.z);
    EXPECT_NEAR(s.azimuth, c.az, 1e-6) << "pos " << c.x << "," << c.y;
    EXPECT_NEAR(s.elevation, c.el, 1e-6);
    EXPECT_NEAR(s.distance, c.d, 1e-6);
  }
  // Differs from the naive egocentric interpretation (the bug we replace).
  EXPECT_NEAR(Azimuth(1.0, 1.0), -45.0, 1e-9);             // naive
  EXPECT_NEAR(CartToPolar(1, 1, 0).azimuth, -30.0, 1e-6);  // BS.2127
}

// Elevation is warped: el_top (30) maps onto el_top_tilde (45) geometrically.
TEST(Bs2127, ElevationWarpTopRow) {
  Cart c = PolarToCart(0.0, 30.0, 1.0);
  EXPECT_NEAR(c.x, 0.0, 1e-6);
  EXPECT_NEAR(c.y, 1.0, 1e-6);
  EXPECT_NEAR(c.z, 1.0, 1e-6);  // tan(45)=1 -> geometric elevation 45.
  EXPECT_NEAR(Elevation(c.x, c.y, c.z), 45.0, 1e-6);
}

// Straight up/down and the origin are handled without division blow-ups.
TEST(Bs2127, PolesAndOrigin) {
  Sph up = CartToPolar(0, 0, 0.7);
  EXPECT_NEAR(up.elevation, 90.0, 1e-9);
  EXPECT_NEAR(up.distance, 0.7, 1e-9);
  Sph down = CartToPolar(0, 0, -0.5);
  EXPECT_NEAR(down.elevation, -90.0, 1e-9);
  Sph origin = CartToPolar(0, 0, 0);
  EXPECT_NEAR(origin.distance, 0.0, 1e-9);
}

// cart -> polar -> cart is the identity across the cube (the converter is built
// to be invertible for point sources).
TEST(Bs2127, RoundTripCartPolarCart) {
  for (double x = -1.0; x <= 1.0; x += 0.5) {
    for (double y = -1.0; y <= 1.0; y += 0.5) {
      for (double z = -1.0; z <= 1.0; z += 0.5) {
        if (std::fabs(x) < 1e-9 && std::fabs(y) < 1e-9 && std::fabs(z) < 1e-9) {
          continue;
        }
        Sph s = CartToPolar(x, y, z);
        Cart c = PolarToCart(s.azimuth, s.elevation, s.distance);
        EXPECT_NEAR(c.x, x, 1e-6) << x << "," << y << "," << z;
        EXPECT_NEAR(c.y, y, 1e-6) << x << "," << y << "," << z;
        EXPECT_NEAR(c.z, z, 1e-6) << x << "," << y << "," << z;
      }
    }
  }
}

}  // namespace
}  // namespace bs2127
}  // namespace adm2iamf
