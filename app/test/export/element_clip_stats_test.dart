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

// Unit tests for the shared signal-overload model (ES-470): dBFS
// conversion, max-merge semantics, and peak formatting.

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/element_clip_stats.dart';

void main() {
  group('ElementClipStats', () {
    test('clipped reflects the sample count', () {
      const clean = ElementClipStats(clippedSamples: 0, peakLinear: 1.0);
      const hot = ElementClipStats(clippedSamples: 1, peakLinear: 1.01);
      expect(clean.clipped, isFalse);
      expect(hot.clipped, isTrue);
    });

    test('peakDbfs converts 20*log10', () {
      const unity = ElementClipStats(clippedSamples: 0, peakLinear: 1.0);
      const double6 = ElementClipStats(clippedSamples: 5, peakLinear: 2.0);
      const half = ElementClipStats(clippedSamples: 0, peakLinear: 0.5);
      expect(unity.peakDbfs, closeTo(0.0, 1e-9));
      expect(double6.peakDbfs, closeTo(6.0206, 1e-3));
      expect(half.peakDbfs, closeTo(-6.0206, 1e-3));
    });

    test('peakDbfs of silence is -infinity', () {
      const silent = ElementClipStats(clippedSamples: 0, peakLinear: 0.0);
      expect(silent.peakDbfs, double.negativeInfinity);
    });
  });

  group('mergeElementClipStats', () {
    test('takes the per-field max for shared keys', () {
      final merged = mergeElementClipStats(
        {1: const ElementClipStats(clippedSamples: 10, peakLinear: 1.2)},
        {1: const ElementClipStats(clippedSamples: 7, peakLinear: 1.5)},
      );
      expect(merged[1]!.clippedSamples, 10);
      expect(merged[1]!.peakLinear, 1.5);
    });

    test('unions disjoint keys and leaves inputs untouched', () {
      final a = {1: const ElementClipStats(clippedSamples: 1, peakLinear: 1.1)};
      final b = {2: const ElementClipStats(clippedSamples: 2, peakLinear: 1.2)};
      final merged = mergeElementClipStats(a, b);
      expect(merged.keys, unorderedEquals([1, 2]));
      expect(a.keys, [1]);
      expect(b.keys, [2]);
    });

    test('empty maps merge to empty', () {
      expect(mergeElementClipStats({}, {}), isEmpty);
    });
  });

  group('formatPeakDbfs', () {
    test('signs and rounds to one decimal', () {
      expect(formatPeakDbfs(2.34), '+2.3 dBFS');
      expect(formatPeakDbfs(0.0), '+0.0 dBFS');
      expect(formatPeakDbfs(-6.02), '-6.0 dBFS');
    });

    test('silence and NaN degrade gracefully', () {
      expect(formatPeakDbfs(double.negativeInfinity), 'silent');
      expect(formatPeakDbfs(double.nan), 'silent');
    });
  });
}
