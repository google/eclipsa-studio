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

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the latch semantics behind the rate-follow retry fix (ES-33):
/// a (device, hw-rate) pair that already failed adoption must not be
/// retried, but any change to the pair — a new hardware rate or a new
/// device — re-arms the attempt.
void main() {
  group('RateFollowLatch', () {
    test('starts clear and matches nothing', () {
      final latch = RateFollowLatch();
      expect(latch.isSet, isFalse);
      expect(latch.matches(0, 44100), isFalse);
    });

    test('matches exactly the latched pair', () {
      final latch = RateFollowLatch();
      latch.set(2, 44100);
      expect(latch.isSet, isTrue);
      expect(latch.matches(2, 44100), isTrue);
    });

    test('a new hardware rate re-arms the attempt', () {
      final latch = RateFollowLatch();
      latch.set(2, 44100);
      expect(latch.matches(2, 96000), isFalse);
    });

    test('a different device re-arms the attempt', () {
      final latch = RateFollowLatch();
      latch.set(2, 44100);
      expect(latch.matches(1, 44100), isFalse);
    });

    test('clear() forgets the failure', () {
      final latch = RateFollowLatch();
      latch.set(2, 44100);
      latch.clear();
      expect(latch.isSet, isFalse);
      expect(latch.matches(2, 44100), isFalse);
    });

    test('re-latching replaces the pair', () {
      final latch = RateFollowLatch();
      latch.set(2, 44100);
      latch.set(2, 96000);
      expect(latch.matches(2, 44100), isFalse);
      expect(latch.matches(2, 96000), isTrue);
    });
  });
}
