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

// Output-channel solo and mute in the Monitoring panel (ES-999): the rule,
// the push to the engine, its reset on a target switch, the 3D scene's
// fade of a silenced output, the output meter's label hit test, hover
// report and label colours that the S/M panel uses, and the status bar
// item that shows them from every view.

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/renderer/scene_bridge.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/statusbar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_fonts.dart';

/// Records the output solo and mute pushes; any other engine call fails
/// the test.
class _RecordingEngine extends Fake implements EclipsaStudioEngine {
  /// The soloed and the muted channels of each push, in push order.
  final soloed = <Set<int>>[];
  final muted = <Set<int>>[];

  @override
  void setOutputSoloMute(Set<int> soloed, Set<int> muted) {
    this.soloed.add({...soloed});
    this.muted.add({...muted});
  }
}

void main() {
  group('OutputSoloMute.silenced', () {
    test('silences the muted channels without a solo', () {
      expect(const OutputSoloMute(muted: {1}).silenced(6), {1});
    });

    test('a solo silences every channel that is not soloed', () {
      expect(const OutputSoloMute(soloed: {0, 2}).silenced(4), {1, 3});
    });

    test('mute wins over solo', () {
      expect(const OutputSoloMute(soloed: {0}, muted: {0}).silenced(2), {0, 1});
    });
  });

  group('OutputSoloMuteNotifier', () {
    ProviderContainer container(EclipsaStudioEngine? engine) {
      final c = ProviderContainer(
        overrides: [eclipsaStudioEngineProvider.overrideWithValue(engine)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('toggles solo and mute and pushes each change', () {
      final engine = _RecordingEngine();
      final c = container(engine);
      final notifier = c.read(outputSoloMuteProvider.notifier);
      notifier.toggleSolo(0);
      notifier.toggleMute(1);
      expect(c.read(outputSoloMuteProvider).soloed, {0});
      expect(c.read(outputSoloMuteProvider).muted, {1});
      notifier.toggleSolo(0);
      expect(c.read(outputSoloMuteProvider).soloed, isEmpty);
      expect(engine.soloed, [
        {0},
        {0},
        <int>{},
      ]);
      expect(engine.muted, [
        <int>{},
        {1},
        {1},
      ]);
    });

    test('a target switch clears it in the panel and the engine', () {
      final engine = _RecordingEngine();
      final c = container(engine);
      final notifier = c.read(outputSoloMuteProvider.notifier);
      notifier.toggleSolo(2);
      notifier.toggleMute(0);
      c.read(monitoringConfigProvider.notifier).setActive(OarLayout.binaural);
      final state = c.read(outputSoloMuteProvider);
      expect(state.soloed, isEmpty);
      expect(state.muted, isEmpty);
      expect(engine.soloed.last, isEmpty);
      expect(engine.muted.last, isEmpty);
    });

    test('works without an engine', () {
      final c = container(null);
      c.read(outputSoloMuteProvider.notifier).toggleMute(3);
      expect(c.read(outputSoloMuteProvider).muted, {3});
    });
  });

  test('EclipsaStudioEngine.channelMask sets bit c for channel c', () {
    expect(EclipsaStudioEngine.channelMask(const {}), 0);
    expect(EclipsaStudioEngine.channelMask(const {0, 3}), 0x9);
    // Bit 63 is the sign bit of a Dart int; FFI passes it as uint64.
    expect(EclipsaStudioEngine.channelMask(const {63}), 1 << 63);
    expect(EclipsaStudioEngine.channelMask(const {-1, 64}), 0);
  });

  group('the scene fades a silenced output', () {
    final faded = Color.lerp(T.textTertiary, T.bgDeep, 0.7)!;

    test('loudspeaker', () {
      final scene = SceneBridge.build(
        elements: const [],
        outputLayout: SpeakerLayout.stereo,
        silencedOutputs: const {1},
      );
      expect(scene.speakers[0].color, T.textTertiary);
      expect(scene.speakers[1].color, faded);
    });

    test('earcup', () {
      final scene = SceneBridge.build(
        elements: const [],
        isBinauralTarget: true,
        silencedOutputs: const {0},
      );
      expect(scene.headphones!.leftColor, faded);
      expect(scene.headphones!.rightColor, T.textTertiary);
    });
  });

  group('MultichannelMeterPainter.labelAt', () {
    // The real fonts: with the test font every label is one width, and
    // 9.1.6 lays out as one rotated row instead of the two staggered
    // rows the app draws at Medium and Large.
    setUpAll(loadGoldenFonts);
    tearDown(() => T.setFontMode(FontSizeMode.medium));

    MultichannelMeterPainter painter(
      List<String> labels, {
      List<double>? levels,
      List<Color?>? colors,
    }) => MultichannelMeterPainter(
      levels: levels ?? List.filled(labels.length, 0.0),
      labels: labels,
      labelColors: colors,
      fontMode: T.fontMode,
      themeMode: T.mode,
    );

    // The label of each channel found sweeping the bottom 60 px of a
    // meter of [size] row by row, left to right.
    Map<int, MeterLabelHit> sweep(MultichannelMeterPainter p, Size size) {
      final hits = <int, MeterLabelHit>{};
      for (var y = size.height - 60; y < size.height; y += 1) {
        for (var x = 0.0; x < size.width; x += 1) {
          final hit = p.labelAt(Offset(x, y), size);
          if (hit != null) hits.putIfAbsent(hit.channel, () => hit);
        }
      }
      return hits;
    }

    for (final (layout, width) in [
      (OarLayout.layout714, 220.0),
      (OarLayout.layout916, 191.0),
    ]) {
      for (final font in FontSizeMode.values) {
        test('${layout.label} at ${font.name}: each label hits its '
            'own channel, under the bars', () {
          T.setFontMode(font);
          final size = Size(width, 200);
          final p = painter(layout.meterLabels);
          final hits = sweep(p, size);
          expect(
            hits.keys.toList()..sort(),
            List.generate(layout.channels, (i) => i),
          );
          for (final MapEntry(key: c, value: hit) in hits.entries) {
            expect(p.labelAt(hit.rect.center, size)?.channel, c);
            expect(hit.rect.top, greaterThanOrEqualTo(hit.stripTop));
          }
        });
      }
    }

    test('two staggered rows never hit the same point', () {
      const size = Size(191, 200);
      final p = painter(OarLayout.layout916.meterLabels);
      final hits = sweep(p, size);
      // Straight up from just inside a second-row label stays on it
      // until it leaves the row, and the first row's label above is
      // found only above that.
      final second = hits[7]!.rect;
      expect(second.top, greaterThan(hits[6]!.rect.top), reason: 'staggered');
      final x = second.left + 1;
      for (var y = second.bottom; y >= second.top; y -= 0.5) {
        expect(p.labelAt(Offset(x, y), size)?.channel, 7, reason: 'y=$y');
      }
    });

    test('the bars are not a label', () {
      const size = Size(220, 200);
      final p = painter(OarLayout.layout51.meterLabels);
      expect(p.labelAt(const Offset(110, 40), size), isNull);
    });

    test('a label colour change repaints', () {
      final labels = OarLayout.stereo.meterLabels;
      final levels = [0.0, 0.0];
      final plain = painter(labels, levels: levels, colors: [null, null]);
      expect(
        painter(
          labels,
          levels: levels,
          colors: [null, null],
        ).shouldRepaint(plain),
        isFalse,
      );
      expect(
        painter(
          labels,
          levels: levels,
          colors: [T.meterRed, null],
        ).shouldRepaint(plain),
        isTrue,
      );
    });
  });

  testWidgets('MultichannelMeter reports the label under the pointer', (
    tester,
  ) async {
    final hovers = <MeterLabelHit?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 220,
            height: 200,
            child: MultichannelMeter(
              levels: const [0.0, 0.0],
              labels: const ['L', 'R'],
              onLabelHover: hovers.add,
            ),
          ),
        ),
      ),
    );
    final meter = find.byType(MultichannelMeter);
    final bars = find.descendant(of: meter, matching: find.byType(CustomPaint));
    final barsOrigin = tester.getTopLeft(bars);
    final size = tester.getSize(bars);
    final p = MultichannelMeterPainter(
      levels: const [0.0, 0.0],
      labels: const ['L', 'R'],
      fontMode: T.fontMode,
      themeMode: T.mode,
    );
    MeterLabelHit? onR;
    for (var x = size.width - 1; x > 0 && onR == null; x--) {
      for (var y = size.height - 1; y > size.height - 30; y--) {
        final hit = p.labelAt(Offset(x, y), size);
        if (hit?.channel == 1) {
          onR = hit;
          break;
        }
      }
    }
    expect(onR, isNotNull);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: barsOrigin + const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(barsOrigin + onR!.rect.center);
    await tester.pump();
    // Reported in the meter's coordinates, inside its 0.5 px frame.
    final shift = barsOrigin - tester.getTopLeft(meter);
    expect(hovers.last?.channel, 1);
    expect(hovers.last?.rect, onR.rect.shift(shift));
    expect(hovers.last?.stripTop, onR.stripTop + shift.dy);
    await mouse.moveTo(barsOrigin + const Offset(110, 20));
    await tester.pump();
    expect(hovers.last, isNull);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(hovers.last, isNull);
  });

  group('OutputSoloMuteStatus', () {
    testWidgets('names the channels and clears both on a click', (
      tester,
    ) async {
      final engine = _RecordingEngine();
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [eclipsaStudioEngineProvider.overrideWithValue(engine)],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, r, _) {
                  ref = r;
                  return const Center(child: OutputSoloMuteStatus());
                },
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Tooltip), findsNothing);

      final labels = ref.read(monitoringConfigProvider).layout.meterLabels;
      ref.read(outputSoloMuteProvider.notifier)
        ..toggleSolo(0)
        ..toggleMute(1);
      await tester.pump();
      expect(find.text('OUT SOLO MUTE'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip)).message!;
      expect(tooltip, contains('Soloed output channels: ${labels[0]}.'));
      expect(tooltip, contains('Muted output channels: ${labels[1]}.'));

      await tester.tap(find.text('OUT SOLO MUTE'));
      await tester.pump();
      expect(ref.read(outputSoloMuteProvider).soloed, isEmpty);
      expect(ref.read(outputSoloMuteProvider).muted, isEmpty);
      expect(engine.soloed.last, isEmpty);
      expect(engine.muted.last, isEmpty);
      expect(find.byType(Tooltip), findsNothing);
    });
  });
}
