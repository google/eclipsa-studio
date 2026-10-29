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

// Mix view findings from the 2026-09 review (ES-868): channel strips read
// the meter rows by the element's position in the elements list, which
// is the order the tick loop builds them in; deleting the active mix at
// index 0 puts the engine on the mix that takes its place; and a delete
// confirmed after another session was opened deletes nothing.

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/mix_view.dart';
import 'package:eclipsa_studio/widgets/remove_x_button.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mix_state_engine.dart';

AudioElement _stereo(int id) => AudioElement(
  id: id,
  name: 'e$id',
  type: 'Channel',
  layout: 'Stereo',
  codec: 'WAV 16bit',
  color: 0xFF34D399,
  wavPath: '/media/e$id.wav',
);

void main() {
  late MixStateEngine engine;
  late ProviderContainer container;

  Future<void> pumpMixView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setMode(T.defaultMode));
    engine = MixStateEngine();
    container = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(engine)],
    );
    addTearDown(container.dispose);
    container.read(workspaceModeProvider.notifier).enterCreator();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: MixView())),
      ),
    );
  }

  /// Two elements in the session and in the engine, and two mixes:
  /// 'One' includes element 1 at -3 dB, 'Two' excludes it and sets
  /// it to -9 dB in Stereo mode (0) with the Direct profile (1).
  Future<void> seedTwoMixes(WidgetTester tester) async {
    container.read(elementsProvider.notifier).set([_stereo(1), _stereo(2)]);
    container.read(mixesNotifierProvider.notifier).set(const [
      Mix(
        id: 1,
        name: 'One',
        subMixes: [
          SubMix(
            outputMixGain: -1,
            elementSettings: [
              MixElementSettings(elementId: 1, mixGain: -3),
              MixElementSettings(elementId: 2),
            ],
          ),
        ],
      ),
      Mix(
        id: 2,
        name: 'Two',
        subMixes: [
          SubMix(
            outputMixGain: -2,
            elementSettings: [
              MixElementSettings(
                elementId: 1,
                included: false,
                mixGain: -9,
                headphonesMode: HeadphonesRenderingMode.stereo,
                binauralProfile: BinauralProfile.direct,
              ),
              MixElementSettings(elementId: 2),
            ],
          ),
        ],
      ),
    ]);
    for (final id in [1, 2]) {
      engine.addElement(id, '/media/e$id.wav');
      engine.setElementType(id, 0, 0, 2);
    }
    pushSubMixSettings(
      engine,
      container.read(mixesNotifierProvider).first.subMixes.first,
      container.read(elementsProvider),
    );
    await tester.pump();
  }

  /// Taps the ✕ on the active tab, named [name].
  Future<void> tapDeleteOnTab(WidgetTester tester, String name) async {
    final tab = find.ancestor(
      of: find.text(name).first,
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(of: tab.first, matching: find.byType(RemoveXButton)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete Mix?'), findsOneWidget);
  }

  testWidgets('a strip reads its meter row by element position', (
    tester,
  ) async {
    await pumpMixView(tester);
    container.read(elementsProvider.notifier).set([_stereo(1), _stereo(2)]);
    // Slot order differs from list order, as after a reorder or a
    // delete compacted the engine's slots.
    container.read(engineOrderProvider.notifier).set([2, 1]);
    container
        .read(animatedMetricsProvider.notifier)
        .set(
          AnimatedMetrics.initial().copyWithSidebar(const [
            [0.1, 0.1],
            [0.9, 0.9],
          ]),
        );
    await tester.pump();

    final meters = tester
        .widgetList<MultichannelMeter>(find.byType(MultichannelMeter))
        .map((m) => m.levels)
        .toList();
    expect(meters, [
      [0.1, 0.1],
      [0.9, 0.9],
    ]);
  });

  testWidgets('deleting the active mix at index 0 pushes the mix that '
      'takes its place', (tester) async {
    await pumpMixView(tester);
    await seedTwoMixes(tester);
    expect(engine.excluded[1], isFalse);
    expect(engine.mixGain[1], -3);

    await tapDeleteOnTab(tester, 'One');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(container.read(mixesNotifierProvider).map((m) => m.name), ['Two']);
    expect(container.read(activeMixProvider), 0);
    expect(engine.excluded[1], isTrue);
    expect(engine.mixGain[1], -9);
    expect(engine.rendering[1], (0, 1));
    expect(engine.outputMixGain, -2);
  });

  testWidgets('a delete confirmed after a session switch deletes nothing', (
    tester,
  ) async {
    await pumpMixView(tester);
    await seedTwoMixes(tester);
    await tapDeleteOnTab(tester, 'One');

    // File > Open Recent from the native menu while the dialog is up:
    // the other session has mixes with the same ids.
    container.read(sessionProvider.notifier).newSession();
    container.read(mixesNotifierProvider.notifier).set(const [
      Mix(id: 1, name: 'Other One'),
      Mix(id: 2, name: 'Other Two'),
    ]);
    await tester.pump();

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Mix?'), findsNothing);
    expect(container.read(mixesNotifierProvider).map((m) => m.name), [
      'Other One',
      'Other Two',
    ]);
  });
}

extension on AnimatedMetrics {
  /// These metrics with [rows] as the per-element meter rows.
  AnimatedMetrics copyWithSidebar(List<List<double>> rows) => AnimatedMetrics(
    meters: meters,
    sidebarMeters: rows,
    lufsIntegrated: lufsIntegrated,
    truePeak: truePeak,
    lufsMomentary: lufsMomentary,
    lufsShortTerm: lufsShortTerm,
    limiterGr: limiterGr,
    engineCpu: engineCpu,
    fps: fps,
  );
}
