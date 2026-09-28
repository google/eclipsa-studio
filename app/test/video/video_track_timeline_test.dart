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

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:eclipsa_studio/video/video_track.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/widgets/time_ruler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loaded video of [duration] with no backend behind it.
class _FakeVideo extends VideoNotifier {
  _FakeVideo(this.duration);

  final Duration duration;

  @override
  VideoState build() => VideoState(filePath: '/clip.mp4', duration: duration);
}

/// The video lane in the timeline maps time on the ruler's scale (ES-758).
void main() {
  testWidgets('the video lane spans the ruler and ends at its duration', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // The transport defaults to 312 s; a 156 s video ends halfway.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoProvider.overrideWith(
            () => _FakeVideo(const Duration(seconds: 156)),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ElementsView())),
      ),
    );
    await tester.pump();
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(ElementsView)),
      ).read(transportProvider).durationSeconds,
      312,
    );

    final ruler = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is TimeRulerPainter,
      ),
    );
    final lane = tester.getRect(find.byType(VideoLane));
    expect(lane.left, ruler.left);
    expect(lane.right, ruler.right);

    final bar = tester.getRect(
      find
          .descendant(
            of: find.byType(VideoLane),
            matching: find.byType(Positioned),
          )
          .first,
    );
    expect(bar.left, ruler.left);
    expect(bar.right, closeTo(ruler.left + ruler.width / 2, 0.01));
  });
}
