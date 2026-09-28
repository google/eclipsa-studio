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

/// Meter ballistics math for the app_shell tick loop.
///
/// Pure functions (no Riverpod / Flutter dependencies) so the release
/// behavior that drives every meter bar, peak-hold line, and clip
/// indicator is unit-testable — a silent regression here corrupts all
/// metering with no other CI signal.

/// Exponential release rate for meter falls. Expressed in dB/s and
/// converted per tick (see [meterDecayFactor]), so the fall time is
/// identical at any display refresh rate (20 dB in ~300 ms).
const double kMeterReleaseDbPerSec = 200.0 / 3.0; // 20 dB per 300 ms

/// Below this linear level a decaying meter snaps to exactly 0.
const double kMeterFloor = 0.001;

/// Sanitize a tick delta before it feeds the decay math.
///
/// Guards against negative and non-finite deltas (a defensive zero —
/// the ticker clock is monotonic, and a NaN here would poison every
/// downstream meter value). Deliberately NO upper clamp: when the
/// ticker resumes after the window was hidden or occluded, the first
/// tick spans the whole gap, and the release must fast-forward through
/// that wall-clock time so stale levels collapse straight to idle
/// instead of lingering and re-animating their fall (ES-452).
/// [meterDecayFactor] underflows harmlessly to 0 for arbitrarily long
/// gaps.
double sanitizeMeterDt(double dtSeconds) =>
    dtSeconds.isFinite && dtSeconds >= 0 ? dtSeconds : 0.0;

/// This tick's linear release multiplier for a frame of [dtSeconds].
double meterDecayFactor(double dtSeconds) =>
    math.pow(10, -kMeterReleaseDbPerSec * dtSeconds / 20).toDouble();

/// Decay one channel row: instant attack, exponential release by
/// [decayFactor] (this tick's linear multiplier from [meterDecayFactor]).
List<double> decayRow(
  List<double> raw,
  List<double> old,
  int len,
  double decayFactor,
) {
  final ch = <double>[];
  for (var c = 0; c < len; c++) {
    final r = (c < raw.length) ? raw[c] : 0.0;
    var decayed = (c < old.length) ? old[c] * decayFactor : 0.0;
    if (decayed < kMeterFloor) decayed = 0.0;
    ch.add(r > decayed ? r : decayed);
  }
  return ch;
}

/// Decay per-element per-channel meters with ballistic fall-off.
/// When not [playing], raw input is treated as silence so the bars
/// fade out at the release rate instead of freezing.
List<List<double>> applyMeterDecay(
  List<List<double>> current,
  List<List<double>> previous,
  bool playing,
  double decayFactor,
) {
  final result = <List<double>>[];
  for (var i = 0; i < current.length; i++) {
    final raw = playing ? current[i] : const <double>[];
    final old = (i < previous.length) ? previous[i] : const <double>[];
    final len = raw.isNotEmpty ? raw.length : old.length;
    result.add(decayRow(raw, old, len, decayFactor));
  }
  return result;
}

/// Element-wise equality for a row of clip flags.
bool boolRowEquals(List<bool> a, List<bool> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Element-wise equality for a grid of clip flags.
bool boolGridEquals(List<List<bool>> a, List<List<bool>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!boolRowEquals(a[i], b[i])) return false;
  }
  return true;
}
