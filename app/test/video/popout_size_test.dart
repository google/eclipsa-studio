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

import 'dart:ui';

import 'package:eclipsa_studio/video/popout_size.dart';
import 'package:eclipsa_studio/video/video_backend_kind.dart';
import 'package:eclipsa_studio/video/video_popout_app.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pop-out window's size for a clip (ES-744): the picture plus the
/// two strips, scaled down to fit 90% of the display, never under
/// 320 px wide unless the display cap is smaller, in whole logical
/// pixels; the aspect ratio at the fitted width; and the picture size
/// riding through the window args.
void main() {
  const chrome = 56.0;
  const display = Size(1920, 1080);

  /// The picture's ratio inside a window size.
  double pictureRatio(Size s) => s.width / (s.height - chrome);

  test('a clip that fits opens at its pixel size plus the strips', () {
    final size = fitPopoutSize(const Size(1280, 720), display, chrome: chrome);
    expect(size, const Size(1280, 720 + chrome));
  });

  test('a clip wider than the display is scaled to 90% of its width', () {
    final size = fitPopoutSize(const Size(3840, 1080), display, chrome: chrome);
    expect(size, const Size(1728, 486 + chrome));
    expect(pictureRatio(size), closeTo(3840 / 1080, 0.01));
  });

  test('a clip taller than the display is scaled to 90% of its height', () {
    final size = fitPopoutSize(const Size(1080, 1920), display, chrome: chrome);
    // 916 px of picture height under the cap, 515 wide at that scale.
    expect(size, const Size(515, 916 + chrome));
    expect(size.height, lessThanOrEqualTo(1080 * 0.9));
    expect(pictureRatio(size), closeTo(1080 / 1920, 0.01));
  });

  test('both strips count against the display height', () {
    // 972 px of display height at 90%, minus the strips, for a picture
    // that is exactly as tall as that limit.
    final size = fitPopoutSize(
      const Size(1000, 972 - chrome),
      display,
      chrome: chrome,
    );
    expect(size, const Size(1000, 972));
    final taller = fitPopoutSize(const Size(1000, 972), display, chrome: 56);
    expect(taller.height, lessThanOrEqualTo(972));
    expect(taller.width, lessThan(1000));
  });

  test('a small clip opens at least 320 px wide', () {
    final size = fitPopoutSize(const Size(160, 90), display, chrome: chrome);
    expect(size, const Size(320, 180 + chrome));
  });

  test('the display cap beats the width floor on a tiny display', () {
    final size = fitPopoutSize(
      const Size(1920, 1080),
      const Size(300, 200),
      chrome: chrome,
    );
    expect(size.width, lessThanOrEqualTo(270));
    expect(size.height, lessThanOrEqualTo(180));
    expect(size, const Size(220, 124 + chrome));
  });

  test('a tall narrow clip stays within the display height', () {
    final size = fitPopoutSize(
      const Size(200, 1600),
      const Size(1440, 900),
      chrome: chrome,
    );
    expect(size.height, lessThanOrEqualTo(810));
    expect(size.width, lessThan(320));
    expect(size, const Size(94, 752 + chrome));
  });

  test('a display shorter than the strips gives no picture height', () {
    final size = fitPopoutSize(
      const Size(1280, 720),
      const Size(400, 40),
      chrome: chrome,
    );
    expect(size, const Size(0, chrome));
  });

  test('the size is in whole logical pixels', () {
    final size = fitPopoutSize(
      const Size(1920, 1080),
      const Size(1440, 900),
      chrome: chrome,
    );
    expect(size, const Size(1296, 729 + chrome));
  });

  test('the aspect ratio at a width matches the fitted window', () {
    // Within the rounding of the fitted height to whole pixels.
    for (final (video, screen) in [
      (const Size(1280, 720), display),
      (const Size(1920, 1080), const Size(1440, 900)),
      (const Size(1080, 1920), display),
    ]) {
      final size = fitPopoutSize(video, screen, chrome: chrome);
      expect(
        popoutAspectRatio(video, width: size.width, chrome: chrome),
        closeTo(size.width / size.height, 1e-3),
        reason: '$video on $screen',
      );
    }
  });

  test('the picture size rides through the window arguments', () {
    final args = parsePopoutArgs(
      encodePopoutArgs(
        '/clips/a.mp4',
        backendKind: VideoBackendKind.avFoundation,
        videoSize: const Size(1920, 1080),
      ),
    );
    expect(args.videoSize, const Size(1920, 1080));
    expect(args.videoPath, '/clips/a.mp4');
    expect(args.backendKind, VideoBackendKind.avFoundation);
  });

  test('an unknown picture size stays null', () {
    final args = parsePopoutArgs(
      encodePopoutArgs(
        '/clips/a.mp4',
        backendKind: VideoBackendKind.avFoundation,
      ),
    );
    expect(args.videoSize, isNull);
  });
}
