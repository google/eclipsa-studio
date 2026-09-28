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

/// Peak-hold ballistics for meter displays.
///
/// Tracks the highest recent value per channel: instant attack, a hold
/// window of [holdSeconds], then a fall at the caller-supplied per-tick
/// [decayFactor]. Fed the raw per-block peaks; the hold line always
/// sits at or above the RMS bar it annotates (peak ≥ RMS).
class PeakHoldTracker {
  PeakHoldTracker({this.holdSeconds = 2.0});

  final double holdSeconds;

  /// Below this the hold snaps to zero (matches the bar decay floor).
  static const double _floor = 0.001;

  final List<double> _holds = [];
  final List<double> _ages = [];

  /// Advance one tick and return a fresh list of hold values.
  ///
  /// [levels] are the displayed linear levels this frame, [dt] the tick
  /// delta in seconds, [decayFactor] the per-tick linear decay multiplier.
  List<double> update(List<double> levels, double dt, double decayFactor) {
    final n = levels.length;
    if (_holds.length > n) {
      _holds.length = n;
      _ages.length = n;
    }
    while (_holds.length < n) {
      _holds.add(0);
      _ages.add(0);
    }
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final level = levels[i];
      var hold = _holds[i];
      if (level >= hold) {
        hold = level;
        _ages[i] = 0;
      } else {
        _ages[i] += dt;
        if (_ages[i] >= holdSeconds) {
          hold = math.max(level, hold * decayFactor);
        }
        if (hold < _floor) hold = 0;
      }
      _holds[i] = hold;
      out[i] = hold;
    }
    return out;
  }

  void reset() {
    _holds.clear();
    _ages.clear();
  }
}

/// [PeakHoldTracker] over a list of channel groups (one row per element).
class NestedPeakHoldTracker {
  NestedPeakHoldTracker({this.holdSeconds = 2.0});

  final double holdSeconds;
  final List<PeakHoldTracker> _rows = [];

  /// Advance one tick and return fresh nested hold lists.
  List<List<double>> update(
    List<List<double>> levels,
    double dt,
    double decayFactor,
  ) {
    final n = levels.length;
    if (_rows.length > n) _rows.length = n;
    while (_rows.length < n) {
      _rows.add(PeakHoldTracker(holdSeconds: holdSeconds));
    }
    return List<List<double>>.generate(
      n,
      (i) => _rows[i].update(levels[i], dt, decayFactor),
    );
  }

  void reset() {
    for (final row in _rows) {
      row.reset();
    }
  }
}
