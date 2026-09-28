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

#include <array>
#include <cmath>
#include <cstddef>

namespace adm2iamf {
namespace bs2127 {
namespace {

constexpr double kPi = 3.14159265358979323846;
double Rad(double d) { return d * kPi / 180.0; }
double Deg(double r) { return r * 180.0 / kPi; }

// BS.2127 §10 allocentric mapping: nominal azimuth -> cube position (z=0).
struct Sector {
  double az;
  double x;
  double y;
};
constexpr std::array<Sector, 5> kMapping = {{
    {0.0, 0.0, 1.0},
    {-30.0, 1.0, 1.0},
    {-110.0, 1.0, -1.0},
    {110.0, -1.0, -1.0},
    {30.0, -1.0, 1.0},
}};
constexpr double kElTop = 30.0;
constexpr double kElTopTilde = 45.0;

// Shift y (clockwise from x) up by 360 until it is >= x.
double RelativeAngle(double x, double y) {
  while (y - 360.0 >= x) y -= 360.0;
  while (y < x) y += 360.0;
  return y;
}

// Is angle x within [start, end] (end clockwise from start), +/- tol?
bool InsideAngleRange(double x, double start, double end, double tol = 0.0) {
  while (end - 360.0 > start) end -= 360.0;
  while (end < start) end += 360.0;
  const double start_tol = start - tol;
  while (x - 360.0 >= start_tol) x -= 360.0;
  while (x < start_tol) x += 360.0;
  return x <= end + tol;
}

double MapAzToLinear(double left_az, double right_az, double azimuth) {
  const double mid_az = (left_az + right_az) / 2.0;
  const double az_range = right_az - mid_az;
  const double rel_az = azimuth - mid_az;
  const double gain_r =
      0.5 + 0.5 * std::tan(Rad(rel_az)) / std::tan(Rad(az_range));
  return std::atan2(gain_r, 1.0 - gain_r) * (2.0 / kPi);
}

double MapLinearToAz(double left_az, double right_az, double x) {
  const double mid_az = (left_az + right_az) / 2.0;
  const double az_range = right_az - mid_az;
  const double gain_l = std::cos(x * (kPi / 2.0));
  const double gain_r_raw = std::sin(x * (kPi / 2.0));
  const double gain_r = gain_r_raw / (gain_l + gain_r_raw);
  const double rel_az =
      Deg(std::atan(2.0 * (gain_r - 0.5) * std::tan(Rad(az_range))));
  return mid_az + rel_az;
}

// Sector whose nominal azimuth range contains `az` (for polar -> cart).
void FindSector(double az, int& i_out, int& j_out) {
  const int n = static_cast<int>(kMapping.size());
  for (int i = 0; i < n; ++i) {
    const int j = (i + 1) % n;
    if (InsideAngleRange(az, kMapping[j].az, kMapping[i].az)) {
      i_out = i;
      j_out = j;
      return;
    }
  }
  i_out = 0;
  j_out = 1;  // Unreachable: the mapping covers the full circle.
}

// Sector whose *geometric* (position) azimuth range contains `az`.
void FindCartSector(double az, int& i_out, int& j_out) {
  const int n = static_cast<int>(kMapping.size());
  for (int i = 0; i < n; ++i) {
    const int j = (i + 1) % n;
    const double start = Azimuth(kMapping[j].x, kMapping[j].y);
    const double end = Azimuth(kMapping[i].x, kMapping[i].y);
    if (InsideAngleRange(az, start, end)) {
      i_out = i;
      j_out = j;
      return;
    }
  }
  i_out = 0;
  j_out = 1;
}

}  // namespace

double Azimuth(double x, double y) { return -Deg(std::atan2(x, y)); }

double Elevation(double x, double y, double z) {
  return Deg(std::atan2(z, std::hypot(x, y)));
}

Cart PolarToCart(double azimuth, double elevation, double distance) {
  double el_tilde, z, r_xy;
  if (std::fabs(elevation) > kElTop) {
    el_tilde = kElTopTilde + (90.0 - kElTopTilde) *
                                 (std::fabs(elevation) - kElTop) /
                                 (90.0 - kElTop);
    z = distance * (elevation >= 0.0 ? 1.0 : -1.0);
    r_xy = distance * std::tan(Rad(90.0 - el_tilde));
  } else {
    el_tilde = kElTopTilde * elevation / kElTop;
    z = std::tan(Rad(el_tilde)) * distance;
    r_xy = distance;
  }

  int i, j;
  FindSector(azimuth, i, j);
  const double left_az = kMapping[i].az, right_az = kMapping[j].az;
  const double rel_az = RelativeAngle(right_az, azimuth);
  const double rel_left_az = RelativeAngle(right_az, left_az);
  const double p = MapAzToLinear(rel_left_az, right_az, rel_az);

  const double lx = kMapping[i].x, ly = kMapping[i].y;
  const double rx = kMapping[j].x, ry = kMapping[j].y;
  return {r_xy * (lx + (rx - lx) * p), r_xy * (ly + (ry - ly) * p), z};
}

Sph CartToPolar(double x, double y, double z) {
  constexpr double kEps = 1e-10;
  if (std::fabs(x) < kEps && std::fabs(y) < kEps) {
    if (std::fabs(z) < kEps) return {0.0, 0.0, 0.0};
    return {0.0, (z >= 0.0 ? 1.0 : -1.0) * 90.0, std::fabs(z)};
  }

  int i, j;
  FindCartSector(Azimuth(x, y), i, j);
  const double left_az = kMapping[i].az, right_az = kMapping[j].az;
  const double lx = kMapping[i].x, ly = kMapping[i].y;
  const double rx = kMapping[j].x, ry = kMapping[j].y;

  // g_lr = [x, y] * inv([[lx, ly], [rx, ry]]) -> gains on the two sector edges.
  const double det = lx * ry - ly * rx;
  const double g_l = (x * ry - y * rx) / det;
  const double g_r = (y * lx - x * ly) / det;
  const double r_xy = g_l + g_r;

  const double rel_left_az = RelativeAngle(right_az, left_az);
  double az = MapLinearToAz(rel_left_az, right_az, g_r / r_xy);
  az = RelativeAngle(-180.0, az);

  const double el_tilde = Deg(std::atan(z / r_xy));
  double el, d;
  if (std::fabs(el_tilde) > kElTopTilde) {
    const double abs_el = kElTop + (90.0 - kElTop) *
                                       (std::fabs(el_tilde) - kElTopTilde) /
                                       (90.0 - kElTopTilde);
    el = (el_tilde >= 0.0 ? 1.0 : -1.0) * abs_el;
    d = std::fabs(z);
  } else {
    el = kElTop * el_tilde / kElTopTilde;
    d = r_xy;
  }
  return {az, el, d};
}

}  // namespace bs2127
}  // namespace adm2iamf
