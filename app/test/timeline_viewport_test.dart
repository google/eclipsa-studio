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

// Hermetic tests for TimelineViewportNotifier.zoomAroundFraction
// (ES-549): pointer-anchored zoom must keep the time under the pivot
// at the same on-screen position, and the playhead variant must stay
// a special case of the same math.

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late TimelineViewportNotifier notifier;

  const durationSec = 100.0;

  setUp(() {
    container = ProviderContainer();
    container
        .read(transportProvider.notifier)
        .updateDuration((durationSec * 48000).round(), 48000);
    notifier = container.read(timelineViewportProvider.notifier);
  });

  tearDown(() => container.dispose());

  TimelineViewport vp() => container.read(timelineViewportProvider);

  /// Session time (seconds) at viewport fraction [frac].
  double timeAtFraction(double frac) {
    final v = vp();
    final visible = durationSec / v.zoomLevel;
    final start = v.scrollOffset * (durationSec - visible);
    return start + frac * visible;
  }

  test('keeps the time under the pivot fixed while zooming in', () {
    notifier.setZoom(4.0);
    notifier.setScroll(0.5);
    final pivotTime = timeAtFraction(0.25);

    notifier.zoomAroundFraction(2.0, 0.25);

    expect(vp().zoomLevel, 8.0);
    expect(timeAtFraction(0.25), closeTo(pivotTime, 1e-9));
  });

  test('keeps the time under the pivot fixed while zooming out', () {
    notifier.setZoom(8.0);
    notifier.setScroll(0.5);
    final pivotTime = timeAtFraction(0.75);

    notifier.zoomAroundFraction(0.5, 0.75);

    expect(vp().zoomLevel, 4.0);
    expect(timeAtFraction(0.75), closeTo(pivotTime, 1e-9));
  });

  test('clamps zoom to [1, 500] and scroll to [0, 1]', () {
    notifier.zoomAroundFraction(0.5, 0.5);
    expect(vp().zoomLevel, 1.0);
    expect(vp().scrollOffset, 0.0);

    notifier.setZoom(400.0);
    notifier.zoomAroundFraction(10.0, 0.0);
    expect(vp().zoomLevel, 500.0);
    expect(vp().scrollOffset, inInclusiveRange(0.0, 1.0));
  });

  test('zooming out to full duration resets scroll to 0', () {
    notifier.setZoom(4.0);
    notifier.setScroll(1.0);
    notifier.zoomAroundFraction(1 / 4.0, 0.5);
    expect(vp().zoomLevel, 1.0);
    expect(vp().scrollOffset, 0.0);
  });

  test('out-of-range pivot fractions are clamped, not extrapolated', () {
    notifier.setZoom(4.0);
    notifier.setScroll(0.5);
    final edgeTime = timeAtFraction(1.0);

    notifier.zoomAroundFraction(2.0, 1.5);

    expect(timeAtFraction(1.0), closeTo(edgeTime, 1e-9));
  });

  test('zoomByAroundPlayhead pins an on-screen playhead', () {
    // Playhead at t=50 of 100 s, full view: fraction 0.5.
    container.read(transportProvider.notifier).seekSeconds(50.0);
    notifier.zoomByAroundPlayhead(2.0);

    expect(vp().zoomLevel, 2.0);
    expect(timeAtFraction(0.5), closeTo(50.0, 1e-9));
  });

  test('zoomByAroundPlayhead falls back to center when off-screen', () {
    // Zoomed into the first quarter; playhead far right at t=90.
    notifier.setZoom(4.0);
    notifier.setScroll(0.0);
    container.read(transportProvider.notifier).seekSeconds(90.0);
    final centerTime = timeAtFraction(0.5);

    notifier.zoomByAroundPlayhead(2.0);

    expect(timeAtFraction(0.5), closeTo(centerTime, 1e-9));
  });
}
