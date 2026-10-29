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

// Elements view findings from the 2026-09 review (ES-868): a WAV assigned
// to an element, swapped in place or replaced by another channel count,
// and an element re-typed, leave the engine on the active mix's
// exclusion, mix gain and rendering config; a replacement must fit the
// profile and takes the old element's mix settings away; an import
// whose session changed during its file read writes nothing; and the
// past-end scrim follows a theme switch.

import 'dart:convert';

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mix_state_engine.dart';

String _probeJson(int channels) => jsonEncode({
  'ok': true,
  'container': 'riff',
  'channels': channels,
  'sample_rate': 48000,
  'bits_per_sample': 16,
  'is_float': false,
  'num_frames': 48000,
  'data_offset': 44,
  'data_size': 48000 * channels * 2,
  'axml_bytes': 0,
  'chna_bytes': 0,
});

WavInfo _info(int channels, {int seconds = 1}) => WavInfo(
  channels: channels,
  sampleRate: 48000,
  bitsPerSample: 16,
  audioFormat: 1,
  dataOffset: 44,
  dataSize: 48000 * seconds * channels * 2,
  totalSamples: 48000 * seconds,
);

AudioElement _stereo(int id, {bool loaded = true}) => AudioElement(
  id: id,
  name: 'e$id',
  type: 'Channel',
  layout: 'Stereo',
  codec: 'WAV 16bit',
  color: 0xFF34D399,
  wavPath: loaded ? '/media/e$id.wav' : null,
  wavInfo: loaded ? _info(2) : null,
  inputRouting: const [1, 0],
);

/// Element 1's settings in the active mix: excluded, -6 dB, Stereo
/// headphones mode (0), Direct binaural profile (1).
const _stored = MixElementSettings(
  elementId: 1,
  included: false,
  mixGain: -6,
  headphonesMode: HeadphonesRenderingMode.stereo,
  binauralProfile: BinauralProfile.direct,
);

