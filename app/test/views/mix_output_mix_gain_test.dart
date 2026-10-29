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

import 'package:eclipsa_studio/loudness/programme_loudness.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/views/mix_view.dart';
import 'package:eclipsa_studio/widgets/console_chip.dart';
import 'package:eclipsa_studio/widgets/gain_knob.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/mix_state_engine.dart';

/// The Mix view edits the sub-mix's output mix gain in the LAYOUTS bar,
/// ahead of the layouts, as IAMF stores it (ES-1006). There is no MASTER
/// strip and no output meter: the only meters are the element strips'.
void main() {
  late ProviderContainer container;
  late MixStateEngine engine;

  Future<void> pump(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = MixStateEngine();
    container = ProviderContainer(
      overrides: [
        eclipsaStudioEngineProvider.overrideWithValue(engine),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(elementsProvider.notifier).set([
      AudioElement(
        id: 1,
        name: 'Bed',
        type: 'Channel',
        layout: '5.1',
        codec: 'WAV 16bit',
        color: 0xFF34D399,
      ),
    ]);
    container.read(mixesNotifierProvider.notifier).set(const [
      Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            outputMixGain: -3,
            elementSettings: [MixElementSettings(elementId: 1)],
            layouts: [MixLayout(soundSystem: SoundSystem.stereo)],
          ),
        ],
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: MixView())),
      ),
    );
    await tester.pump();
  }

  // The output mix gain's value field, in the bar that holds its label.
  Finder gainValue(String text) => find.descendant(
    of: find
        .ancestor(of: find.text('OUTPUT MIX GAIN'), matching: find.byType(Row))
        .first,
    matching: find.text(text),
  );

  testWidgets('the gain sits before LAYOUTS and the view has no output '
      'meter', (tester) async {
    await pump(tester);
    expect(find.text('MASTER'), findsNothing);
    expect(gainValue('-3.0 dB'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('OUTPUT MIX GAIN')).dx,
      lessThan(tester.getTopLeft(find.text('LAYOUTS')).dx),
    );
    // One meter, the Bed strip's.
    expect(find.byType(MultichannelMeter), findsOneWidget);
    // The strips start at the left edge of the 1400 px view, not centred.
    expect(tester.getTopLeft(find.byType(MultichannelMeter)).dx, lessThan(100));
  });

  testWidgets('a typed value sets the sub-mix gain and reaches the engine', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(gainValue('-3.0 dB'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '-6');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(
      container.read(mixesNotifierProvider).first.subMixes.first.outputMixGain,
      -6,
    );
    expect(engine.outputMixGain, -6);
    expect(gainValue('-6.0 dB'), findsOneWidget);
  });

  testWidgets('dragging the knob up raises the gain; a double-click sets '
      '0 dB', (tester) async {
    await pump(tester);
    double gain() => container
        .read(mixesNotifierProvider)
        .first
        .subMixes
        .first
        .outputMixGain;

    final knob = find.byType(GainKnob);
    expect(knob, findsOneWidget);
    await tester.drag(knob, const Offset(0, -60));
    await tester.pump();
    expect(gain(), greaterThan(-3));
    expect(engine.outputMixGain, gain());

    await tester.tap(knob);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(knob);
    await tester.pumpAndSettle();
    expect(gain(), 0);
    expect(engine.outputMixGain, 0);
    expect(gainValue('0.0 dB'), findsOneWidget);
  });

  // A gain change marks the last report's figures out of date. They keep
  // their values as a reference and draw in the disabled chip's ink.
  for (final stale in [false, true]) {
    testWidgets('figures from a ${stale ? 'stale' : 'current'} report draw '
        'in the ${stale ? 'disabled' : 'plain'} chip ink', (tester) async {
      await pump(
        tester,
        overrides: [
          programmeLoudnessByLayoutProvider.overrideWithValue((
            byLayout: {
              SoundSystem.stereo: ProgrammeLoudness(
                integratedLufs: -16,
                truePeakDbtp: -1.5,
                layoutLabel: 'Stereo',
                writtenToFile: true,
                stale: stale,
              ),
            },
            stale: stale,
          )),
        ],
      );
      final figures = tester.widget<Text>(find.text('-16.0 LUFS · -1.5 dBTP'));
      expect(
        ConsoleChip.ink(selected: false, enabled: false),
        isNot(ConsoleChip.ink(selected: false)),
      );
      expect(
        figures.style?.color,
        ConsoleChip.ink(selected: false, enabled: !stale),
      );
    });
  }
}
