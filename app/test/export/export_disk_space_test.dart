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

import 'package:eclipsa_studio/export/export_disk_space.dart';
import 'package:eclipsa_studio/export/iamf_export_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('estimateIamfBytes', () {
    test('LPCM is channels x bytes per sample x frames', () {
      expect(
        estimateIamfBytes(
          codec: IamfCodec.lpcm,
          bitDepth: 16,
          sampleRate: 48000,
          totalChannels: 14,
          frames: 7710720,
          opusBitratePerChannel: 64000,
        ),
        14 * 2 * 7710720,
      );
    });

    test('Opus is per-channel bitrate x channels x seconds', () {
      expect(
        estimateIamfBytes(
          codec: IamfCodec.opus,
          bitDepth: 24,
          sampleRate: 48000,
          totalChannels: 2,
          frames: 48000 * 10,
          opusBitratePerChannel: 64000,
        ),
        2 * 64000 ~/ 8 * 10,
      );
    });

    test('nothing to encode is zero bytes', () {
      expect(
        estimateIamfBytes(
          codec: IamfCodec.lpcm,
          bitDepth: 24,
          sampleRate: 48000,
          totalChannels: 0,
          frames: 100,
          opusBitratePerChannel: 64000,
        ),
        0,
      );
    });
  });

  group('ExportSpaceNeed.compute', () {
    test('MP4 stages two copies of the video and audio, then one more', () {
      final need = ExportSpaceNeed.compute(
        muxToMp4: true,
        iamfBytes: 100,
        videoBytes: 1000,
      );
      expect(need.scratchBytes, 2200);
      expect(need.destinationBytes, 1100);
    });

    test('bare IAMF writes the audio to the destination only', () {
      final need = ExportSpaceNeed.compute(
        muxToMp4: false,
        iamfBytes: 100,
        videoBytes: 1000,
      );
      expect(need.scratchBytes, 0);
      expect(need.destinationBytes, 100);
    });
  });

  group('diskSpaceShortfalls', () {
    const need = ExportSpaceNeed(scratchBytes: 2200, destinationBytes: 1100);

    test('one volume: scratch and destination needs add up', () {
      const scratch = VolumeSpace(path: '/tmp', freeBytes: 3000, volumeId: 1);
      const dest = VolumeSpace(path: '/out', freeBytes: 3000, volumeId: 1);
      final short = diskSpaceShortfalls(
        need: need,
        scratch: scratch,
        destination: dest,
      );
      expect(short, hasLength(1));
      expect(short.single.path, '/out');
      expect(short.single.neededBytes, 3300);
      expect(short.single.freeBytes, 3000);
    });

    test('one volume with room reports nothing', () {
      const scratch = VolumeSpace(path: '/tmp', freeBytes: 3300, volumeId: 1);
      const dest = VolumeSpace(path: '/out', freeBytes: 3300, volumeId: 1);
      expect(
        diskSpaceShortfalls(need: need, scratch: scratch, destination: dest),
        isEmpty,
      );
    });

    test('two volumes are checked separately', () {
      const scratch = VolumeSpace(path: '/tmp', freeBytes: 2000, volumeId: 1);
      const dest = VolumeSpace(path: '/ext', freeBytes: 1000, volumeId: 2);
      final short = diskSpaceShortfalls(
        need: need,
        scratch: scratch,
        destination: dest,
      );
      expect(short.map((s) => s.path), ['/tmp', '/ext']);
      expect(short[0].neededBytes, 2200);
      expect(short[1].neededBytes, 1100);
    });

    test('bare IAMF export has no scratch volume', () {
      const dest = VolumeSpace(path: '/out', freeBytes: 50, volumeId: 2);
      final short = diskSpaceShortfalls(
        need: const ExportSpaceNeed(scratchBytes: 0, destinationBytes: 100),
        scratch: null,
        destination: dest,
      );
      expect(short, hasLength(1));
      expect(short.single.neededBytes, 100);
    });
  });

  group('formatBytes', () {
    test('uses decimal units with one decimal from a gigabyte', () {
      expect(formatBytes(40), '40 bytes');
      expect(formatBytes(312000), '312 kB');
      expect(formatBytes(697637016), '698 MB');
      expect(formatBytes(15919000000), '15.9 GB');
    });
  });
}
