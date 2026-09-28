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

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/video/video_track.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the lane keeps its inset and moves its chip per style', (
    tester,
  ) async {
    // In the 52 px row the lane is 40 px, 6 from the top, in every
    // theme: the concepts draw 49 and 48 from the top, and a
    // component's size does not vary by theme, only how it is drawn
    // and coloured. The chip does move: top in `recessed` and
    // `outlined`, bottom in both concepts.
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  SizedBox(
                    width: 800,
                    height: 52,
                    child: VideoLane(barLeft: 0, barWidth: 600, label: 'a.mp4'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    final lane = find.byType(VideoLane);
    double barTop() =>
        tester.getTopLeft(find.byType(ClipRect)).dy -
        tester.getTopLeft(lane).dy;
    double barHeight() => tester.getSize(find.byType(ClipRect)).height;
    double chipTop() =>
        tester.getTopLeft(find.text('a.mp4')).dy - tester.getTopLeft(lane).dy;

    expect(barTop(), 6);
    expect(barHeight(), 40);
    expect(chipTop(), lessThan(26));

    for (final mode in [AppThemeMode.dark, AppThemeMode.light]) {
      T.setMode(mode);
      rebuild(() {});
      await tester.pump();
      expect(barTop(), 6, reason: mode.name);
      expect(barHeight(), 40, reason: mode.name);
      expect(chipTop(), greaterThan(26), reason: mode.name);
    }
  });
}