void main() {
  // Provider teardown reaches platform channels (video pop-out close).
  TestWidgetsFlutterBinding.ensureInitialized();

  late MixStateEngine engine;
  late ProviderContainer container;

  setUp(() {
    engine = MixStateEngine();
    container = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(engine)],
    );
    container.read(workspaceModeProvider.notifier).enterCreator();
    WavDecoder.probeForTesting = (path) =>
        _probeJson(path.contains('6ch') ? 6 : (path.contains('25ch') ? 25 : 2));
  });

  tearDown(() {
    WavDecoder.probeForTesting = null;
    container.dispose();
  });

  /// Puts [elements] in the session and in the engine, as a session
  /// load does, with [settings] in the active mix.
  void seed(List<AudioElement> elements, List<MixElementSettings> settings) {
    container.read(elementsProvider.notifier).set(elements);
    container.read(mixesNotifierProvider.notifier).set([
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [SubMix(elementSettings: settings)],
      ),
    ]);
    for (final e in elements.where((e) => e.wavPath != null)) {
      engine.addElement(e.id, e.wavPath!);
      engine.setElementType(e.id, 0, 0, 2);
    }
    final sub = container.read(mixesNotifierProvider).first.subMixes.first;
    pushSubMixSettings(engine, sub, elements);
    container.read(engineOrderProvider.notifier).set([
      for (final e in elements)
        if (e.wavPath != null) e.id,
    ]);
  }

  /// Expects the engine to hold [_stored] for element 1.
  void expectStoredSettingsInEngine() {
    expect(engine.excluded[1], isTrue, reason: 'mix exclusion');
    expect(engine.mixGain[1], -6, reason: 'mix gain');
    expect(engine.rendering[1], (0, 1), reason: 'rendering config');
  }

  group('the engine keeps the active mix settings', () {
    test('a same-channel-count WAV swap', () async {
      seed([_stereo(1)], [_stored]);
      expectStoredSettingsInEngine();

      expect(await assignWavToElement(container, 1, '/media/b.wav'), isNull);
      expect(engine.removed, [1], reason: 'the swap re-adds the element');
      expectStoredSettingsInEngine();
      expect(engine.routing[1], [1, 0], reason: 'input routing');
      expect(container.read(engineOrderProvider), [1]);
    });

    test('a WAV assigned to an element without one', () async {
      seed([_stereo(1, loaded: false)], [_stored]);

      expect(await assignWavToElement(container, 1, '/media/b.wav'), isNull);
      expectStoredSettingsInEngine();
      expect(container.read(engineOrderProvider), [1]);
    });

    testWidgets('a re-typed element', (tester) async {
      seed([_stereo(1)], [_stored]);
      late WidgetRef ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      );

      final el = container.read(elementsProvider).single;
      updateElementById(ref, el.copyWith(layout: '5.1'));
      expectStoredSettingsInEngine();
    });
  });

  group('a different-channel-count replacement', () {
    test("takes the old element's settings out of every mix", () async {
      container
          .read(iamfProfileProvider.notifier)
          .set(IamfProfile.baseEnhanced);
      seed(
        [_stereo(1), _stereo(2)],
        const [
          MixElementSettings(elementId: 1),
          MixElementSettings(elementId: 2, mixGain: -3),
        ],
      );

      expect(await assignWavToElement(container, 2, '/media/6ch.wav'), isNull);
      final elements = container.read(elementsProvider);
      expect(elements.map((e) => e.id), [1, 3]);
      final settings = container
          .read(mixesNotifierProvider)
          .single
          .subMixes
          .single
          .elementSettings;
      expect(settings.map((s) => s.elementId), [1, 3]);
    });

    test('must fit the profile beside the other elements', () async {
      // Simple: 16 channels. A 25-channel WAV opens as a 4OA scene.
      container.read(iamfProfileProvider.notifier).set(IamfProfile.simple);
      seed([_stereo(1)], const [MixElementSettings(elementId: 1)]);

      final err = await assignWavToElement(container, 1, '/media/25ch.wav');
      expect(err, contains('16 total channels'));
      expect(container.read(elementsProvider).single.wavPath, '/media/e1.wav');
      expect(engine.removed, isEmpty);
      expect(container.read(engineOrderProvider), [1]);
    });

    test('must not mix types where the profile forbids it', () async {
      // Base: two elements, one type. A 4-channel WAV opens as a 1OA
      // scene beside a channel bed.
      container.read(iamfProfileProvider.notifier).set(IamfProfile.base);
      seed(
        [_stereo(1), _stereo(2)],
        const [
          MixElementSettings(elementId: 1),
          MixElementSettings(elementId: 2),
        ],
      );
      WavDecoder.probeForTesting = (_) => _probeJson(4);

      final err = await assignWavToElement(container, 2, '/media/4ch.wav');
      expect(err, contains('does not allow mixing element types'));
      expect(container.read(elementsProvider).map((e) => e.id), [1, 2]);
      expect(engine.removed, isEmpty);
    });
  });

  group('an import across a session switch writes nothing', () {
    test('a WAV replace', () async {
      seed([_stereo(1)], const [MixElementSettings(elementId: 1)]);
      // The other session is opened while the dropped file is read, and
      // it has an element with the same id.
      WavDecoder.probeForTesting = (_) {
        container.read(sessionProvider.notifier).newSession();
        container.read(elementsProvider.notifier).set([
          _stereo(1).copyWith(wavPath: '/other/e1.wav'),
        ]);
        return _probeJson(2);
      };

      final err = await assignWavToElement(container, 1, '/media/b.wav');
      expect(err, contains('the session changed'));
      expect(container.read(elementsProvider).single.wavPath, '/other/e1.wav');
    });

    test('a new element', () async {
      WavDecoder.probeForTesting = (_) {
        container.read(sessionProvider.notifier).newSession();
        return _probeJson(2);
      };

      final err = await addNewElementFromWav(container, '/media/b.wav');
      expect(err, contains('the session changed'));
      expect(container.read(elementsProvider), isEmpty);
    });
  });

  testWidgets('the past-end scrim follows a theme switch', (tester) async {
    addTearDown(() => T.setMode(T.defaultMode));
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(workspaceModeProvider.notifier).enterCreator();
    c.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    // A 10 s element sets the timeline length; the 5 s one ends halfway
    // and draws the scrim past its end.
    c.read(elementsProvider.notifier).set([
      _stereo(1).copyWith(wavInfo: _info(2, seconds: 10)),
      _stereo(2).copyWith(wavInfo: _info(2, seconds: 5)),
    ]);
    c.read(transportProvider.notifier).updateDuration(48000 * 10, 48000);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: ElementsView())),
      ),
    );
    await tester.pump();

    Finder scrim(Color color) =>
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == color);
    final dark = T.pastEndScrim;
    expect(scrim(dark), findsOneWidget);

    c.read(themeModeProvider.notifier).set(AppThemeMode.light);
    await tester.pump();
    final light = T.pastEndScrim;
    expect(light, isNot(dark));
    expect(scrim(light), findsOneWidget);
    expect(scrim(dark), findsNothing);
  });
}
