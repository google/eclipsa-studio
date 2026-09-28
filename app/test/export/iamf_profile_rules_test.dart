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

import 'package:eclipsa_studio/export/iamf_profile_rules.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixture helpers — keep each test focused on the rule it exercises.

AudioElement _channel({
  required int id,
  String layout = 'Stereo',
  String name = 'Bed',
}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Channel',
    layout: layout,
    codec: 'LPCM',
    color: 0xFF000000,
  );
}

AudioElement _scene({required int id, int order = 1}) {
  return AudioElement(
    id: id,
    name: 'Scene',
    type: 'Scene',
    layout: '${order}OA',
    codec: 'LPCM',
    color: 0xFF000000,
    ambisonicsOrder: order,
  );
}

AudioElement _object({required int id, bool dual = false}) {
  return AudioElement(
    id: id,
    name: 'Obj',
    type: 'Object',
    layout: dual ? 'Dual' : 'Mono',
    codec: 'LPCM',
    color: 0xFF000000,
    isDual: dual,
  );
}

/// A mix whose first sub-mix carries [layouts] (output layouts) and
/// [settings] (per-element rendering config). Defaults to a single stereo
/// output layout and no element settings.
Mix _mix({
  int id = 1,
  String name = 'Main',
  List<MixLayout> layouts = const [MixLayout(soundSystem: SoundSystem.stereo)],
  List<MixElementSettings> settings = const [],
  int subMixCount = 1,
}) {
  return Mix(
    id: id,
    name: name,
    subMixes: [
      for (var i = 0; i < subMixCount; i++)
        SubMix(layouts: layouts, elementSettings: settings),
    ],
  );
}

Set<ProfileConflictKind> _kinds(
  IamfProfile profile, {
  List<AudioElement> elements = const [],
  List<Mix> mixes = const [],
}) {
  return profileConflicts(
    elements: elements,
    mixes: mixes,
    profile: profile,
  ).map((c) => c.kind).toSet();
}

