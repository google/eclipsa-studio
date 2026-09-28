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

/// IAMF fixed-point encoding helpers.
///
/// The bitstream stores gains and loudness values as signed 16-bit
/// integers in Q7.8 fixed-point — 256 ticks per dB, range
/// [-32768 / 256, 32767 / 256] dB ≈ [-128, +127.996] dB.
///
/// Angles are similarly packed: azimuth is 9-bit in [-180, 180],
/// elevation 8-bit in [-90, 90], and (per this project's convention)
/// object distance is normalized 0..1 into a 7-bit field.
///
/// Keeping these helpers pure Dart (no IAMF protos) makes them trivial
/// to unit-test.
library;

const int _kInt16Min = -32768;
const int _kInt16Max = 32767;

/// Convert a floating-point dB value to IAMF's Q7.8 int16 representation.
/// Clamps to int16 range. NaN → 0.
int dbToQ7_8(double db) {
  if (db.isNaN) return 0;
  final scaled = (db * 256).round();
  return scaled.clamp(_kInt16Min, _kInt16Max);
}

/// Convert a floating-point LUFS value to IAMF's Q7.8 int16
/// representation. Uses the same encoding as [dbToQ7_8] since LUFS is
/// a dB-scaled unit.
int lufsToQ7_8(double lufs) => dbToQ7_8(lufs);

/// Encode an azimuth angle in degrees to the IAMF 9-bit signed integer
/// range. Wraps the input to (-180, 180] first, then rounds. The
/// boundary maps to +180 to match OAR's conventions (OBR normalizes to
/// (-180, 180]; OLR's back-center speaker sits at exactly +180) and the
/// live-monitoring wrap in state.dart.
int encodeAzimuth(double degrees) {
  final wrapped = _wrapSigned(degrees, 180);
  return wrapped.round().clamp(-180, 180);
}

/// Encode an elevation angle in degrees. Clamps to [-90, 90] without
/// wrapping — elevations outside that range indicate a bug upstream.
int encodeElevation(double degrees) {
  return degrees.round().clamp(-90, 90);
}

/// Encode a normalized distance (Eclipsa Studio stores distance as 0..1) into
/// IAMF's 7-bit distance field. Maps 0.0 → 0 and 1.0 → 127. Values
/// outside [0, 1] are clamped.
int encodeNormalizedDistance(double d) {
  if (d.isNaN) return 0;
  final clamped = d.clamp(0.0, 1.0);
  return (clamped * 127).round();
}

/// Split a dual-object center + spread into two azimuths. Returns
/// `(firstAz, secondAz)`. Elevation and distance are shared — the
/// caller handles those fields itself.
///
/// The first azimuth belongs to object channel 0 (the WAV's left
/// channel). Positive azimuth is left (ADM), so channel 0 sits at
/// center + spread/2 — the same split the scene visualizer uses.
///
/// Spread is expected in [0, 180] degrees. Values outside that range
/// are clamped.
({int firstAzimuth, int secondAzimuth}) splitDualAzimuth({
  required double centerAzimuth,
  required double spread,
}) {
  final s = spread.clamp(0.0, 180.0);
  final half = s / 2;
  return (
    firstAzimuth: encodeAzimuth(centerAzimuth + half),
    secondAzimuth: encodeAzimuth(centerAzimuth - half),
  );
}

// ── Internals ───────────────────────────────────────────────────────────

/// Wrap a signed angle into (-bound, bound]. `bound = 180` for azimuth.
double _wrapSigned(double value, double bound) {
  final period = bound * 2;
  return bound - (bound - value) % period;
}
