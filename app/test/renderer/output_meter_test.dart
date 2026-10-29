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

// The output meter's solo and mute panel (ES-999): hovering a label opens
// it for that channel, it stays open on the way to it and closes after
// OutputMeter.closeDelay, a pass over another label does not move it,
// its buttons toggle the channel and colour the label, and a target
// switch closes it.

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/output_meter.dart';
import 'package:eclipsa_studio/widgets/solo_mute_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_fonts.dart';

void main() {
  setUpAll(loadGoldenFonts);

  late ProviderContainer container;
  late TestGesture mouse;

  Future<void> pumpMeter(
    WidgetTester tester, {
    OarLayout layout = OarLayout.layout714,
    double width = 220,
  }) async {
    container = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    container.read(monitoringConfigProvider.notifier)
      ..addTarget(layout)
      ..setActive(layout);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            // The buttons' tooltips would leave timers pending.
            body: TooltipVisibility(
              visible: false,
              child: Center(
                child: SizedBox(
                  width: width,
                  height: 200,
                  child: const OutputMeter(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
  }

  Finder bars() => find.descendant(
    of: find.byType(MultichannelMeter),
    matching: find.byType(CustomPaint),
  );

  MultichannelMeterPainter painterOf(WidgetTester tester) =>
      tester.widget<CustomPaint>(bars()).painter! as MultichannelMeterPainter;

  // Where [channel]'s label is drawn, in global coordinates.
  Rect labelRect(WidgetTester tester, int channel) {
    final size = tester.getSize(bars());
    final origin = tester.getTopLeft(bars());
    final p = painterOf(tester);
    for (var y = size.height - 60; y < size.height; y += 1) {
      for (var x = 0.0; x < size.width; x += 1) {
        final hit = p.labelAt(Offset(x, y), size);
        if (hit?.channel == channel) return hit!.rect.shift(origin);
      }
    }
    throw StateError('no label for channel $channel');
  }

  OarLayout active() => container.read(monitoringConfigProvider).layout;

  Finder panelTitle(int channel) => find.text(active().speakerLabels[channel]);

  Finder button(String label) => find.widgetWithText(SoloMuteButton, label);

  Future<void> hoverLabel(WidgetTester tester, int channel) async {
    await mouse.moveTo(labelRect(tester, channel).center);
    await tester.pump();
  }

  testWidgets('hovering a label opens the panel for that channel', (
    tester,
  ) async {
    await pumpMeter(tester);
    expect(find.byType(SoloMuteButton), findsNothing);
    await hoverLabel(tester, 5);
    expect(panelTitle(5), findsOneWidget);
    expect(find.byType(SoloMuteButton), findsNWidgets(2));
  });

  testWidgets('S and M toggle the channel and colour its label', (
    tester,
  ) async {
    await pumpMeter(tester);
    await hoverLabel(tester, 5);
    await mouse.moveTo(tester.getCenter(button('M')));
    await tester.pump();

    await tester.tap(button('M'));
    await tester.pump();
    expect(container.read(outputSoloMuteProvider).muted, {5});
    expect(painterOf(tester).labelColors![5], T.meterRed);

    // Mute wins over solo, as in the engine.
    await tester.tap(button('S'));
    await tester.pump();
    expect(container.read(outputSoloMuteProvider).soloed, {5});
    expect(painterOf(tester).labelColors![5], T.meterRed);

    await tester.tap(button('M'));
    await tester.pump();
    expect(container.read(outputSoloMuteProvider).muted, isEmpty);
    expect(painterOf(tester).labelColors![5], T.meterYellow);
    expect(painterOf(tester).labelColors![4], isNull);
  });

  testWidgets('the panel stays open on the way to it and closes after the '
      'close delay', (tester) async {
    await pumpMeter(tester);
    await hoverLabel(tester, 5);
    // Off the label onto the bars, then into the panel within the delay.
    await mouse.moveTo(labelRect(tester, 5).center - const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(tester.getCenter(button('S')));
    await tester.pump(OutputMeter.closeDelay * 2);
    expect(panelTitle(5), findsOneWidget);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(
      OutputMeter.closeDelay - const Duration(milliseconds: 50),
    );
    expect(panelTitle(5), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SoloMuteButton), findsNothing);
  });

  testWidgets('a pass over another label keeps the panel; resting on it '
      'moves the panel there', (tester) async {
    await pumpMeter(tester);
    await hoverLabel(tester, 5);
    // On the way to M the pointer crosses channel 6's label.
    await hoverLabel(tester, 6);
    await tester.pump(OutputMeter.switchDelay ~/ 2);
    await mouse.moveTo(tester.getCenter(button('M')));
    await tester.pump(OutputMeter.switchDelay * 2);
    expect(panelTitle(5), findsOneWidget);
    await tester.tap(button('M'));
    await tester.pump();
    expect(container.read(outputSoloMuteProvider).muted, {5});

    await hoverLabel(tester, 6);
    await tester.pump(
      OutputMeter.switchDelay + const Duration(milliseconds: 10),
    );
    expect(panelTitle(6), findsOneWidget);
    expect(panelTitle(5), findsNothing);
  });

  testWidgets('the panel covers no label at 9.1.6', (tester) async {
    await pumpMeter(tester, layout: OarLayout.layout916, width: 191);
    // Channel 7's label is in the second row, under channel 6's.
    final first = labelRect(tester, 6);
    final second = labelRect(tester, 7);
    expect(second.top, greaterThan(first.top));
    await hoverLabel(tester, 7);
    final panel = tester.getRect(
      find.ancestor(of: panelTitle(7), matching: find.byType(Container)).first,
    );
    expect(panel.bottom, lessThanOrEqualTo(first.top));
  });

  testWidgets('a target switch closes the panel', (tester) async {
    await pumpMeter(tester);
    await hoverLabel(tester, 5);
    expect(find.byType(SoloMuteButton), findsNWidgets(2));
    container
        .read(monitoringConfigProvider.notifier)
        .setActive(OarLayout.stereo);
    await tester.pump();
    expect(find.byType(SoloMuteButton), findsNothing);
  });
}
