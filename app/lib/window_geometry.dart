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

/// Main-window geometry against the display work area (ES-613).
///
/// Pure functions over rectangles so the clamping is unit-testable
/// without a window or a display. Every rectangle is in the logical,
/// top-left-origin space that both `window_manager` and
/// `screen_retriever` report on macOS and Windows: a display's work
/// area is its visible frame (the display minus the menu bar, Dock or
/// taskbar), and a window's bounds are its frame.
///
/// The rule: the window must fit the display it is on. The 1400×900
/// preferred minimum is reduced per axis to the work area, the window
/// is no larger than the work area, and its whole rectangle sits
/// inside it, so the top edge never lands above the work area's top
/// where the menu bar would cover the 28 px titlebar strip.
library;

import 'dart:math' as math;
import 'dart:ui';

/// Preferred minimum size of the main window, applied in full only on
/// a display whose work area is at least this large.
const Size kPreferredMinWindowSize = Size(1400, 900);

/// Floor under the clamped minimum, so a bad or missing display reading
/// cannot produce a degenerate window.
const Size kAbsoluteMinWindowSize = Size(640, 480);

/// The work area to fit [stored] into: the one it overlaps most, and
/// [primary] when it overlaps none or is null. A window left on an
/// external display, including one arranged above the built-in
/// display at negative y, restores there.
Rect pickWorkArea(Rect? stored, List<Rect> workAreas, Rect primary) {
  if (stored == null) return primary;
  Rect best = primary;
  var bestArea = 0.0;
  for (final area in workAreas) {
    final overlap = stored.intersect(area);
    if (overlap.isEmpty) continue;
    final a = overlap.width * overlap.height;
    if (a > bestArea) {
      bestArea = a;
      best = area;
    }
  }
  return best;
}

/// The minimum window size to apply on a display whose work area is
/// [workArea]: [kPreferredMinWindowSize] reduced per axis to the work
/// area, never below [kAbsoluteMinWindowSize].
Size clampMinimumSize(Rect workArea) {
  return Size(
    math.max(
      kAbsoluteMinWindowSize.width,
      math.min(kPreferredMinWindowSize.width, workArea.width),
    ),
    math.max(
      kAbsoluteMinWindowSize.height,
      math.min(kPreferredMinWindowSize.height, workArea.height),
    ),
  );
}

/// Fits [stored] into [workArea]. The size is raised to [minimum] and
/// capped at the work area, then the origin is clamped so the whole
/// rectangle lies inside the work area. [minimum] must come from
/// [clampMinimumSize] for the same work area, so it never exceeds it.
Rect fitWindowBounds(Rect stored, Rect workArea, Size minimum) {
  final w = _fitAxis(stored.width, minimum.width, workArea.width);
  final h = _fitAxis(stored.height, minimum.height, workArea.height);
  final x = _clampOrigin(stored.left, workArea.left, workArea.right - w);
  final y = _clampOrigin(stored.top, workArea.top, workArea.bottom - h);
  return Rect.fromLTWH(x, y, w, h);
}

/// The bounds for a window with no usable stored geometry: [minimum]
/// in size, centred in [workArea].
Rect defaultWindowBounds(Rect workArea, Size minimum) {
  final w = math.min(minimum.width, workArea.width);
  final h = math.min(minimum.height, workArea.height);
  return Rect.fromLTWH(
    workArea.left + (workArea.width - w) / 2,
    workArea.top + (workArea.height - h) / 2,
    w,
    h,
  );
}

/// Whether a stored rectangle is usable at all: finite, with a
/// positive size. Position and size are clamped later; this only
/// rejects values no display could give.
bool isSaneStoredBounds(Rect r) =>
    r.left.isFinite &&
    r.top.isFinite &&
    r.width.isFinite &&
    r.height.isFinite &&
    r.width > 0 &&
    r.height > 0;

double _fitAxis(double stored, double minimum, double available) =>
    math.min(math.max(stored, minimum), available);

double _clampOrigin(double v, double low, double high) =>
    high < low ? low : v.clamp(low, high).toDouble();
