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
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for [longestAudioSeconds], the audio contribution
/// to the timeline extent. Pins the mixed-sample-rate rule: elements are
/// compared by duration in seconds, never by raw frame count — a 96 kHz
/// file with more frames but fewer seconds must not truncate the timeline
/// below a longer 48 kHz file.
void main() {
  AudioElement elem(int id, {WavInfo? wav}) => AudioElement(
    id: id,
    name: 'e$id',
    type: 'Channel',
    layout: 'Stereo',
    codec: 'Opus',
    color: 0xFF000000,
    wavInfo: wav,
  );

  WavInfo wav({required int totalSamples, required int sampleRate}) => WavInfo(
    channels: 2,
    sampleRate: sampleRate,
    bitsPerSample: 24,
    audioFormat: 1,
    dataOffset: 44,
    dataSize: totalSamples * 2 * 3,
    totalSamples: totalSamples,
  );

  group('longestAudioSeconds', () {
    test('mixed rates: longest in seconds wins, not most frames', () {
      // 60 s @ 48 kHz (2.88 M frames) vs 40 s @ 96 kHz (3.84 M frames).
      // Frame-count ordering would crown the 96 kHz file and report 40 s.
      final elements = [
        elem(1, wav: wav(totalSamples: 60 * 48000, sampleRate: 48000)),
        elem(2, wav: wav(totalSamples: 40 * 96000, sampleRate: 96000)),
      ];
      expect(longestAudioSeconds(elements), 60.0);
    });

    test('single element reports its own duration', () {
      final elements = [
        elem(1, wav: wav(totalSamples: 30 * 44100, sampleRate: 44100)),
      ];
      expect(longestAudioSeconds(elements), 30.0);
    });

    test('elements without a WAV contribute nothing', () {
      final elements = [
        elem(1),
        elem(2, wav: wav(totalSamples: 10 * 48000, sampleRate: 48000)),
        elem(3),
      ];
      expect(longestAudioSeconds(elements), 10.0);
    });

    test('empty list and all-empty elements report 0', () {
      expect(longestAudioSeconds(const []), 0.0);
      expect(longestAudioSeconds([elem(1), elem(2)]), 0.0);
    });

    test('equal-rate sessions keep the plain longest file', () {
      final elements = [
        elem(1, wav: wav(totalSamples: 20 * 48000, sampleRate: 48000)),
        elem(2, wav: wav(totalSamples: 50 * 48000, sampleRate: 48000)),
        elem(3, wav: wav(totalSamples: 35 * 48000, sampleRate: 48000)),
      ];
      expect(longestAudioSeconds(elements), 50.0);
    });

    test('fractional durations are not truncated', () {
      // 1.5 s @ 48 kHz alongside 1 s @ 96 kHz.
      final elements = [
        elem(1, wav: wav(totalSamples: 72000, sampleRate: 48000)),
        elem(2, wav: wav(totalSamples: 96000, sampleRate: 96000)),
      ];
      expect(longestAudioSeconds(elements), 1.5);
    });
  });
}
