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

// Pins the main-window fit against the display work area (ES-613): the
// minimum shrinks to a small display, an oversized stored window is
// clamped into the work area with its top edge at or below the work
// area's top, a window on an external display arranged above the
// primary stays there, and a window that already fits round-trips
// unchanged.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/window_geometry.dart';

/// A 13" MacBook at "looks like 1440×900" with a 24 pt menu bar.
const _air = Rect.fromLTWH(0, 24, 1440, 876);

/// The same with the Dock showing.
const _airWithDock = Rect.fromLTWH(0, 24, 1440, 810);

/// A large external display.
const _external = Rect.fromLTWH(0, 24, 2560, 1416);

/// An external display arranged above the built-in one: negative y.
const _externalAbove = Rect.fromLTWH(-560, -1440, 2560, 1440);

void main() {
  group('clampMinimumSize', () {
    test('keeps the preferred minimum on a large display', () {
      expect(clampMinimumSize(_external), kPreferredMinWindowSize);
    });

    test('reduces the height to a 13" work area', () {
      expect(clampMinimumSize(_air), const Size(1400, 876));
      expect(clampMinimumSize(_airWithDock), const Size(1400, 810));
    });

    test('reduces both axes under "Larger Text" scaling', () {
      expect(
        clampMinimumSize(const Rect.fromLTWH(0, 24, 1352, 836)),
        const Size(1352, 836),
      );
    });

    test('never goes below the absolute floor', () {
      expect(
        clampMinimumSize(const Rect.fromLTWH(0, 0, 300, 200)),
        kAbsoluteMinWindowSize,
      );
    });
  });

  group('fitWindowBounds', () {
    test('a window that fits round-trips unchanged', () {
      const stored = Rect.fromLTWH(200, 100, 1600, 1000);
      final min = clampMinimumSize(_external);
      expect(fitWindowBounds(stored, _external, min), stored);
    });

    test('an oversized stored window is clamped into a 13" work area', () {
      // Bounds saved on an external display, restored on the laptop.
      const stored = Rect.fromLTWH(300, 120, 1555, 1057);
      final min = clampMinimumSize(_air);
      expect(fitWindowBounds(stored, _air, min), _air);
    });

    test('the top edge never lands above the work area', () {
      const stored = Rect.fromLTWH(20, -40, 1400, 800);
      final min = clampMinimumSize(_external);
      final fit = fitWindowBounds(stored, _external, min);
      expect(fit.top, _external.top);
      expect(fit.size, const Size(1400, 900), reason: 'raised to the minimum');
    });

    test('the bottom edge stays reachable with the Dock showing', () {
      const stored = Rect.fromLTWH(0, 24, 1440, 876);
      final min = clampMinimumSize(_airWithDock);
      final fit = fitWindowBounds(stored, _airWithDock, min);
      expect(fit.bottom, _airWithDock.bottom);
      expect(fit.height, 810);
    });

    test('a window smaller than the minimum grows and stays inside', () {
      const stored = Rect.fromLTWH(2000, 1000, 800, 500);
      final min = clampMinimumSize(_external);
      final fit = fitWindowBounds(stored, _external, min);
      expect(fit.size, kPreferredMinWindowSize);
      expect(fit.right, lessThanOrEqualTo(_external.right));
      expect(fit.bottom, lessThanOrEqualTo(_external.bottom));
    });
  });

  group('pickWorkArea', () {
    const areas = [_air, _externalAbove];

    test('a window on the display arranged above stays there', () {
      const stored = Rect.fromLTWH(200, -1200, 1600, 1000);
      expect(pickWorkArea(stored, areas, _air), _externalAbove);
      final fit = fitWindowBounds(
        stored,
        _externalAbove,
        clampMinimumSize(_externalAbove),
      );
      expect(fit, stored);
    });

    test('a window off every display falls back to the primary', () {
      const stored = Rect.fromLTWH(9000, 9000, 1400, 900);
      expect(pickWorkArea(stored, areas, _air), _air);
    });

    test('no stored bounds picks the primary', () {
      expect(pickWorkArea(null, areas, _air), _air);
    });

    test('a window straddling two displays goes where most of it is', () {
      // Mostly on the built-in display, spilling up onto the external.
      const stored = Rect.fromLTWH(100, -100, 1400, 900);
      expect(pickWorkArea(stored, areas, _air), _air);
    });
  });

  group('defaultWindowBounds', () {
    test('centres the minimum in the work area', () {
      final min = clampMinimumSize(_external);
      final b = defaultWindowBounds(_external, min);
      expect(b.size, min);
      expect(b.center, _external.center);
    });

    test('fills the height of a small work area', () {
      final min = clampMinimumSize(_air);
      final b = defaultWindowBounds(_air, min);
      expect(b.size, const Size(1400, 876));
      expect(b.top, _air.top);
      expect(b.bottom, _air.bottom);
      expect(b.center.dx, _air.center.dx);
    });
  });

  test('isSaneStoredBounds rejects non-finite and empty rectangles', () {
    expect(isSaneStoredBounds(const Rect.fromLTWH(0, 0, 1400, 900)), isTrue);
    expect(isSaneStoredBounds(const Rect.fromLTWH(0, 0, 0, 900)), isFalse);
    expect(
      isSaneStoredBounds(const Rect.fromLTWH(double.nan, 0, 1400, 900)),
      isFalse,
    );
    expect(
      isSaneStoredBounds(const Rect.fromLTWH(0, 0, double.infinity, 900)),
      isFalse,
    );
  });
}
