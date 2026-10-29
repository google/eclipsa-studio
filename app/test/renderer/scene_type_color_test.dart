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

import 'package:eclipsa_studio/renderer/scene_bridge.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 3D scene colours a channel-based element's sources from the
/// element's type in the active theme, as the Elements view draws its
/// row, and not from the colour the session stored for the element.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  AudioElement stereo(int color) => AudioElement(
    id: 1,
    name: 'e',
    type: 'Channel',
    layout: 'Stereo',
    codec: 'LPCM',
    color: color,
  );

  List<Object> sourceColors({required int stored, bool onHeadphones = false}) =>
      [
        for (final s in SceneBridge.build(
          elements: [stereo(stored)],
          outputLayout: SpeakerLayout.stereo,
          isBinauralTarget: onHeadphones,
          stereoOnHeadphones: onHeadphones ? const {1} : const {},
          levels: const [
            [0.5, 0.25],
          ],
        ).sources)
          s.color,
      ];

  for (final onHeadphones in [false, true]) {
    final where = onHeadphones ? 'inside the head' : 'on loudspeakers';
    test('the stored colour does not reach the sources, $where', () {
      final magenta = sourceColors(
        stored: 0xFFFF00FF,
        onHeadphones: onHeadphones,
      );
      final green = sourceColors(
        stored: 0xFF00FF00,
        onHeadphones: onHeadphones,
      );
      expect(magenta, isNotEmpty);
      expect(magenta, green);
    });
  }

  test('the sources follow the theme, through the type colour', () {
    T.setMode(AppThemeMode.dark);
    final dark = sourceColors(stored: 0xFFFF00FF);
    T.setMode(AppThemeMode.light);
    final light = sourceColors(stored: 0xFFFF00FF);
    expect(aeTypeColor('Channel'), isNot(kThemeDark.typeChannel));
    expect(dark, isNot(light));
  });
}
