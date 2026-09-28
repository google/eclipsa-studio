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
import 'package:eclipsa_studio/widgets/topbar.dart';
import 'package:eclipsa_studio/widgets/transport_scrub_bar.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which tabs carry the transport scrub bar in the topbar, and that
/// the bar seeks and follows the theme there (ES-35, ES-783).
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<ProviderContainer> pumpTopbar(
    WidgetTester tester, {
    required WorkspaceMode mode,
    required String tab,
  }) async {
    // Wide: the test font draws square glyphs, so the topbar's text is
    // about twice its shipped width and the bar needs the room.
    tester.view.physicalSize = const Size(2400, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: eclipsaStudioTheme(),
          home: const Scaffold(body: Topbar()),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Topbar)),
    );
    switch (mode) {
      case WorkspaceMode.creator:
        container.read(workspaceModeProvider.notifier).enterCreator();
      case WorkspaceMode.playback:
        container.read(workspaceModeProvider.notifier).enterPlayback();
      case WorkspaceMode.none:
        break;
    }
    container.read(activeTabProvider.notifier).set(tab);
    await tester.pump();
    return container;
  }

  test('showsScrubBar: every Playback tab, every Creator tab but Elements', () {
    for (final tab in WorkspaceTabs.allowedIn(WorkspaceMode.playback)) {
      expect(showsScrubBar(WorkspaceMode.playback, tab), isTrue, reason: tab);
    }
    expect(
      showsScrubBar(WorkspaceMode.creator, WorkspaceTabs.elements),
      isFalse,
    );
    expect(showsScrubBar(WorkspaceMode.creator, WorkspaceTabs.mix), isTrue);
    expect(
      showsScrubBar(WorkspaceMode.creator, WorkspaceTabs.renderer),
      isTrue,
    );
    expect(showsScrubBar(WorkspaceMode.none, WorkspaceTabs.elements), isFalse);
  });

  for (final (mode, tab, shown) in [
    (WorkspaceMode.creator, WorkspaceTabs.elements, false),
    (WorkspaceMode.creator, WorkspaceTabs.mix, true),
    (WorkspaceMode.creator, WorkspaceTabs.renderer, true),
    (WorkspaceMode.playback, WorkspaceTabs.renderer, true),
    (WorkspaceMode.playback, WorkspaceTabs.inspector, true),
  ]) {
    testWidgets('${mode.name}, $tab tab: ${shown ? 'bar' : 'no bar'}', (
      tester,
    ) async {
      await pumpTopbar(tester, mode: mode, tab: tab);
      expect(
        find.byType(TransportScrubBar),
        shown ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('switching from Elements to Renderer adds the bar in place', (
    tester,
  ) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.creator,
      tab: WorkspaceTabs.elements,
    );
    expect(find.byType(TransportScrubBar), findsNothing);
    container.read(activeTabProvider.notifier).set(WorkspaceTabs.renderer);
    await tester.pump();
    expect(find.byType(TransportScrubBar), findsOneWidget);
    container.read(activeTabProvider.notifier).set(WorkspaceTabs.elements);
    await tester.pump();
    expect(find.byType(TransportScrubBar), findsNothing);
  });

  testWidgets('a tap on the bar in the Renderer tab seeks the transport', (
    tester,
  ) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.creator,
      tab: WorkspaceTabs.renderer,
    );
    final duration = container.read(transportProvider).durationSamples;
    expect(duration, greaterThan(0));
    expect(container.read(transportAnalyzingProvider), isFalse);

    final bar = tester.getRect(find.byType(TransportScrubBar));
    await tester.tapAt(Offset(bar.left + bar.width / 2, bar.center.dy));
    await tester.pump();
    final pos = container.read(transportProvider).samplePosition;
    expect((pos - duration / 2).abs(), lessThan(duration * 0.01));
  });

  testWidgets('a loop region shows on the bar as a band', (tester) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.creator,
      tab: WorkspaceTabs.renderer,
    );
    final duration = container.read(transportProvider).durationSamples;
    container
        .read(loopRegionProvider.notifier)
        .set(LoopRegion(startSample: duration ~/ 4, endSample: duration ~/ 2));
    await tester.pump();
    final bar = tester.getRect(find.byType(TransportScrubBar));
    final bands = find.byKey(TransportScrubBar.loopBandKey);
    expect(bands, findsOneWidget);
    final band = tester.getRect(bands);
    expect(band.left - bar.left, closeTo(bar.width / 4, 1));
    expect(band.width, closeTo(bar.width / 4, 1));

    container.read(loopRegionProvider.notifier).clear();
    await tester.pump();
    expect(bands, findsNothing);
  });

  Future<ProviderContainer> pumpBar(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: eclipsaStudioTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: const TransportScrubBar()),
            ),
          ),
        ),
      ),
    );
    return ProviderScope.containerOf(
      tester.element(find.byType(TransportScrubBar)),
    );
  }

  testWidgets('a bar narrower than the hovered knob draws without error', (
    tester,
  ) async {
    await pumpBar(tester, 6);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byType(TransportScrubBar)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a zero duration outside a scan says there is nothing to seek', (
    tester,
  ) async {
    final container = await pumpBar(tester, 400);
    container.read(transportProvider.notifier).updateDuration(0, 48000);
    await tester.pump();
    expect(container.read(transportAnalyzingProvider), isFalse);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Nothing to seek',
    );
  });

  testWidgets('the bar takes the new theme on a theme switch', (tester) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.creator,
      tab: WorkspaceTabs.renderer,
    );
    Color track() =>
        (tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: find.byType(TransportScrubBar),
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    container.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pump();
    expect(track(), T.bgDeep);
    final dark = track();

    container.read(themeModeProvider.notifier).set(AppThemeMode.light);
    await tester.pump();
    expect(track(), T.bgDeep);
    expect(track(), isNot(dark));
  });

  testWidgets('High Contrast outlines the track on its black ground', (
    tester,
  ) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.creator,
      tab: WorkspaceTabs.renderer,
    );
    BoxDecoration track() =>
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byType(TransportScrubBar),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    var outlinedModes = 0;
    for (final mode in AppThemeMode.values) {
      container.read(themeModeProvider.notifier).set(mode);
      await tester.pump();
      final outlined = T.chromeStyle == ChromeStyle.outlined;
      if (outlined) outlinedModes++;
      expect(
        track().border,
        outlined ? isNotNull : isNull,
        reason: '${mode.name} track border',
      );
      if (outlined) {
        expect(track().border!.top.color, T.border);
        expect(track().color, isNot(T.border));
      }
    }
    expect(outlinedModes, 1, reason: 'High Contrast is the outlined theme');
  });
}
