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

import 'package:eclipsa_studio/meters/meter_ballistics.dart';
import 'package:eclipsa_studio/meters/peak_hold.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PeakHoldTracker', () {
    test('instant attack and hold within the hold window', () {
      final tracker = PeakHoldTracker(holdSeconds: 2.0);
      expect(tracker.update([0.8], 1 / 60, meterDecayFactor(1 / 60)), [0.8]);
      // Level drops; hold stands for the hold window.
      expect(tracker.update([0.1], 1.0, meterDecayFactor(1.0)), [0.8]);
    });

    test('falls at the release rate after the hold window', () {
      final tracker = PeakHoldTracker(holdSeconds: 2.0);
      tracker.update([0.8], 1 / 60, meterDecayFactor(1 / 60));
      final held = tracker.update([0.0], 1.9, meterDecayFactor(1.9));
      expect(held, [0.8]); // still inside the hold window
      // The next 0.3 s of ticks land past the window and release:
      // 20 dB down in 300 ms.
      tracker.update([0.0], 0.1, meterDecayFactor(0.1));
      final out = tracker.update([0.0], 0.2, meterDecayFactor(0.2));
      expect(out, [closeTo(0.08, 1e-9)]);
    });

    test('a suspended-ticker gap collapses the hold to zero (ES-452)', () {
      final tracker = PeakHoldTracker(holdSeconds: 2.0);
      tracker.update([0.8], 1 / 60, meterDecayFactor(1 / 60));
      // One tick spanning a long hidden-window gap: the hold window
      // expired long ago and the release fast-forwards to the floor.
      final out = tracker.update([0.0], 60.0, meterDecayFactor(60.0));
      expect(out, [0.0]);
    });
  });
}
