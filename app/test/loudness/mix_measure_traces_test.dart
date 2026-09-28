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

// Unit tests for the limiter GR getters on MixMeasureTraces (ES-517):
// the engagement threshold boundary (strict >), the max fold, and the
// engaged-fraction arithmetic that drive the Loudness Report's MAX GR /
// LIMITED columns and the GR-lane caption.

import 'dart:typed_data';

import 'package:eclipsa_studio/export/iamf_measure_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

MixMeasureTraces tracesWithGr(List<double> gr) {
  return MixMeasureTraces(
    momentaryLufs: Float32List(0),
    shortTermLufs: Float32List(0),
    shortTermPeakDbfs: Float32List(0),
    shortTermPsrDb: Float32List(0),
    limiterGrDb: Float32List.fromList(gr),
    loudnessRangeLu: null,
    lraStable: false,
  );
}

void main() {
  test('empty trace reads as unengaged', () {
    final t = tracesWithGr(const []);
    expect(t.maxLimiterGrDb, 0.0);
    expect(t.limiterEngagedFraction, 0.0);
  });

  test('threshold boundary is strict: at engagedThresholdDb is clean', () {
    // Note float32 rounding: 0.01 stored in a Float32List reads back
    // fractionally below the double threshold, which is fine — the
    // boundary must not count as engaged either way (`>`).
    final t = tracesWithGr(const [MixMeasureTraces.engagedThresholdDb]);
    expect(t.limiterEngagedFraction, 0.0);
  });

  test('just above the threshold counts, with the right fraction', () {
    final t = tracesWithGr(const [0.02, 0.0, 0.0, 0.02]);
    expect(t.limiterEngagedFraction, 0.5);
    expect(t.maxLimiterGrDb, closeTo(0.02, 1e-6));
  });

  test('mixed values fold to the correct max', () {
    final t = tracesWithGr(const [0.0, 1.5, 0.3, 4.25, 2.0]);
    expect(t.maxLimiterGrDb, closeTo(4.25, 1e-6));
    expect(t.limiterEngagedFraction, closeTo(4 / 5, 1e-9));
  });

  test('non-finite entries are ignored (defense in depth)', () {
    final t = tracesWithGr(const [double.nan, double.infinity, 0.5]);
    expect(t.maxLimiterGrDb, closeTo(0.5, 1e-6));
    expect(t.limiterEngagedFraction, closeTo(1 / 3, 1e-9));
  });
}
