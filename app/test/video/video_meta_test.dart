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

import 'package:eclipsa_studio/video/video_backend.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Pure unit tests for VideoMeta.fromChannelMap (ES-462) — the parser both the
// AVFoundation and Media Foundation backends run their `load` reply through.
// The contract: optional keys are omitted (or non-positive) when the native
// side couldn't resolve them, and colorTransfer/colorPrimaries arrive as
// separate ASCII strings composed here into one display string.
void main() {
  group('VideoMeta.fromChannelMap', () {
    test('parses a full reply', () {
      final meta = VideoMeta.fromChannelMap({
        'durationMs': 2000,
        'width': 320,
        'height': 240,
        'fps': 30.0,
        'containerDurationMs': 4975,
        'codec': 'HEVC (hvc1)',
        'bitRate': 27844,
        'colorTransfer': 'PQ (HDR10)',
        'colorPrimaries': 'BT.2020',
      });
      expect(meta.duration, const Duration(seconds: 2));
      expect(meta.width, 320);
      expect(meta.height, 240);
      expect(meta.fps, 30.0);
      expect(meta.containerDuration, const Duration(milliseconds: 4975));
      expect(meta.codec, 'HEVC (hvc1)');
      expect(meta.bitRateBps, 27844);
      expect(meta.colorInfo, 'PQ (HDR10) · BT.2020');
    });

    test('missing optional keys parse to null', () {
      final meta = VideoMeta.fromChannelMap({
        'durationMs': 2000,
        'width': 320,
        'height': 240,
        'fps': 30.0,
      });
      expect(meta.containerDuration, isNull);
      expect(meta.codec, isNull);
      expect(meta.bitRateBps, isNull);
      expect(meta.colorInfo, isNull);
    });

    test('non-positive durations and bit rate parse to null', () {
      final meta = VideoMeta.fromChannelMap({
        'durationMs': 0,
        'containerDurationMs': -1,
        'bitRate': 0,
      });
      expect(meta.duration, isNull);
      expect(meta.containerDuration, isNull);
      expect(meta.bitRateBps, isNull);
    });

    test('color composes from either part alone', () {
      expect(
        VideoMeta.fromChannelMap({'colorTransfer': 'PQ (HDR10)'}).colorInfo,
        'PQ (HDR10)',
      );
      expect(
        VideoMeta.fromChannelMap({'colorPrimaries': 'BT.709'}).colorInfo,
        'BT.709',
      );
    });

    test('integer-typed fps and doubles-typed ints tolerate num', () {
      final meta = VideoMeta.fromChannelMap({
        'durationMs': 2000.0,
        'width': 320.0,
        'fps': 30,
        'bitRate': 27844.0,
      });
      expect(meta.duration, const Duration(seconds: 2));
      expect(meta.width, 320);
      expect(meta.fps, 30.0);
      expect(meta.bitRateBps, 27844);
    });
  });

  group('VideoMeta.quarterTurns', () {
    test('defaults to 0 when the reply omits it', () {
      expect(VideoMeta.fromChannelMap({'width': 320}).quarterTurns, 0);
    });

    test('parses the reply value into 0-3', () {
      expect(VideoMeta.fromChannelMap({'quarterTurns': 1}).quarterTurns, 1);
      expect(VideoMeta.fromChannelMap({'quarterTurns': 3.0}).quarterTurns, 3);
      expect(VideoMeta.fromChannelMap({'quarterTurns': 5}).quarterTurns, 1);
    });
  });

  group('fittedVideoTexture', () {
    const pictureKey = Key('picture');

    Future<void> pump(WidgetTester tester, VideoMeta meta) {
      return tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: fittedVideoTexture(
              meta,
              const SizedBox.expand(key: pictureKey),
            ),
          ),
        ),
      );
    }

    testWidgets('letterboxes an unrotated clip to its aspect ratio', (
      tester,
    ) async {
      await pump(tester, const VideoMeta(width: 1920, height: 1080));
      expect(tester.getSize(find.byKey(pictureKey)), const Size(400, 225));
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        0,
      );
    });

    testWidgets('turns a portrait clip and fits its display size', (
      tester,
    ) async {
      // A 1920x1080 frame with a quarter turn displays as 1080x1920: the
      // 300 px tall box fits it at 168.75 x 300, and the unrotated frame
      // inside is laid out at 300 x 168.75 before the turn.
      await pump(
        tester,
        const VideoMeta(width: 1080, height: 1920, quarterTurns: 1),
      );
      expect(tester.getSize(find.byType(RotatedBox)), const Size(168.75, 300));
      expect(tester.getSize(find.byKey(pictureKey)), const Size(300, 168.75));
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        1,
      );
    });

    testWidgets('three quarter turns fit like one', (tester) async {
      await pump(
        tester,
        const VideoMeta(width: 1080, height: 1920, quarterTurns: 3),
      );
      expect(tester.getSize(find.byKey(pictureKey)), const Size(300, 168.75));
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        3,
      );
    });

    testWidgets('returns the texture as is before the size resolves', (
      tester,
    ) async {
      await pump(tester, VideoMeta.empty);
      expect(find.byType(RotatedBox), findsNothing);
      expect(tester.getSize(find.byKey(pictureKey)), const Size(400, 300));
    });
  });
}
