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

import 'package:eclipsa_studio/video/ffmpeg_engine_backend.dart';
import 'package:eclipsa_studio/video/ffmpeg_video_ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// The FFmpeg backend's rotation handling (ES-796): the engine reports the
// stored frame size and the quarter turns; the meta carries the display
// size, and the software image path turns the unrotated frame.
void main() {
  FfmpegVideoInfo info({
    int width = 1920,
    int height = 1080,
    int quarterTurns = 0,
  }) => FfmpegVideoInfo(
    width: width,
    height: height,
    fps: 30,
    durationMs: 2000,
    ok: true,
    hw: false,
    quarterTurns: quarterTurns,
  );

  group('ffmpegVideoMeta', () {
    test('keeps the stored size for 0 and 2 quarter turns', () {
      for (final turns in [0, 2]) {
        final meta = ffmpegVideoMeta(info(quarterTurns: turns));
        expect(meta.width, 1920, reason: 'turns $turns');
        expect(meta.height, 1080, reason: 'turns $turns');
        expect(meta.quarterTurns, turns);
      }
    });

    test('swaps the stored size for 1 and 3 quarter turns', () {
      for (final turns in [1, 3]) {
        final meta = ffmpegVideoMeta(info(quarterTurns: turns));
        expect(meta.width, 1080, reason: 'turns $turns');
        expect(meta.height, 1920, reason: 'turns $turns');
        expect(meta.quarterTurns, turns);
      }
    });

    test('an unresolved size stays null after the swap', () {
      final meta = ffmpegVideoMeta(
        info(width: 0, height: 1080, quarterTurns: 1),
      );
      expect(meta.width, 1080);
      expect(meta.height, isNull);
    });

    test('carries duration and fps', () {
      final meta = ffmpegVideoMeta(info());
      expect(meta.duration, const Duration(seconds: 2));
      expect(meta.fps, 30);
    });
  });

  group('fittedVideoImage', () {
    testWidgets('lays the frame out in the swapped box for an odd turn', (
      tester,
    ) async {
      final image = await tester.runAsync(
        () => createTestImage(width: 192, height: 108),
      );
      addTearDown(image!.dispose);
      for (final turns in [1, 3]) {
        await tester.pumpWidget(
          Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: fittedVideoImage(image, turns),
            ),
          ),
        );
        expect(
          tester.getSize(find.byType(RawImage)),
          const Size(300, 400),
          reason: 'turns $turns',
        );
        expect(
          tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
          turns,
        );
      }
    });

    testWidgets('lays the frame out in the panel box for no turn', (
      tester,
    ) async {
      final image = await tester.runAsync(
        () => createTestImage(width: 192, height: 108),
      );
      addTearDown(image!.dispose);
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: fittedVideoImage(image, 0),
          ),
        ),
      );
      expect(tester.getSize(find.byType(RawImage)), const Size(400, 300));
    });
  });
}
