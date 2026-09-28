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

/// Decibel utilities for audio level calculations.
class DbUtils {
  DbUtils._();

  /// Linear amplitude (0..1+) → dBFS.
  static double linearToDb(double linear) {
    if (linear <= 0) return -120.0;
    return 20 * math.log(linear) / math.ln10;
  }

  /// dBFS → linear amplitude.
  static double dbToLinear(double db) {
    return math.pow(10, db / 20).toDouble();
  }

  /// Largest reduction [linearGrToDb] will report. A limiter gain of
  /// zero is infinite reduction, and infinity fed to a peak hold never
  /// decays out of the display — so cap it at a depth far past any
  /// real limiting instead.
  static const double maxGrDb = 60.0;

  /// Limiter gain (linear, 1.0 = no reduction) → dB of reduction as a
  /// POSITIVE magnitude, the sign convention the Loudness Report's GR
  /// lane and the live GR bar both use.
  ///
  /// Unity and above report no reduction. So does a non-finite read:
  /// this value crosses the FFI from shared memory the audio thread is
  /// writing concurrently, and a NaN there should read as "nothing to
  /// show", not poison the meter.
  static double linearGrToDb(double gr) {
    if (!gr.isFinite || gr >= 1.0) return 0.0;
    if (gr <= 0.0) return maxGrDb;
    return math.min(maxGrDb, -20 * math.log(gr) / math.ln10);
  }

  /// Normalize a dB value to 0..1 range given a floor and ceiling.
  static double normalizeDb(double db, {double floor = -60, double ceil = 0}) {
    return ((db - floor) / (ceil - floor)).clamp(0.0, 1.0);
  }

  /// Linear amplitude → normalized 0..1 (via dB mapping).
  static double linearToNormalized(
    double linear, {
    double floor = -60,
    double ceil = 0,
  }) {
    return normalizeDb(linearToDb(linear), floor: floor, ceil: ceil);
  }
}
