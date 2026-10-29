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
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:eclipsa_studio/widgets/drop_zone.dart';
import 'package:eclipsa_studio/widgets/track_lanes.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An Elements row draws its drag handle, its lane and its waveform in
/// the colour of its type in the active theme, and not in the colour
/// the session stored for the element.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  // A stored colour that no theme uses for a type.
  const stored = Color(0xFFFF00FF);

  // Type, layout and channel count of each case.
  const formats = [
    ('Object', 'Mono', 1),
    ('Channel', 'Stereo', 2),
    ('Scene', '1OA', 4),
  ];

  AudioElement element(
    String type,
    String layout,
    int channels, {
    bool wav = false,
  }) => AudioElement(
    id: 1,
    name: 'element',
    type: type,
    layout: layout,
    codec: 'LPCM',
    color: stored.toARGB32(),
    wavPath: wav ? '/media/element.wav' : null,
    wavInfo: wav
        ? WavInfo(
            channels: channels,
            sampleRate: 48000,
            bitsPerSample: 16,
            audioFormat: 1,
            dataOffset: 44,
            dataSize: 48000 * 10 * channels * 2,
            totalSamples: 48000 * 10,
          )
        : null,
  );

  Future<ProviderContainer> pumpRow(WidgetTester tester, AudioElement e) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ElementsView())),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ElementsView)),
    );
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(elementsProvider.notifier).set([e]);
    if (e.wavInfo != null) {
      container
          .read(transportProvider.notifier)
          .updateDuration(e.wavInfo!.totalSamples, 48000);
    }
    await tester.pump();
    return container;
  }

  Color handle(WidgetTester tester) =>
      tester.widget<Text>(find.text('☰')).style!.color!;

  // The lane of an element with no WAV file is a compact drop zone.
  Color emptyLane(WidgetTester tester) => tester
      .widget<DropZone>(
        find.byWidgetPredicate(
          (w) => w is DropZone && w.variant == DropZoneVariant.compact,
        ),
      )
      .accentColor!;

  // The file details chip takes the lane block's cached colour.
  Color fileDetails(WidgetTester tester) =>
      tester.widget<TrackInfoChip>(find.byType(TrackInfoChip)).color;

  Color waveform(WidgetTester tester) => tester
      .widget<MultiChannelWaveform>(find.byType(MultiChannelWaveform))
      .style
      .waveColor;

  for (final mode in AppThemeMode.values) {
    for (final (type, layout, channels) in formats) {
      testWidgets('${mode.name}: a $type row draws its handle and empty '
          'lane in the $type colour', (tester) async {
        T.setMode(mode);
        expect(aeTypeColor(type), isNot(stored));
        await pumpRow(tester, element(type, layout, channels));
        expect(handle(tester), aeTypeColor(type));
        expect(emptyLane(tester), aeTypeColor(type));
      });

      testWidgets('${mode.name}: a $type row with a WAV file draws its '
          'lane and waveform in the $type colour', (tester) async {
        T.setMode(mode);
        await pumpRow(tester, element(type, layout, channels, wav: true));
        expect(handle(tester), aeTypeColor(type));
        expect(fileDetails(tester), aeTypeColor(type));
        expect(waveform(tester), aeTypeColor(type));
      });
    }
  }

  testWidgets('the handle and empty lane follow a theme switch', (
    tester,
  ) async {
    final container = await pumpRow(tester, element('Channel', 'Stereo', 2));
    container.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pump();
    final dark = aeTypeColor('Channel');
    expect(handle(tester), dark);

    container.read(themeModeProvider.notifier).set(AppThemeMode.light);
    await tester.pump();
    final light = aeTypeColor('Channel');
    expect(light, isNot(dark));
    expect(handle(tester), light);
    expect(emptyLane(tester), light);
  });

  testWidgets('the lane and waveform of a row with a WAV file follow a '
      'theme switch', (tester) async {
    final container = await pumpRow(
      tester,
      element('Channel', 'Stereo', 2, wav: true),
    );
    container.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pump();
    final dark = aeTypeColor('Channel');
    expect(fileDetails(tester), dark);

    container.read(themeModeProvider.notifier).set(AppThemeMode.light);
    await tester.pump();
    final light = aeTypeColor('Channel');
    expect(light, isNot(dark));
    expect(fileDetails(tester), light);
    expect(waveform(tester), light);
  });

  // The session loader keeps a type it does not recognise.
  testWidgets('a type the loader does not recognise is drawn in one colour', (
    tester,
  ) async {
    await pumpRow(tester, element('Ambisonics', 'Stereo', 2, wav: true));
    final color = handle(tester);
    expect(fileDetails(tester), color);
    expect(waveform(tester), color);
  });
}
