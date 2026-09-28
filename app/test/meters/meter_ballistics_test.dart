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

import 'package:eclipsa_studio/meters/meter_ballistics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('meterDecayFactor', () {
    test('falls 20 dB in 300 ms regardless of tick rate', () {
      // One 300 ms tick.
      expect(meterDecayFactor(0.3), closeTo(0.1, 1e-9));
      // Eighteen 60 Hz ticks (300 ms) compound to the same fall.
      final perTick = meterDecayFactor(0.3 / 18);
      expect(math.pow(perTick, 18).toDouble(), closeTo(0.1, 1e-9));
    });

    test('zero dt means no decay', () {
      expect(meterDecayFactor(0), 1.0);
    });
  });

  group('sanitizeMeterDt', () {
    test('zeroes negative and non-finite deltas', () {
      expect(sanitizeMeterDt(-0.016), 0.0);
      expect(sanitizeMeterDt(double.nan), 0.0);
      expect(sanitizeMeterDt(double.infinity), 0.0);
      expect(sanitizeMeterDt(double.negativeInfinity), 0.0);
    });

    test('passes normal ticks and long gaps through unclamped (ES-452)', () {
      expect(sanitizeMeterDt(1 / 60), 1 / 60);
      expect(sanitizeMeterDt(2.0), 2.0);
      expect(sanitizeMeterDt(7200.0), 7200.0);
    });

    test('a suspended-ticker gap collapses a full-scale bar to zero', () {
      // 2 s of release at 20 dB/300 ms is a ~133 dB fall — one tick
      // spanning the gap must land below the floor and snap to 0, so
      // meters come back idle after the window was hidden (ES-452).
      final out = decayRow([0.0], [1.0], 1, meterDecayFactor(2.0));
      expect(out, [0.0]);
    });
  });

  group('decayRow', () {
    test('instant attack: raw above decayed old wins', () {
      final out = decayRow([0.8], [0.5], 1, 0.9);
      expect(out, [0.8]);
    });

    test('exponential release: old * decayFactor floors the fall', () {
      final out = decayRow([0.1], [0.5], 1, 0.9);
      expect(out, [closeTo(0.45, 1e-12)]);
    });

    test('snaps to zero below the floor', () {
      final out = decayRow([0.0], [kMeterFloor], 1, 0.9);
      expect(out, [0.0]);
    });

    test('pads missing raw and old channels with silence', () {
      final out = decayRow([0.4], [0.6, 0.2], 3, 0.5);
      expect(out[0], 0.4); // raw wins over 0.3
      expect(out[1], closeTo(0.1, 1e-12)); // no raw, decays old
      expect(out[2], 0.0); // neither raw nor old
    });
  });

  group('applyMeterDecay', () {
    test('playing: attacks track raw, falls are clamped to release', () {
      final out = applyMeterDecay(
        [
          [0.9, 0.1],
        ],
        [
          [0.5, 0.5],
        ],
        true,
        0.8,
      );
      expect(out, [
        [0.9, closeTo(0.4, 1e-12)],
      ]);
    });

    test('paused: raw is silenced so bars fade at the release rate', () {
      final out = applyMeterDecay(
        [
          [0.9, 0.9],
        ],
        [
          [0.5, 0.5],
        ],
        false,
        0.8,
      );
      expect(out, [
        [closeTo(0.4, 1e-12), closeTo(0.4, 1e-12)],
      ]);
    });

    test('new element with no previous state starts from silence', () {
      final out = applyMeterDecay(
        [
          [0.3],
          [0.7],
        ],
        [
          [0.5],
        ],
        true,
        0.5,
      );
      expect(out, [
        [0.3],
        [0.7],
      ]);
    });
  });

  group('clip-flag equality', () {
    test('boolRowEquals compares by value and length', () {
      expect(boolRowEquals([true, false], [true, false]), isTrue);
      expect(boolRowEquals([true], [true, false]), isFalse);
      expect(boolRowEquals([true, false], [true, true]), isFalse);
      expect(boolRowEquals([], []), isTrue);
    });

    test('boolGridEquals compares nested rows', () {
      expect(
        boolGridEquals(
          [
            [true],
            [false, true],
          ],
          [
            [true],
            [false, true],
          ],
        ),
        isTrue,
      );
      expect(
        boolGridEquals(
          [
            [true],
          ],
          [
            [false],
          ],
        ),
        isFalse,
      );
      expect(
        boolGridEquals(
          [
            [true],
          ],
          [
            [true],
            [true],
          ],
        ),
        isFalse,
      );
    });
  });
}
