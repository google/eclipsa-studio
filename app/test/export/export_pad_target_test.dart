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
  group('exportPadTarget', () {
    test('LPCM aligns up to the next coded-frame multiple', () {
      expect(
        exportPadTarget(
          lengthFrames: 9402353,
          framesPerCodedBlock: 1024,
          codec: IamfCodec.lpcm,
        ),
        9402368, // ceil(9402353 / 1024) * 1024; trim 15.
      );
    });

    test('LPCM already aligned needs no padding', () {
      expect(
        exportPadTarget(
          lengthFrames: 1024 * 12,
          framesPerCodedBlock: 1024,
          codec: IamfCodec.lpcm,
        ),
        1024 * 12,
      );
    });

    test('Opus aligns length + encoder delay to the frame grid (ES-485)', () {
      // The ES-485 repro: 9,402,353 frames padded to the plain 960
      // multiple (9,403,200) declared trim 847; with the 312-sample
      // delay shift the encoder needed 648 more, overflowing the
      // one-frame end-trim limit. The delay-aware target keeps
      // (target + delay) on the grid so the trim alone is the end trim.
      final target = exportPadTarget(
        lengthFrames: 9402353,
        framesPerCodedBlock: kOpusFramesPerCodedBlock,
        codec: IamfCodec.opus,
      );
      expect((target + kOpusEncoderDelay) % kOpusFramesPerCodedBlock, 0);
      expect(target, greaterThanOrEqualTo(9402353));
      expect(target - 9402353, lessThan(kOpusFramesPerCodedBlock));
      expect(target, 9402888); // trim 535.
    });

    test('Opus target already on the shifted grid needs no padding', () {
      const aligned = 14 * kOpusFramesPerCodedBlock - kOpusEncoderDelay;
      expect(
        exportPadTarget(
          lengthFrames: aligned,
          framesPerCodedBlock: kOpusFramesPerCodedBlock,
          codec: IamfCodec.opus,
        ),
        aligned,
      );
    });

    test('Opus trim stays under one frame across lengths', () {
      for (var length = 1; length <= 4 * 960 + 7; length += 313) {
        final target = exportPadTarget(
          lengthFrames: length,
          framesPerCodedBlock: kOpusFramesPerCodedBlock,
          codec: IamfCodec.opus,
        );
        expect(target, greaterThanOrEqualTo(length));
        expect(target - length, lessThan(kOpusFramesPerCodedBlock));
        expect((target + kOpusEncoderDelay) % kOpusFramesPerCodedBlock, 0);
      }
    });

    test('zero length yields zero target', () {
      expect(
        exportPadTarget(
          lengthFrames: 0,
          framesPerCodedBlock: 1024,
          codec: IamfCodec.lpcm,
        ),
        0,
      );
    });
  });
}