void main() {
  group('spec-version requirements', () {
    test('expanded layouts gate by the version that introduced them', () {
      expect(
        minSpecVersionForLayout(LoudspeakerLayout.stereo),
        IamfSpecVersion.v1_0,
      );
      expect(
        minSpecVersionForLayout(LoudspeakerLayout.k7_1_4),
        IamfSpecVersion.v1_0,
      );
      expect(
        minSpecVersionForLayout(LoudspeakerLayout.k9_1_6),
        IamfSpecVersion.v1_1,
      );
      expect(
        minSpecVersionForLayout(LoudspeakerLayout.k7_1_5_4),
        IamfSpecVersion.v2_0,
      );
      expect(
        minSpecVersionForLayout(LoudspeakerLayout.k10_2_9_3),
        IamfSpecVersion.v2_0,
      );
    });

    test('output layouts gate the same way', () {
      expect(
        minSpecVersionForSoundSystem(SoundSystem.stereo),
        IamfSpecVersion.v1_0,
      );
      expect(
        minSpecVersionForSoundSystem(SoundSystem.surround9_1_6),
        IamfSpecVersion.v1_1,
      );
      expect(
        minSpecVersionForSoundSystem(SoundSystem.surround7_1_5_4),
        IamfSpecVersion.v2_0,
      );
      expect(
        minSpecVersionForSoundSystem(SoundSystem.surround10_2_9_3),
        IamfSpecVersion.v2_0,
      );
    });

    test('head-locked binaural is v2.0.0; stereo/world-locked are v1.0.0', () {
      expect(
        minSpecVersionForHeadphonesMode(HeadphonesRenderingMode.stereo),
        IamfSpecVersion.v1_0,
      );
      expect(
        minSpecVersionForHeadphonesMode(
          HeadphonesRenderingMode.binauralWorldLocked,
        ),
        IamfSpecVersion.v1_0,
      );
      expect(
        minSpecVersionForHeadphonesMode(
          HeadphonesRenderingMode.binauralHeadLocked,
        ),
        IamfSpecVersion.v2_0,
      );
    });
  });

  group('per-profile predicates', () {
    test('Base forbids expanded layouts; Base-Enhanced adds 9.1.6 only', () {
      expect(
        profileAllowsLayout(IamfProfile.base, LoudspeakerLayout.k7_1_4),
        isTrue,
      );
      expect(
        profileAllowsLayout(IamfProfile.base, LoudspeakerLayout.k9_1_6),
        isFalse,
      );
      expect(
        profileAllowsLayout(IamfProfile.baseEnhanced, LoudspeakerLayout.k9_1_6),
        isTrue,
      );
      expect(
        profileAllowsLayout(
          IamfProfile.baseEnhanced,
          LoudspeakerLayout.k7_1_5_4,
        ),
        isFalse,
      );
      expect(
        profileAllowsLayout(
          IamfProfile.baseAdvanced,
          LoudspeakerLayout.k7_1_5_4,
        ),
        isTrue,
      );
    });

    test('head-locked & binaural filter only from Base-Advanced', () {
      for (final p in [
        IamfProfile.simple,
        IamfProfile.base,
        IamfProfile.baseEnhanced,
      ]) {
        expect(
          profileAllowsHeadphonesMode(
            p,
            HeadphonesRenderingMode.binauralHeadLocked,
          ),
          isFalse,
          reason: '${p.label} must forbid head-locked',
        );
        expect(profileAllowsBinauralFilterProfile(p), isFalse);
      }
      for (final p in [
        IamfProfile.baseAdvanced,
        IamfProfile.advanced1,
        IamfProfile.advanced2,
      ]) {
        expect(
          profileAllowsHeadphonesMode(
            p,
            HeadphonesRenderingMode.binauralHeadLocked,
          ),
          isTrue,
        );
        expect(profileAllowsBinauralFilterProfile(p), isTrue);
      }
    });

    test('object type gated by allowObjectBased', () {
      expect(profileAllowsElementType(IamfProfile.base, 'Object'), isFalse);
      expect(profileAllowsElementType(IamfProfile.base, 'Channel'), isTrue);
      expect(
        profileAllowsElementType(IamfProfile.baseAdvanced, 'Object'),
        isTrue,
      );
    });
  });

  group('minProfileFor*', () {
    test('layouts', () {
      expect(minProfileForLayout(LoudspeakerLayout.stereo), IamfProfile.simple);
      expect(
        minProfileForLayout(LoudspeakerLayout.k9_1_6),
        IamfProfile.baseEnhanced,
      );
      expect(
        minProfileForLayout(LoudspeakerLayout.k7_1_5_4),
        IamfProfile.baseAdvanced,
      );
      // Layout-filter only: 10.2.9.3 is accepted from Base-Advanced even
      // though its 24 channels exceed Base-Advanced's budget (the channel
      // conflict handles that separately).
      expect(
        minProfileForLayout(LoudspeakerLayout.k10_2_9_3),
        IamfProfile.baseAdvanced,
      );
    });

    test('output layouts, element types, rendering config', () {
      expect(minProfileForSoundSystem(SoundSystem.stereo), IamfProfile.simple);
      expect(
        minProfileForSoundSystem(SoundSystem.surround9_1_6),
        IamfProfile.baseEnhanced,
      );
      expect(
        minProfileForSoundSystem(SoundSystem.surround7_1_5_4),
        IamfProfile.baseAdvanced,
      );
      expect(minProfileForElementType('Channel'), IamfProfile.simple);
      expect(minProfileForElementType('Object'), IamfProfile.baseAdvanced);
      expect(
        minProfileForHeadphonesMode(HeadphonesRenderingMode.stereo),
        IamfProfile.simple,
      );
      expect(
        minProfileForHeadphonesMode(HeadphonesRenderingMode.binauralHeadLocked),
        IamfProfile.baseAdvanced,
      );
      expect(minProfileForBinauralFilterProfile(), IamfProfile.baseAdvanced);
    });

    test('channel counts', () {
      expect(minProfileForChannelCount(2), IamfProfile.simple);
      expect(minProfileForChannelCount(16), IamfProfile.simple);
      expect(minProfileForChannelCount(17), IamfProfile.base);
      expect(minProfileForChannelCount(18), IamfProfile.base);
      // 4OA (25 ch) fits only the 28-channel profiles.
      expect(minProfileForChannelCount(25), IamfProfile.baseEnhanced);
      expect(minProfileForChannelCount(28), IamfProfile.baseEnhanced);
      expect(minProfileForChannelCount(29), isNull);
    });

    test('whole sessions (load-time validation, ES-490)', () {
      // One stereo bed fits the lowest profile.
      expect(
        minProfileForSession(elements: [_channel(id: 1)], mixes: [_mix()]),
        IamfProfile.simple,
      );
      // Three elements exceed Simple's 1 and Base's 2 AE caps.
      expect(
        minProfileForSession(
          elements: [_channel(id: 1), _channel(id: 2), _channel(id: 3)],
          mixes: [_mix()],
        ),
        IamfProfile.baseEnhanced,
      );
      // Objects need Base-Advanced.
      expect(
        minProfileForSession(elements: [_object(id: 1)], mixes: [_mix()]),
        IamfProfile.baseAdvanced,
      );
      // 29 elements fit no profile (Advanced-2 caps at 28).
      expect(
        minProfileForSession(
          elements: [for (var i = 1; i <= 29; i++) _object(id: i)],
          mixes: [_mix()],
        ),
        isNull,
      );
    });
  });

  group('config gating (element format dialog, ES-152)', () {
    ElementConfig configFor(int channels, String label) =>
        validConfigsForChannelCount(
          channels,
        ).firstWhere((c) => c.label == label);

    test('profileAllowsConfig gates objects and expanded layouts', () {
      expect(
        profileAllowsConfig(IamfProfile.base, configFor(1, 'Object · Mono')),
        isFalse,
      );
      expect(
        profileAllowsConfig(
          IamfProfile.baseAdvanced,
          configFor(1, 'Object · Mono'),
        ),
        isTrue,
      );
      expect(
        profileAllowsConfig(IamfProfile.base, configFor(16, 'Channel · 9.1.6')),
        isFalse,
      );
      expect(
        profileAllowsConfig(IamfProfile.base, configFor(16, 'Scene · 3OA')),
        isTrue,
      );
    });

    test('configs exceeding the channel budget alone are forbidden', () {
      // 4OA is 25 channels. No profile has an ambisonic-order field in
      // the IAMF spec or iamf-tools' profile_filter.cc; the channel
      // budget caps the order, so 4OA fits only
      // Base-Enhanced (28ch); Simple (16), Base (18) and Base-Advanced
      // (18) exclude it standalone.
      final fourOa = configFor(25, 'Scene · 4OA');
      expect(profileAllowsConfig(IamfProfile.simple, fourOa), isFalse);
      expect(profileAllowsConfig(IamfProfile.base, fourOa), isFalse);
      expect(profileAllowsConfig(IamfProfile.baseEnhanced, fourOa), isTrue);
      expect(profileAllowsConfig(IamfProfile.baseAdvanced, fourOa), isFalse);
      expect(minProfileForConfig(fourOa), IamfProfile.baseEnhanced);
      // 3OA (16ch) squeaks into Simple's 16-channel budget.
      expect(
        profileAllowsConfig(IamfProfile.simple, configFor(16, 'Scene · 3OA')),
        isTrue,
      );
      // 10.2.9.3 (24ch) needs v2.0, and Base-Advanced/Advanced-1 only
      // budget 18 — Advanced-2 (28ch) is the first that fits it.
      expect(
        minProfileForConfig(configFor(24, 'Channel · 10.2.9.3')),
        IamfProfile.advanced2,
      );
    });

    test('Custom (Nch) configs budget-gate by their parsed count', () {
      // A non-standard count yields a 'Custom (Nch)' config; the gate
      // must parse N rather than fall back to 0 and wave it through.
      final custom20 = configFor(20, 'Channel · Custom (20ch)');
      expect(profileAllowsConfig(IamfProfile.simple, custom20), isFalse);
      expect(profileAllowsConfig(IamfProfile.base, custom20), isFalse);
      expect(profileAllowsConfig(IamfProfile.baseEnhanced, custom20), isTrue);
      expect(minProfileForConfig(custom20), IamfProfile.baseEnhanced);
    });

    test('minProfileForConfig powers the disabled-option explainer', () {
      expect(
        minProfileForConfig(configFor(16, 'Channel · 9.1.6')),
        IamfProfile.baseEnhanced,
      );
      expect(
        minProfileForConfig(configFor(2, 'Object · Dual')),
        IamfProfile.baseAdvanced,
      );
      expect(
        minProfileForConfig(configFor(2, 'Channel · Stereo')),
        IamfProfile.simple,
      );
    });

    test('gating collapses ambiguity where the profile decides it', () {
      // Under Base, 16ch has a single permitted reading (3OA) — the format
      // dialog is skipped. Base-Enhanced re-opens the 9.1.6 alternative.
      expect(
        profileAllowedConfigsForChannelCount(
          IamfProfile.base,
          16,
        ).map((c) => c.label),
        ['Scene · 3OA'],
      );
      expect(
        profileAllowedConfigsForChannelCount(
          IamfProfile.baseEnhanced,
          16,
        ).length,
        2,
      );
      // Mono/stereo lose their Object reading below Base-Advanced, but
      // stereo keeps its Binaural alternative everywhere.
      expect(
        profileAllowedConfigsForChannelCount(
          IamfProfile.base,
          1,
        ).map((c) => c.label),
        ['Channel · Mono'],
      );
      expect(
        profileAllowedConfigsForChannelCount(
          IamfProfile.base,
          2,
        ).map((c) => c.label),
        ['Channel · Stereo', 'Channel · Binaural'],
      );
      // Bed-vs-bed ambiguities are v1.0-vs-v1.0 — never collapsed.
      expect(
        profileAllowedConfigsForChannelCount(IamfProfile.simple, 6).length,
        2,
      );
    });
  });

  group('audioElementChannelCount', () {
    test('scene orders', () {
      expect(audioElementChannelCount(_scene(id: 1, order: 1)), 4);
      expect(audioElementChannelCount(_scene(id: 1, order: 2)), 9);
      expect(audioElementChannelCount(_scene(id: 1, order: 3)), 16);
      expect(audioElementChannelCount(_scene(id: 1, order: 4)), 25);
    });

    test('objects and channel layouts', () {
      expect(audioElementChannelCount(_object(id: 1)), 1);
      expect(audioElementChannelCount(_object(id: 1, dual: true)), 2);
      expect(audioElementChannelCount(_channel(id: 1, layout: 'Stereo')), 2);
      expect(audioElementChannelCount(_channel(id: 1, layout: '5.1')), 6);
      expect(audioElementChannelCount(_channel(id: 1, layout: '7.1.4')), 12);
      expect(audioElementChannelCount(_channel(id: 1, layout: '9.1.6')), 16);
    });

    test('Custom(Nch) parses with or without a space; unknown is zero', () {
      // validConfigsForChannelCount emits the spaced "Custom (Nch)" form.
      expect(
        audioElementChannelCount(_channel(id: 1, layout: 'Custom (5ch)')),
        5,
      );
      expect(
        audioElementChannelCount(_channel(id: 1, layout: 'Custom(5ch)')),
        5,
      );
      expect(audioElementChannelCount(_channel(id: 1, layout: 'Nonsense')), 0);
    });
  });

  group('profileConflicts — element layouts', () {
    test('Base + 9.1.6 element is a layout conflict', () {
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1, layout: '9.1.6')],
      );
      expect(k, contains(ProfileConflictKind.elementLayoutNotAllowed));
    });

    test('Base-Enhanced + 9.1.6 element has no layout conflict', () {
      final k = _kinds(
        IamfProfile.baseEnhanced,
        elements: [_channel(id: 1, layout: '9.1.6')],
      );
      expect(k, isNot(contains(ProfileConflictKind.elementLayoutNotAllowed)));
    });

    test('Base-Enhanced + 7.1.5.4 element is a layout conflict', () {
      final k = _kinds(
        IamfProfile.baseEnhanced,
        elements: [_channel(id: 1, layout: '7.1.5.4')],
      );
      expect(k, contains(ProfileConflictKind.elementLayoutNotAllowed));
    });

    test('Base-Advanced + 7.1.5.4 element has no layout conflict', () {
      final k = _kinds(
        IamfProfile.baseAdvanced,
        elements: [_channel(id: 1, layout: '7.1.5.4')],
      );
      expect(k, isNot(contains(ProfileConflictKind.elementLayoutNotAllowed)));
    });

    test('Base + Stereo element has no layout conflict', () {
      expect(
        _kinds(IamfProfile.base, elements: [_channel(id: 1)]),
        isNot(contains(ProfileConflictKind.elementLayoutNotAllowed)),
      );
    });
  });

  group('profileConflicts — counts, channels, types', () {
    test('Simple rejects 2 elements', () {
      expect(
        _kinds(
          IamfProfile.simple,
          elements: [_channel(id: 1), _channel(id: 2)],
        ),
        contains(ProfileConflictKind.tooManyElements),
      );
    });

    test('Base rejects 24 channels (two 7.1.4) without a layout conflict', () {
      final k = _kinds(
        IamfProfile.base,
        elements: [
          _channel(id: 1, layout: '7.1.4'),
          _channel(id: 2, layout: '7.1.4'),
        ],
      );
      expect(k, contains(ProfileConflictKind.tooManyChannels));
      expect(k, isNot(contains(ProfileConflictKind.elementLayoutNotAllowed)));
    });

    test('Base-Enhanced rejects object elements', () {
      expect(
        _kinds(IamfProfile.baseEnhanced, elements: [_object(id: 1)]),
        contains(ProfileConflictKind.objectNotAllowed),
      );
    });

    test('Base-Advanced accepts object elements', () {
      expect(
        _kinds(IamfProfile.baseAdvanced, elements: [_object(id: 1)]),
        isNot(contains(ProfileConflictKind.objectNotAllowed)),
      );
    });

    test('Base rejects mixed channel + scene (ES simplified model)', () {
      // Eclipsa Studio models Base as allowMixedTypes:false. The spec's
      // v1.0.0-errata §4.2 actually permits specific two-element channel +
      // scene combinations; ES deliberately simplifies to "one type only"
      // (matching IamfProfile.allowMixedTypes and the export validator).
      expect(
        _kinds(IamfProfile.base, elements: [_channel(id: 1), _scene(id: 2)]),
        contains(ProfileConflictKind.mixedTypesNotAllowed),
      );
    });

    test(
      'Base + two 9.1.6 elements: channel AND layout conflicts together',
      () {
        final conflicts = profileConflicts(
          elements: [
            _channel(id: 1, layout: '9.1.6'),
            _channel(id: 2, layout: '9.1.6'),
          ],
          mixes: const [],
          profile: IamfProfile.base,
        );
        final kinds = conflicts.map((c) => c.kind).toSet();
        expect(
          kinds,
          containsAll(<ProfileConflictKind>[
            ProfileConflictKind.tooManyChannels, // 32 > 18
            ProfileConflictKind.elementLayoutNotAllowed, // 9.1.6 is v1.1.0+
          ]),
        );
        expect(conflicts.length, greaterThanOrEqualTo(2));
      },
    );

    test('Base-Enhanced allows mixed channel + scene', () {
      expect(
        _kinds(
          IamfProfile.baseEnhanced,
          elements: [_channel(id: 1), _scene(id: 2)],
        ),
        isNot(contains(ProfileConflictKind.mixedTypesNotAllowed)),
      );
    });

    test('10.2.9.3 element: layout OK under Base-Advanced but over budget', () {
      // Two-mechanism: layout filter passes, channel budget (24 > 18) fails.
      final ba = _kinds(
        IamfProfile.baseAdvanced,
        elements: [_channel(id: 1, layout: '10.2.9.3')],
      );
      expect(ba, isNot(contains(ProfileConflictKind.elementLayoutNotAllowed)));
      expect(ba, contains(ProfileConflictKind.tooManyChannels));
      // Advanced-2's 28-channel budget fits it.
      expect(
        _kinds(
          IamfProfile.advanced2,
          elements: [_channel(id: 1, layout: '10.2.9.3')],
        ),
        isEmpty,
      );
    });
  });

  group('profileConflicts — sub-mixes & output layouts', () {
    test('Simple rejects 2 sub-mixes', () {
      expect(
        _kinds(
          IamfProfile.simple,
          elements: [_channel(id: 1)],
          mixes: [_mix(subMixCount: 2)],
        ),
        contains(ProfileConflictKind.tooManySubMixes),
      );
    });

    test('Base-Advanced allows 2 sub-mixes', () {
      expect(
        _kinds(
          IamfProfile.baseAdvanced,
          elements: [_channel(id: 1)],
          mixes: [_mix(subMixCount: 2)],
        ),
        isNot(contains(ProfileConflictKind.tooManySubMixes)),
      );
    });

    test('Simple rejects a 9.1.6 output layout', () {
      final k = _kinds(
        IamfProfile.simple,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(
            layouts: const [MixLayout(soundSystem: SoundSystem.surround9_1_6)],
          ),
        ],
      );
      expect(k, contains(ProfileConflictKind.mixLayoutNotAllowed));
    });

    test('Base-Enhanced allows a 9.1.6 output layout', () {
      final k = _kinds(
        IamfProfile.baseEnhanced,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(
            layouts: const [MixLayout(soundSystem: SoundSystem.surround9_1_6)],
          ),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.mixLayoutNotAllowed)));
    });

    test('Base-Enhanced rejects a 7.1.5.4 output layout', () {
      final k = _kinds(
        IamfProfile.baseEnhanced,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(
            layouts: const [
              MixLayout(soundSystem: SoundSystem.surround7_1_5_4),
            ],
          ),
        ],
      );
      expect(k, contains(ProfileConflictKind.mixLayoutNotAllowed));
    });
  });

  group('profileConflicts — rendering config (headphones / binaural)', () {
    MixElementSettings hp(int id, HeadphonesRenderingMode mode) =>
        MixElementSettings(elementId: id, headphonesMode: mode);

    test('Base rejects a head-locked element reference', () {
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(settings: [hp(1, HeadphonesRenderingMode.binauralHeadLocked)]),
        ],
      );
      expect(k, contains(ProfileConflictKind.headphonesModeNotAllowed));
    });

    test('Base-Advanced accepts a head-locked element reference', () {
      final k = _kinds(
        IamfProfile.baseAdvanced,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(settings: [hp(1, HeadphonesRenderingMode.binauralHeadLocked)]),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.headphonesModeNotAllowed)));
    });

    test('Base accepts a world-locked element reference', () {
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(settings: [hp(1, HeadphonesRenderingMode.binauralWorldLocked)]),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.headphonesModeNotAllowed)));
    });

    test('Base rejects a non-default binaural filter profile', () {
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(
            settings: [
              const MixElementSettings(
                elementId: 1,
                binauralProfile: BinauralProfile.direct,
              ),
            ],
          ),
        ],
      );
      expect(k, contains(ProfileConflictKind.binauralFilterNotAllowed));
    });

    test('Base-Advanced accepts a non-default binaural filter profile', () {
      final k = _kinds(
        IamfProfile.baseAdvanced,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(
            settings: [
              const MixElementSettings(
                elementId: 1,
                binauralProfile: BinauralProfile.direct,
              ),
            ],
          ),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.binauralFilterNotAllowed)));
    });

    test('channel-Binaural element reference is excluded (locked, '
        'not resettable)', () {
      // Its rendering config is locked to Stereo in the UI, so a leftover
      // head-locked / binaural-filter value must not raise a dead-end
      // conflict.
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1, layout: 'Binaural')],
        mixes: [
          _mix(
            settings: [
              const MixElementSettings(
                elementId: 1,
                headphonesMode: HeadphonesRenderingMode.binauralHeadLocked,
                binauralProfile: BinauralProfile.direct,
              ),
            ],
          ),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.headphonesModeNotAllowed)));
      expect(k, isNot(contains(ProfileConflictKind.binauralFilterNotAllowed)));
    });

    test('excluded (included:false) reference raises no conflict', () {
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(
            settings: [
              const MixElementSettings(
                elementId: 1,
                included: false,
                headphonesMode: HeadphonesRenderingMode.binauralHeadLocked,
              ),
            ],
          ),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.headphonesModeNotAllowed)));
    });

    test('reference to an element absent from the pool is skipped', () {
      // Element 99 is referenced by the mix but not in the pool — the
      // engine skips it rather than raising a conflict it cannot attribute.
      final k = _kinds(
        IamfProfile.base,
        elements: [_channel(id: 1)],
        mixes: [
          _mix(settings: [hp(99, HeadphonesRenderingMode.binauralHeadLocked)]),
        ],
      );
      expect(k, isNot(contains(ProfileConflictKind.headphonesModeNotAllowed)));
    });
  });

  group('profileFits', () {
    test('a stereo single-element session fits Simple', () {
      expect(
        profileFits(
          elements: [_channel(id: 1)],
          mixes: [
            _mix(settings: [const MixElementSettings(elementId: 1)]),
          ],
          profile: IamfProfile.simple,
        ),
        isTrue,
      );
    });

    test('a 9.1.6 element does not fit Base', () {
      expect(
        profileFits(
          elements: [_channel(id: 1, layout: '9.1.6')],
          mixes: [_mix()],
          profile: IamfProfile.base,
        ),
        isFalse,
      );
    });
  });
}
