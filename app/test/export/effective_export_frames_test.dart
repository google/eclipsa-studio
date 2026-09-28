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

import 'package:eclipsa_studio/export/iamf_export_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effectiveExportFrames', () {
    test('IAMF-only always exports the full timeline', () {
      expect(
        effectiveExportFrames(
          longestFrames: 480000,
          videoFrames: 96000,
          isMp4: false,
        ),
        480000,
      );
    });

    test('MP4 clamps to a shorter video', () {
      expect(
        effectiveExportFrames(
          longestFrames: 480000,
          videoFrames: 96000,
          isMp4: true,
        ),
        96000,
      );
    });

    test('MP4 leaves audio shorter than the video alone', () {
      expect(
        effectiveExportFrames(
          longestFrames: 96000,
          videoFrames: 480000,
          isMp4: true,
        ),
        96000,
      );
    });

    test('MP4 with equal lengths is not clamped', () {
      expect(
        effectiveExportFrames(
          longestFrames: 480000,
          videoFrames: 480000,
          isMp4: true,
        ),
        480000,
      );
    });

    test('MP4 fails open when the video duration is unresolved', () {
      expect(
        effectiveExportFrames(
          longestFrames: 480000,
          videoFrames: 0,
          isMp4: true,
        ),
        480000,
      );
    });

    test('no audio yields zero regardless of video', () {
      expect(
        effectiveExportFrames(
          longestFrames: 0,
          videoFrames: 96000,
          isMp4: true,
        ),
        0,
      );
    });
  });
}
