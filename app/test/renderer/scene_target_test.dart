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

// The Renderer scene draws the monitoring target and the sources apart
// (ES-595, ES-336). The target is its loudspeakers, or headphones on the
// binaural target, lit by the output meters. Each channel of a
// channel-based element is a source where that target's render takes it
// from: the layout's loudspeaker position on a loudspeaker target, OBR's
// virtual loudspeaker on the binaural target, or inside the head halfway
// to each earcup when OAR plays the element on the headphones as plain
// stereo.

import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/renderer/coordinate_utils.dart';
import 'package:eclipsa_studio/renderer/renderable_scene.dart';
import 'package:eclipsa_studio/renderer/scene_bridge.dart';
import 'package:eclipsa_studio/renderer/scene_target.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

AudioElement _element(int id, String layout, {String type = 'Channel'}) =>
    AudioElement(
      id: id,
      name: 'E$id',
      type: type,
      layout: layout,
      codec: 'LPCM',
      color: 0xFF336699,
    );

Vector3 _at(double azDeg, double elDeg, [double distance = 1.0]) =>
    CoordinateUtils.sphericalToVisualizer(azDeg, elDeg, distance);

void _expectAt(Vector3 got, double azDeg, double elDeg, [double d = 1.0]) {
  expect(
    got.distanceTo(_at(azDeg, elDeg, d)),
    lessThan(1e-9),
    reason: 'at ($azDeg, $elDeg, $d)',
  );
}

