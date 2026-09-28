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

// Tests for the Object element polar-position math (ES-436): dual-object
// azimuths (az ± spread/2) must be wrapped onto (-180, 180] before they
// reach the engine, because OAR's OLR neither folds nor circularly
// compares out-of-range azimuths (a raw 270 collapses to the left
// speaker on stereo instead of rendering at the equivalent -90). The
// boundary maps to +180, matching OBR's normalization and OLR's
// back-center speaker (M+180). Elevation and distance are clamped, not
// wrapped — out-of-range values only occur in hand-edited session JSON.

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

AudioElement _object({
  required double azimuth,
  double elevation = 0,
  double distance = 1,
  double spread = 60,
  bool isDual = true,
}) {
  return AudioElement(
    id: 1,
    name: 'obj',
    type: 'Object',
    layout: '',
    codec: 'LPCM',
    color: 0,
    azimuth: azimuth,
    elevation: elevation,
    distance: distance,
    isDual: isDual,
    spread: spread,
  );
}

void main() {
  group('elementObjectPolarPositions (dual, spread 180)', () {
    test('azimuth 0 gives hard left/right (±90)', () {
      final pos = elementObjectPolarPositions(_object(azimuth: 0, spread: 180));
      expect(pos.count, 2);
      expect(pos.az, 90); // Channel 1: left.
      expect(pos.az2, -90); // Channel 2: right.
    });

    test('azimuth 90 puts both channels on the median plane', () {
      final pos = elementObjectPolarPositions(
        _object(azimuth: 90, spread: 180),
      );
      expect(pos.az, 180); // Directly behind (+180, the M+180 speaker).
      expect(pos.az2, 0); // Directly ahead.
    });

    test('azimuth 180 gives flipped stereo, not both-left (ES-436)', () {
      final pos = elementObjectPolarPositions(
        _object(azimuth: 180, spread: 180),
      );
      expect(pos.az, -90); // 270 wrapped: right side.
      expect(pos.az2, 90); // Left side.
    });

    test('azimuth -180 gives flipped stereo, not both-right (ES-436)', () {
      final pos = elementObjectPolarPositions(
        _object(azimuth: -180, spread: 180),
      );
      expect(pos.az, -90); // Right side.
      expect(pos.az2, 90); // -270 wrapped: left side.
    });
  });

  group('elementObjectPolarPositions (general)', () {
    test('dual keeps az ± spread/2 when in range', () {
      final pos = elementObjectPolarPositions(_object(azimuth: 10, spread: 60));
      expect(pos.az, 40);
      expect(pos.az2, -20);
    });

    test('single object wraps its azimuth too', () {
      final pos = elementObjectPolarPositions(
        _object(azimuth: 200, isDual: false),
      );
      expect(pos.count, 1);
      expect(pos.az, -160);
    });

    test('azimuth boundary maps to +180 for both ±180 inputs', () {
      // OLR's back-center speaker sits at exactly +180 and its
      // closest-speaker fallback compares angles linearly, so -180
      // would score 360 degrees away from it.
      expect(
        elementObjectPolarPositions(_object(azimuth: 180, isDual: false)).az,
        180,
      );
      expect(
        elementObjectPolarPositions(_object(azimuth: -180, isDual: false)).az,
        180,
      );
    });

    test('clamps out-of-range elevation and distance (not wrapped)', () {
      // Only reachable via hand-edited session JSON; sliders are
      // bounded. Matches the export path's encodeElevation /
      // encodeNormalizedDistance clamp semantics.
      final pos = elementObjectPolarPositions(
        _object(azimuth: 0, elevation: 200, distance: 5),
      );
      expect(pos.el, 90);
      expect(pos.el2, 90);
      expect(pos.dist, 1);
      expect(pos.dist2, 1);

      final neg = elementObjectPolarPositions(
        _object(azimuth: 0, elevation: -200, distance: -1, isDual: false),
      );
      expect(neg.el, -90);
      expect(neg.dist, 0);
    });
  });
}
