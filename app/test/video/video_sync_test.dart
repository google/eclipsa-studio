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

import 'package:eclipsa_studio/video/video_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isDiscontinuousJump', () {
    const sr = 48000;

    test('a single 60 Hz tick is natural progress', () {
      // 48 kHz / 60 Hz = 800 samples per tick.
      expect(isDiscontinuousJump(deltaSamples: 800, sampleRate: sr), isFalse);
    });

    test('a few dropped Flutter frames stay under the threshold', () {
      // 5 ticks of backlog (~83 ms) must not be mistaken for a seek.
      expect(isDiscontinuousJump(deltaSamples: 4000, sampleRate: sr), isFalse);
    });

    test('threshold sits at exactly 100 ms', () {
      expect(isDiscontinuousJump(deltaSamples: 4800, sampleRate: sr), isFalse);
      expect(isDiscontinuousJump(deltaSamples: 4801, sampleRate: sr), isTrue);
    });

    test('forward user seeks jump by seconds', () {
      expect(isDiscontinuousJump(deltaSamples: sr * 5, sampleRate: sr), isTrue);
    });

    test('any negative delta is a loop wrap or backward scrub', () {
      expect(isDiscontinuousJump(deltaSamples: -1, sampleRate: sr), isTrue);
      expect(
        isDiscontinuousJump(deltaSamples: -sr * 10, sampleRate: sr),
        isTrue,
      );
    });

    test('zero delta is not a jump', () {
      expect(isDiscontinuousJump(deltaSamples: 0, sampleRate: sr), isFalse);
    });

    test('threshold scales with the sample rate', () {
      // 100 ms at 96 kHz is 9600 samples.
      expect(
        isDiscontinuousJump(deltaSamples: 9600, sampleRate: 96000),
        isFalse,
      );
      expect(
        isDiscontinuousJump(deltaSamples: 9601, sampleRate: 96000),
        isTrue,
      );
    });
  });
}
