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

import 'dart:ui' as ui;

import 'package:eclipsa_studio/meters/mini_multichannel_meter.dart';
import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Red on a meter means the engine's sticky clip latch and nothing
/// else (ES-191): a channel at 0 dBFS with its latch clear draws no red
/// pixel, a latched channel draws the red indicator, and a tap on the
/// meter is the clear.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  /// Renders [child] at [width]×[height] and counts pixels equal to
  /// the current theme's meterRed.
  Future<int> redPixels(
    WidgetTester tester,
    Widget child, {
    double width = 160,
    double height = 120,
  }) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(width: width, height: height, child: child),
          ),
        ),
      ),
    );
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final red = T.meterRed;
    var count = 0;
    // toImage and toByteData are engine futures; runAsync hands
    // control to the real event loop so they complete.
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      for (var o = 0; o + 3 < data.lengthInBytes; o += 4) {
        final px = Color.fromARGB(
          data.getUint8(o + 3),
          data.getUint8(o),
          data.getUint8(o + 1),
          data.getUint8(o + 2),
        );
        if (px == red) count++;
      }
      image.dispose();
    });
    return count;
  }

  for (final mode in AppThemeMode.values) {
    group(mode.name, () {
      setUp(() => T.setMode(mode));

      testWidgets('full-scale bars with clear latches draw no red', (
        tester,
      ) async {
        expect(
          await redPixels(
            tester,
            const MultichannelMeter(
              levels: [1.0, 1.0],
              peaks: [1.0, 1.0],
              clipped: [false, false],
            ),
          ),
          0,
        );
        expect(
          await redPixels(
            tester,
            const MiniMultichannelMeter(
              levels: [1.0, 1.0],
              peaks: [1.0, 1.0],
              clipped: [false, false],
            ),
            width: 24,
            height: 40,
          ),
          0,
        );
      });

      testWidgets('a latched channel draws the red indicator', (tester) async {
        expect(
          await redPixels(
            tester,
            const MultichannelMeter(levels: [0.1, 0.1], clipped: [true, false]),
          ),
          greaterThan(0),
        );
        expect(
          await redPixels(
            tester,
            const MiniMultichannelMeter(
              levels: [0.1, 0.1],
              clipped: [true, false],
            ),
            width: 24,
            height: 40,
          ),
          greaterThan(0),
        );
      });
    });
  }

  testWidgets('a tap on either meter is the clip clear', (tester) async {
    var clears = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            SizedBox(
              width: 160,
              height: 100,
              child: MultichannelMeter(
                levels: const [0.5],
                clipped: const [true],
                onClipClear: () => clears++,
              ),
            ),
            SizedBox(
              width: 24,
              height: 40,
              child: MiniMultichannelMeter(
                levels: const [0.5],
                clipped: const [true],
                onClipClear: () => clears++,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(MultichannelMeter));
    expect(clears, 1);
    await tester.tap(find.byType(MiniMultichannelMeter));
    expect(clears, 2);
  });
}
