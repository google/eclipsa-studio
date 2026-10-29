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

// Pixel goldens for the two multichannel meter painters (ES-507): the
// full meter with its channel labels and dB scale over every theme and
// font mode, and the sidebar mini meter (no text) over every theme. A
// 9.1.6 output meter at the Renderer view's 192 px width covers the
// dense label layouts (ES-795).
// Inputs are synthetic: a 7.1.4 element whose levels step down the
// scale, with a peak-hold above each level and one clipped channel, so
// the bar ramp, the peak line and the clip indicator all appear.
//
// Regenerate after an intended change to the ramp, the scale or a
// theme's meter colours:
//
//   flutter test test/goldens --update-goldens
//
// The images are rasterized on macOS (the only platform `flutter test`
// runs on in CI).

import 'dart:math' as math;

import 'package:eclipsa_studio/meters/mini_multichannel_meter.dart';
import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_fonts.dart';
import '../support/golden_matrix.dart';

/// 12 channels (7.1.4) from 0 dBFS down to -55 dBFS in 5 dB steps.
final List<double> _levels = List.generate(
  12,
  (i) => math.pow(10, -5.0 * i / 20).toDouble(),
);

/// Peak-hold 3 dB above each level, capped at full scale.
final List<double> _peaks = _levels
    .map((l) => math.min(1.0, l * math.pow(10, 3 / 20)))
    .toList();

/// The hottest channel has latched a clip.
final List<bool> _clipped = List.generate(12, (i) => i == 0);

void main() {
  setUpAll(loadGoldenFonts);

  forEachThemeAndFont((theme, font) {
    final name = '${themeTag(theme)}_${fontTag(font)}';
    testWidgets('multichannel meter, theme $name', (tester) async {
      final subject = await pumpGoldenSubject(
        tester,
        () => MultichannelMeter(
          levels: _levels,
          peaks: _peaks,
          clipped: _clipped,
        ),
        size: const Size(260, 180),
        theme: theme,
        font: font,
      );
      await expectLater(
        subject,
        matchesGoldenFile('meters/multichannel_$name.png'),
      );
    });
  });

  // The Renderer view's output meter at 9.1.6: 16 bars in a 192 px
  // meter (a 240 px panel less its padding and the gain-reduction bar),
  // a 9.8 px bar pitch, labelled with the familiar names in OBR's alt
  // order (L R C LFE Lw Rw Lss Rss Lrs Rrs Ltf Rtf Lts Rts Ltr Rtr,
  // ES-960). Labels: one rotated row at Small, two staggered horizontal
  // rows at Medium and Large.
  final levels916 = List.generate(
    16,
    (i) => math.pow(10, -3.0 * i / 20).toDouble(),
  );
  forEachThemeAndFont((theme, font) {
    final name = '${themeTag(theme)}_${fontTag(font)}';
    testWidgets('9.1.6 output meter, theme $name', (tester) async {
      final subject = await pumpGoldenSubject(
        tester,
        () => MultichannelMeter(
          levels: levels916,
          labels: OarLayout.layout916.meterLabels,
        ),
        size: const Size(192, 220),
        theme: theme,
        font: font,
      );
      await expectLater(
        subject,
        matchesGoldenFile('meters/multichannel_916_$name.png'),
      );
    });
  });

  forEachThemeAndFont(fonts: false, (theme, font) {
    final name = themeTag(theme);
    testWidgets('mini multichannel meter, theme $name', (tester) async {
      final subject = await pumpGoldenSubject(
        tester,
        () => MiniMultichannelMeter(
          levels: _levels,
          peaks: _peaks,
          clipped: _clipped,
        ),
        size: const Size(72, 40),
        theme: theme,
        font: font,
      );
      await expectLater(
        subject,
        matchesGoldenFile('meters/mini_multichannel_$name.png'),
      );
    });
  });
}
