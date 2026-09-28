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

import 'package:eclipsa_studio/export/iamf_format_maps.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('soundSystemToOarLayout', () {
    // The bug this guards: 10.2.9.3 mapped to null ("not supported by OAR")
    // even though ck_oar_layout_a293 is 11, so every 10.2.9.3 mix presentation
    // silently exported with no loudness metadata.
    test('every SoundSystem maps to an OAR target layout', () {
      for (final s in SoundSystem.values) {
        expect(
          soundSystemToOarLayout(s),
          isNotNull,
          reason:
              '${s.label} has no oar_layout_t — offline rendering and '
              'loudness measurement silently skip it',
        );
      }
    });

    // Pinned against oar_layout_t in oar.h. A renumbering upstream must break
    // this rather than silently render every layout to the wrong target.
    test('values match oar.h', () {
      const expected = <SoundSystem, int>{
        SoundSystem.mono: 1, // ck_oar_layout_mono
        SoundSystem.stereo: 2, // ck_oar_layout_stereo
        SoundSystem.surround5_1: 3, // ck_oar_layout_51
        SoundSystem.surround5_1_2: 4, // ck_oar_layout_512
        SoundSystem.surround5_1_4: 5, // ck_oar_layout_514
        SoundSystem.surround7_1: 6, // ck_oar_layout_71
        SoundSystem.surround7_1_2: 7, // ck_oar_layout_712
        SoundSystem.surround7_1_4: 8, // ck_oar_layout_714
        SoundSystem.surround3_1_2: 9, // ck_oar_layout_312
        SoundSystem.surround9_1_6: 10, // ck_oar_layout_916
        SoundSystem.surround10_2_9_3: 11, // ck_oar_layout_a293 (SS-H)
        SoundSystem.surround7_1_5_4: 12, // ck_oar_layout_7154
        SoundSystem.binaural: 0xFF, // ck_oar_layout_binaural
      };
      expect(expected.length, SoundSystem.values.length);
      expected.forEach((s, oar) {
        expect(soundSystemToOarLayout(s), oar, reason: s.label);
      });
    });

    test('the mapping is injective, so the inverse round-trips', () {
      final seen = <int, SoundSystem>{};
      for (final s in SoundSystem.values) {
        final oar = soundSystemToOarLayout(s)!;
        expect(
          seen.containsKey(oar),
          isFalse,
          reason: '${s.label} and ${seen[oar]?.label} both map to $oar',
        );
        seen[oar] = s;
        expect(soundSystemForOarValue(oar), s);
      }
    });
  });

  group('iamfSoundSystemName', () {
    test('binaural is a layout type, not a sound system', () {
      expect(iamfSoundSystemName(SoundSystem.binaural), isNull);
      for (final s in SoundSystem.values) {
        if (s == SoundSystem.binaural) continue;
        expect(iamfSoundSystemName(s), isNotNull, reason: s.label);
      }
    });

    // The docstring claims the IAMF name carries the enum's ITU notation.
    // It is a hand-maintained switch, so assert the claim instead of trusting
    // it: "9+10+3" must land in SOUND_SYSTEM_H_9_10_3.
    test('each name ends in its ituNotation', () {
      for (final s in SoundSystem.values) {
        final name = iamfSoundSystemName(s);
        if (name == null) continue;
        expect(
          name,
          endsWith('_${s.ituNotation.replaceAll('+', '_')}'),
          reason: '${s.label} declares ${s.ituNotation}',
        );
      }
    });
  });

  group('layout naming', () {
    // One spelling for the layout across both enums, so
    // LoudspeakerLayout.fromDisplayName resolves a SoundSystem's label.
    test('SoundSystem.label matches LoudspeakerLayout.displayName', () {
      for (final s in SoundSystem.values) {
        final l = LoudspeakerLayout.fromDisplayName(s.label);
        if (l == null) continue; // mono/22.2-only systems need no twin
        expect(l.displayName, s.label);
      }
      expect(
        LoudspeakerLayout.fromDisplayName(SoundSystem.surround10_2_9_3.label),
        LoudspeakerLayout.k10_2_9_3,
      );
    });

    test('the second name for 10.2.9.3 is UI-only', () {
      expect(SoundSystem.surround10_2_9_3.label, '10.2.9.3');
      expect(SoundSystem.surround10_2_9_3.uiLabel, '10.2.9.3 (22.2)');
      for (final s in SoundSystem.values) {
        if (s == SoundSystem.surround10_2_9_3) continue;
        expect(s.uiLabel, s.label, reason: '${s.name} needs no second name');
      }
    });
  });
}