void main() {
  group('SceneBridge', () {
    test('a loudspeaker target draws its loudspeakers, lit by the outputs', () {
      final scene = SceneBridge.build(
        elements: const [],
        outputLayout: SpeakerLayout.layout51,
        outputLevels: const [0.5, 0, 0, 0, 0, 0],
      );
      expect(scene.headphones, isNull);
      expect(scene.speakers.map((s) => s.label), [
        'L',
        'R',
        'C',
        'LFE',
        'Ls',
        'Rs',
      ]);
      _expectAt(scene.speakers[4].position, 110, 0, 1.1);
      expect(scene.speakers[0].level, 0.5);
      expect(scene.speakers[0].color, isNot(scene.speakers[1].color));
      expect(scene.speakers[1].color, T.textTertiary);
    });

    test('channel sources sit on the unit sphere, inside the outputs', () {
      final scene = SceneBridge.build(
        elements: [_element(1, '7.1.4')],
        outputLayout: SpeakerLayout.stereo,
        levels: const [
          [0.4],
        ],
      );
      // The target is stereo whatever the element's layout, its
      // cabinets just outside the unit sphere.
      expect(scene.speakers, hasLength(2));
      _expectAt(scene.speakers[0].position, 30, 0, 1.1);
      expect(scene.sources, hasLength(12));
      _expectAt(scene.sources[8].position, 45, 30); // Ltf
      _expectAt(scene.sources[3].position, 45, -30); // LFE
      expect(scene.sources[0].level, 0.4);
      expect(scene.sources[0].radius, greaterThan(scene.sources[1].radius));
    });

    test('the binaural target draws headphones and OBR\'s positions', () {
      final scene = SceneBridge.build(
        elements: [_element(1, '5.1.4')],
        outputLayout: SpeakerLayout.stereo,
        isBinauralTarget: true,
        outputLevels: const [0.3, 0.6],
      );
      expect(scene.speakers, isEmpty);
      expect(scene.headphones!.leftLevel, 0.3);
      expect(scene.headphones!.rightLevel, 0.6);
      expect(scene.sources, hasLength(10));
      _expectAt(scene.sources[3].position, 0, -30); // LFE
      _expectAt(scene.sources[6].position, 45, 45); // Ltf
      _expectAt(scene.sources[8].position, 135, 45); // Ltr
    });

    test('stereo on the headphones puts a pair inside the head', () {
      final scene = SceneBridge.build(
        elements: [_element(1, 'Binaural'), _element(2, '7.1.4')],
        isBinauralTarget: true,
        stereoOnHeadphones: const {1},
        levels: const [
          [0.5, 0.2],
          [],
        ],
      );
      // The Binaural element's pair, then the binauralised 7.1.4 bed's
      // twelve.
      expect(scene.sources, hasLength(14));
      final (left, right) = (scene.sources[0], scene.sources[1]);
      // On the ear axis halfway to each earcup; audio left is
      // visualizer -X.
      const half = RenderableHeadphones.headRadius / 2;
      expect(left.position.x, closeTo(-half, 1e-6));
      expect((left.position.y, left.position.z), (0.0, 0.0));
      expect(right.position.x, closeTo(half, 1e-6));
      expect(left.level, 0.5);
      expect(right.level, 0.2);
    });

    test('every element on the headphones shares the pair\'s place', () {
      final scene = SceneBridge.build(
        elements: [_element(1, 'Binaural'), _element(2, '5.1')],
        isBinauralTarget: true,
        stereoOnHeadphones: const {1, 2},
        levels: const [
          [1, 1],
          [1, 1, 1, 0, 1, 1],
        ],
      );
      final sources = scene.sources;
      expect(sources, hasLength(4));
      expect(sources[2].position, sources[0].position);
      expect(sources[3].position, sources[1].position);
      for (final s in sources) {
        // At full level, still inside the head.
        expect(
          s.position.length + s.radius,
          lessThanOrEqualTo(RenderableHeadphones.headRadius),
        );
      }
      // The left and right sources do not touch.
      expect(
        sources[0].position.distanceTo(sources[1].position),
        greaterThan(sources[0].radius + sources[1].radius),
      );
    });

    test('a source in the head takes the loudest channel on its side', () {
      // 5.1: L R C LFE Ls Rs. C counts for both sides; the LFE for none.
      final scene = SceneBridge.build(
        elements: [_element(1, '5.1')],
        isBinauralTarget: true,
        stereoOnHeadphones: const {1},
        levels: const [
          [0.1, 0.2, 0.3, 0.9, 0.4, 0.05],
        ],
      );
      expect(scene.sources.map((s) => s.level), [0.4, 0.3]);
    });

    test('stereoOnHeadphones is ignored on a loudspeaker target', () {
      final scene = SceneBridge.build(
        elements: [_element(1, 'Binaural')],
        outputLayout: SpeakerLayout.stereo,
        stereoOnHeadphones: const {1},
      );
      expect(scene.headphones, isNull);
      expect(scene.sources, hasLength(2));
      _expectAt(scene.sources[0].position, 30, 0);
    });

    test('a silenced element\'s sources and objects fade', () {
      final elements = [
        _element(1, 'Stereo'),
        _element(2, 'Object', type: 'Object'),
      ];
      final audible = SceneBridge.build(
        elements: elements,
        levels: const [
          [0.8, 0.8],
          [0.8],
        ],
      );
      final silenced = SceneBridge.build(
        elements: elements,
        silenced: const {1, 2},
        levels: const [
          [0.8, 0.8],
          [0.8],
        ],
      );
      final faded = Color.lerp(aeTypeColor('Channel'), T.bgDeep, 0.7)!;
      expect(silenced.sources[0].color, isNot(audible.sources[0].color));
      expect(silenced.sources[0].radius, lessThan(audible.sources[0].radius));
      // At its silent size and level at once, ahead of the meters.
      expect(silenced.sources[0].radius, 0.03);
      expect(silenced.sources[0].level, 0);
      // A silent channel shows the element type's colour, so it fades to
      // exactly the faded type colour.
      expect(
        SceneBridge.build(
          elements: [elements[0]],
          silenced: const {1},
        ).sources[0].color,
        faded,
      );
      expect(
        silenced.objects.single.color,
        isNot(audible.objects.single.color),
      );
      // Positions do not move.
      expect(silenced.sources[0].position, audible.sources[0].position);
    });

    test('objects keep their positions on the binaural target', () {
      final object = _element(1, 'Object', type: 'Object');
      final loudspeaker = SceneBridge.build(elements: [object]);
      final binaural = SceneBridge.build(
        elements: [object],
        isBinauralTarget: true,
        stereoOnHeadphones: const {1},
      );
      expect(binaural.sources, isEmpty);
      expect(binaural.objects, hasLength(1));
      expect(
        binaural.objects.single.position,
        loudspeaker.objects.single.position,
      );
    });
  });

  group('creatorStereoOnHeadphones', () {
    final elements = [
      _element(1, 'Binaural'),
      _element(2, '7.1.4'),
      _element(3, '5.1'),
      _element(4, 'Object', type: 'Object'),
    ];

    test('takes the mode the app pushes for the active sub-mix', () {
      const sub = SubMix(
        elementSettings: [
          // A Binaural element is pushed as Stereo whatever is stored.
          MixElementSettings(
            elementId: 1,
            headphonesMode: HeadphonesRenderingMode.binauralWorldLocked,
          ),
          MixElementSettings(
            elementId: 2,
            headphonesMode: HeadphonesRenderingMode.stereo,
          ),
          MixElementSettings(
            elementId: 4,
            headphonesMode: HeadphonesRenderingMode.stereo,
          ),
        ],
      );
      // Element 3 has the default, world-locked; element 4 is an
      // object, which OAR always binauralises.
      expect(creatorStereoOnHeadphones(sub, elements), {1, 2});
    });

    test('is empty without a sub-mix', () {
      expect(creatorStereoOnHeadphones(null, elements), isEmpty);
    });
  });

  group('silencedByMuteSolo', () {
    AudioElement el(int id, {bool mute = false, bool solo = false}) =>
        _element(id, 'Stereo').copyWith(mute: mute, solo: solo);

    test('silences the muted elements without a solo', () {
      expect(silencedByMuteSolo([el(1, mute: true), el(2)]), {1});
    });

    test('a solo silences every element that is not soloed', () {
      expect(silencedByMuteSolo([el(1, solo: true), el(2), el(3)]), {2, 3});
    });

    test('mute wins over solo', () {
      expect(silencedByMuteSolo([el(1, solo: true, mute: true), el(2)]), {
        1,
        2,
      });
    });
  });

  group('playbackStereoOnHeadphones', () {
    IamfMixPresentation mix(List<IamfMixElementGain> elements) =>
        IamfMixPresentation(
          id: 1,
          name: 'Test',
          language: 'en',
          loudnessLufs: null,
          truePeakDbtp: null,
          elements: elements,
          layoutType: null,
          soundSystem: null,
          subMixes: [IamfSubMixInfo(elements: elements, outputMixGainDb: 0)],
        );

    test('takes the file\'s mode as the engine pushes it', () {
      final elements = [
        _element(1, 'Binaural'),
        _element(2, '5.1'),
        _element(3, 'Stereo'),
      ];
      final presentation = mix(const [
        // A Binaural element the file marks world-locked is binauralised.
        IamfMixElementGain(
          audioElementId: 1,
          defaultGainDb: 0,
          headphonesRenderingMode: 'binaural_world_locked',
        ),
        IamfMixElementGain(
          audioElementId: 2,
          defaultGainDb: 0,
          headphonesRenderingMode: 'stereo',
        ),
        // No rendering config: the engine keeps world-locked.
        IamfMixElementGain(audioElementId: 3, defaultGainDb: 0),
      ]);
      expect(playbackStereoOnHeadphones(presentation, elements), {2});
      expect(playbackStereoOnHeadphones(null, elements), isEmpty);
    });
  });

  test('object elements never share a mesh id', () {
    // Element 1 is a dual object (two spheres), element 2 a single one.
    final scene = SceneBridge.build(
      elements: [
        _element(1, 'Stereo', type: 'Object').copyWith(isDual: true),
        _element(2, 'Mono', type: 'Object'),
      ],
      outputLayout: SpeakerLayout.stereo,
    );
    final ids = [for (final o in scene.objects) o.id];
    expect(ids, hasLength(3));
    expect(ids.toSet(), hasLength(3));
  });
}
