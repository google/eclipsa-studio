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
import 'dart:ui';

/// The pop-out window's size for a clip of [video] pixels on a display
/// of [display] logical pixels, with [chrome] logical pixels of strips
/// above and below the picture (the title bar and the status bar,
/// ES-744).
///
/// The window is the picture plus the strips, so the picture shows with
/// no letterbox at open. The picture keeps its aspect and is scaled
/// down, never up, so that the window fits inside [fitFraction] of the
/// display on both axes; a picture narrower than [minWidth] is scaled
/// up to that width unless the display cap is smaller, which then
/// wins. The width is rounded to whole logical pixels and the height
/// derived from it, so the returned size is the one the window takes.
/// [video] is in pixels and the result in logical pixels: a 1280 x 720
/// clip on a display with room for it opens at 1280 x (720 + chrome).
Size fitPopoutSize(
  Size video,
  Size display, {
  required double chrome,
  double fitFraction = 0.9,
  double minWidth = 320,
}) {
  final w = math.max(video.width, 1.0);
  final h = math.max(video.height, 1.0);
  final limitW = math.max(display.width * fitFraction, 0.0);
  final limitH = math.max(display.height * fitFraction - chrome, 0.0);
  final cap = math.min(limitW / w, limitH / h);
  final scale = math.min(math.max(math.min(1.0, cap), minWidth / w), cap);
  final width = (w * scale).roundToDouble();
  final height = (width * h / w).roundToDouble();
  return Size(width, height + chrome);
}

/// The window's width-to-height ratio for `setAspectRatio`: the
/// picture of [video] pixels drawn [width] logical pixels wide, plus
/// [chrome] logical pixels of strips. Computed from the width the
/// window has, so the ratio matches the window at that size; the
/// strips have a fixed height, so the ratio drifts by their share as
/// the window is resized.
double popoutAspectRatio(
  Size video, {
  required double width,
  required double chrome,
}) {
  final w = math.max(video.width, 1.0);
  return width / (width * video.height / w + chrome);
}
