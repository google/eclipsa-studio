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

import 'package:eclipsa_studio/meters/db_utils.dart';
import 'package:eclipsa_studio/meters/peak_hold.dart';
import 'package:flutter_test/flutter_test.dart';

/// The limiter-gain → GR-depth conversion behind both the live GR bar
/// and its peak hold. Shared by two call sites (the bar's fill and the
/// tick loop that feeds the hold), so a drift here would put the mark
/// and the bar at different depths.
void main() {
  group('DbUtils.linearGrToDb', () {
    test('reports reduction as a positive magnitude', () {
      // Half amplitude is 6.02 dB down; the GR lane convention makes
      // that +6, not -6.
      expect(DbUtils.linearGrToDb(0.5), closeTo(6.02, 0.01));
      expect(DbUtils.linearGrToDb(0.891), closeTo(1.0, 0.01));
    });

    test('unity and above are no reduction', () {
      expect(DbUtils.linearGrToDb(1.0), 0.0);
      // The envelope can read fractionally over unity between writes;
      // that is not gain, and must not draw a bar below zero.
      expect(DbUtils.linearGrToDb(1.5), 0.0);
    });

    test('a non-finite read shows nothing rather than poisoning the meter', () {
      // The value crosses the FFI from shared memory the audio thread
      // is writing concurrently.
      expect(DbUtils.linearGrToDb(double.nan), 0.0);
      expect(DbUtils.linearGrToDb(double.infinity), 0.0);
    });

    test('zero gain caps instead of returning infinity', () {
      // Infinity fed to the peak hold would never decay back out of
      // the display — the hold multiplies by a decay factor.
      expect(DbUtils.linearGrToDb(0.0), DbUtils.maxGrDb);
      expect(DbUtils.linearGrToDb(-1.0), DbUtils.maxGrDb);
      expect(DbUtils.maxGrDb.isFinite, isTrue);
    });
  });

  group('GR peak hold', () {
    test('holds the deepest reduction, then falls back to zero', () {
      final tracker = PeakHoldTracker(holdSeconds: 2.0);

      // A 6 dB transient is captured instantly.
      expect(tracker.update([6.0], 0.016, 0.9)[0], 6.0);
      // ... and survives while the reduction recovers, which is the
      // whole point: a one-frame dip would otherwise leave no mark.
      expect(tracker.update([0.0], 0.016, 0.9)[0], 6.0);
      expect(tracker.update([0.0], 1.0, 0.9)[0], 6.0);

      // Past the hold window it decays, and reaches zero rather than
      // sticking at a floor value.
      var held = tracker.update([0.0], 1.5, 0.9)[0];
      expect(held, lessThan(6.0));
      for (var i = 0; i < 500 && held > 0; i++) {
        held = tracker.update([0.0], 0.016, 0.9)[0];
      }
      expect(held, 0.0);
    });

    test('a deeper hit takes over the hold immediately', () {
      final tracker = PeakHoldTracker(holdSeconds: 2.0);
      tracker.update([3.0], 0.016, 0.9);
      expect(tracker.update([9.0], 0.016, 0.9)[0], 9.0);
    });
  });
}
