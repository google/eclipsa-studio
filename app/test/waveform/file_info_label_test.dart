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

import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

WavInfo _info({int sampleRate = 44100}) => WavInfo(
  channels: 2,
  sampleRate: sampleRate,
  bitsPerSample: 24,
  audioFormat: 1,
  dataOffset: 44,
  dataSize: sampleRate * 2 * 3,
  totalSamples: sampleRate, // 1 second
);

void main() {
  group('fileInfoLabel resampling annotation', () {
    test('plain rate when no engine rate is given', () {
      expect(
        fileInfoLabel(_info(), 'a.wav'),
        'a.wav · 2ch · 24bit · 44100 Hz · 00:01.000',
      );
    });

    test('plain rate when file rate matches the engine rate', () {
      expect(
        fileInfoLabel(_info(sampleRate: 48000), 'a.wav', engineRate: 48000),
        'a.wav · 2ch · 24bit · 48000 Hz · 00:01.000',
      );
    });

    test('annotates file → engine rate when they differ', () {
      expect(
        fileInfoLabel(_info(), 'a.wav', engineRate: 48000),
        'a.wav · 2ch · 24bit · 44100 → 48000 Hz · 00:01.000',
      );
    });

    test('omits the filename part when null', () {
      expect(
        fileInfoLabel(_info(), null, engineRate: 48000),
        '2ch · 24bit · 44100 → 48000 Hz · 00:01.000',
      );
    });
  });
}
