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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/waveform/wav_decoder.dart';

/// [WavDecoder] is a thin mapping over the engine's shared WAV parser
/// (`eclipsa_studio_wav_probe_json`); the byte-level acceptance matrix —
/// containers, encodings, malformed files — is pinned engine-side in
/// engine/test/wav_probe_ffi_test.cc and the engine/wav conformance
/// suite. These tests cover the Dart-side mapping: JSON → [WavInfo],
/// error routing, and the UI's 32-channel cap.
String okJson({
  String container = 'riff',
  int channels = 2,
  int sampleRate = 48000,
  int bitsPerSample = 16,
  bool isFloat = false,
  int numFrames = 256,
  int dataOffset = 92,
  int? dataSize,
  int axmlBytes = 0,
  int chnaBytes = 0,
}) => jsonEncode({
  'ok': true,
  'container': container,
  'channels': channels,
  'sample_rate': sampleRate,
  'bits_per_sample': bitsPerSample,
  'is_float': isFloat,
  'num_frames': numFrames,
  'data_offset': dataOffset,
  'data_size': dataSize ?? numFrames * channels * (bitsPerSample ~/ 8),
  'axml_bytes': axmlBytes,
  'chna_bytes': chnaBytes,
});

String errorJson(String message) => jsonEncode({'ok': false, 'error': message});

void main() {
  tearDown(() => WavDecoder.probeForTesting = null);

  group('readInfo', () {
    test('maps probe JSON onto WavInfo', () async {
      WavDecoder.probeForTesting = (_) => okJson(
        channels: 6,
        sampleRate: 96000,
        bitsPerSample: 24,
        numFrames: 96000,
      );
      final info = await WavDecoder.readInfo('x.wav');
      expect(info.channels, 6);
      expect(info.sampleRate, 96000);
      expect(info.bitsPerSample, 24);
      expect(info.audioFormat, 1);
      expect(info.totalSamples, 96000);
      expect(info.dataSize, 96000 * 6 * 3);
      expect(info.durationSeconds, 1.0);
    });

    test('maps IEEE-float sources to audioFormat 3', () async {
      WavDecoder.probeForTesting = (_) =>
          okJson(isFloat: true, bitsPerSample: 32);
      expect((await WavDecoder.readInfo('f.wav')).audioFormat, 3);
    });

    test('parser rejections surface as FormatException', () async {
      WavDecoder.probeForTesting = (_) =>
          errorJson('Unsupported format tag: 85');
      await expectLater(
        WavDecoder.readInfo('bad.wav'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('format tag'),
          ),
        ),
      );
    });

    test('unopenable files surface as FileSystemException', () async {
      WavDecoder.probeForTesting = (_) =>
          errorJson('Cannot open WAV file: absent.wav');
      await expectLater(
        WavDecoder.readInfo('absent.wav'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('accepts 32 channels, rejects 33 (engine scratch cap)', () async {
      WavDecoder.probeForTesting = (_) => okJson(channels: 32);
      expect((await WavDecoder.readInfo('c32.wav')).channels, 32);

      WavDecoder.probeForTesting = (_) => okJson(channels: 33);
      await expectLater(
        WavDecoder.readInfo('c33.wav'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('channel count'),
          ),
        ),
      );
    });
  });

  group('probeRaw', () {
    test('exposes ADM metadata sizes', () async {
      WavDecoder.probeForTesting = (_) =>
          okJson(container: 'bw64', axmlBytes: 23, chnaBytes: 12);
      final raw = await WavDecoder.probeRaw('adm.wav');
      expect(raw['container'], 'bw64');
      expect(raw['axml_bytes'], 23);
      expect(raw['chna_bytes'], 12);
    });
  });
}
