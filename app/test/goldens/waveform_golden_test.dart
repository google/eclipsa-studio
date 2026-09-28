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

// Pixel goldens for the waveform painter (ES-507) over every theme, in
// the three per-type styles (Object, Channel, Scene) whose colours are
// theme tokens. The painter draws no text, so the font axis is skipped.
// The peaks are 400 bins of a 3 Hz amplitude envelope over a fixed
// pseudo-random fill, with RMS at 60% of the envelope, so the wave
// fill, the RMS band and the centerline all appear.
//
// Regenerate after an intended change to the painter or a theme's
// element-type colours:
//
//   flutter test test/goldens --update-goldens
//
// The images are rasterized on macOS (the only platform `flutter test`
// runs on in CI).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eclipsa_studio/waveform/peak_data.dart';
import 'package:eclipsa_studio/waveform/waveform_painter.dart';
import 'package:eclipsa_studio/waveform/waveform_style.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_matrix.dart';

const int _bins = 400;

ChannelPeaks _peaks() {
  final mins = Float32List(_bins);
  final maxs = Float32List(_bins);
  final rms = Float32List(_bins);
  for (var i = 0; i < _bins; i++) {
    final envelope =
        0.9 * (0.55 + 0.45 * math.sin(2 * math.pi * 3 * i / _bins));
    // A fixed per-bin jitter in [0, 1) computed in closed form, so the
    // golden does not depend on an SDK's random sequence.
    final jitter = (math.sin(i * 12.9898) * 43758.5453) % 1.0;
    maxs[i] = envelope * (0.6 + 0.4 * jitter);
    mins[i] = -envelope * (0.6 + 0.4 * (1.0 - jitter));
    rms[i] = envelope * 0.6;
  }
  return ChannelPeaks(
    mins: mins,
    maxs: maxs,
    rms: rms,
    samplesPerPeak: 256,
    channelIndex: 0,
  );
}

void main() {
  final peaks = _peaks();
  final styles = <String, WaveformStyle Function()>{
    'object': () => WaveformStyle.object,
    'channel': () => WaveformStyle.channel,
    'scene': () => WaveformStyle.scene,
  };

  forEachThemeAndFont(fonts: false, (theme, font) {
    for (final entry in styles.entries) {
      final name = '${entry.key}_${themeTag(theme)}';
      testWidgets('waveform $name', (tester) async {
        final subject = await pumpGoldenSubject(
          tester,
          () => CustomPaint(
            painter: WaveformPainter(peaks: peaks, style: entry.value()),
          ),
          size: const Size(400, 80),
          theme: theme,
          font: font,
        );
        await expectLater(
          subject,
          matchesGoldenFile('waveform/waveform_$name.png'),
        );
      });
    }
  });
}
