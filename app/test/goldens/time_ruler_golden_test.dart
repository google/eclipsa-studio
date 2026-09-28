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

// Pixel goldens for the time ruler (ES-507): ticks, labels and the
// playhead head over every theme and font mode. Each theme's chrome
// style picks its own tick heights, label offset and head shape, so
// the matrix covers every branch of the painter. The strip is 600 px
// wide over a 60 s timeline at 2x zoom, scrolled a quarter in, with
// the playhead at 24 s.
//
// Regenerate after an intended change to the ruler or a theme's ruler
// colours:
//
//   flutter test test/goldens --update-goldens
//
// The images are rasterized on macOS (the only platform `flutter test`
// runs on in CI).

import 'package:eclipsa_studio/widgets/time_ruler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_fonts.dart';
import '../support/golden_matrix.dart';

void main() {
  setUpAll(loadGoldenFonts);

  forEachThemeAndFont((theme, font) {
    final name = '${themeTag(theme)}_${fontTag(font)}';
    testWidgets('time ruler, theme $name', (tester) async {
      final subject = await pumpGoldenSubject(
        tester,
        () => const TimeRulerStrip(
          durationSeconds: 60,
          playheadSeconds: 24,
          zoomLevel: 2,
          scrollOffset: 0.25,
        ),
        size: const Size(600, TimeRulerStrip.height),
        theme: theme,
        font: font,
      );
      await expectLater(
        subject,
        matchesGoldenFile('timeline/time_ruler_$name.png'),
      );
    });
  });
}
