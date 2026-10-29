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
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:eclipsa_studio/widgets/topbar.dart';
import 'package:eclipsa_studio/widgets/transport_clock.dart';
import 'package:eclipsa_studio/widgets/transport_controls.dart';
import 'package:eclipsa_studio/widgets/transport_scrub_bar.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The clock reserves the width of the longest value its display mode
/// can show, and the topbar's groups keep their places as the clock's
/// text, the duration and the active tab change (ES-915).
void main() {
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  const rate = 48000;
  // 1:53:40.523, the file the issue was seen with.
  const longFile = 327385088;
  // 59:59.999 and 1:00:00.000: the switch to the hour format.
  const beforeHour = 3599999 * rate ~/ 1000;
  const atHour = 3600 * rate;

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

  /// The rects of the parts whose places the clock must not move.
  Map<String, Rect> layout(WidgetTester tester) => {
    'mix selector': tester.getRect(find.byType(ConsoleSelector<int>)),
    'scrub bar': tester.getRect(find.byType(TransportScrubBar)),
    'transport': tester.getRect(find.byType(TransportControls)),
    'clock': tester.getRect(find.byType(TransportClock)),
  };

  Finder clockShowing(String text) =>
      find.textContaining(text, findRichText: true);

  Future<void> setTransport(
    WidgetTester tester,
    ProviderContainer container, {
    required int duration,
    required int position,
  }) async {
    final transport = container.read(transportProvider.notifier);
    transport.updateDuration(duration, rate);
    transport.setSamplePosition(position);
    await tester.pump();
  }

  for (final theme in AppThemeMode.values) {
    for (final font in FontSizeMode.values) {
      group('${theme.name}, ${font.name} font', () {
        setUp(() {
          T.setMode(theme);
          T.setFontMode(font);
        });

        testWidgets('crossing one hour moves nothing', (tester) async {
          final container = await pumpTopbar(
            tester,
            mode: WorkspaceMode.playback,
            tab: WorkspaceTabs.renderer,
          );
          await setTransport(
            tester,
            container,
            duration: longFile,
            position: beforeHour,
          );
          expect(clockShowing('59:59.999 / 1:53:40.523'), findsOneWidget);
          final before = layout(tester);

          await setTransport(
            tester,
            container,
            duration: longFile,
            position: atHour,
          );
          expect(clockShowing('1:00:00.000 / 1:53:40.523'), findsOneWidget);
          expect(layout(tester), before);
        });

        testWidgets('an unknown duration and the scanned one match', (
          tester,
        ) async {
          final container = await pumpTopbar(
            tester,
            mode: WorkspaceMode.playback,
            tab: WorkspaceTabs.inspector,
          );
          await setTransport(tester, container, duration: 0, position: 0);
          expect(clockShowing('00:00.000 / 00:00.000'), findsOneWidget);
          // The scan's caption stands in for the bar, in the bar's slot.
          final caption = find.descendant(
            of: find.byType(TransportScrubBar),
            matching: find.text('ANALYZING…'),
          );
          expect(caption, findsOneWidget);
          final scanning = layout(tester);

          await setTransport(
            tester,
            container,
            duration: longFile,
            position: 0,
          );
          expect(clockShowing('00:00.000 / 1:53:40.523'), findsOneWidget);
          expect(caption, findsNothing);
          expect(layout(tester), scanning);
        });

        testWidgets('samples mode keeps one width', (tester) async {
          final container = await pumpTopbar(
            tester,
            mode: WorkspaceMode.playback,
            tab: WorkspaceTabs.renderer,
          );
          container
              .read(timeDisplayProvider.notifier)
              .restore(TimeDisplayMode.samples);
          // One second: the shortest sample counts, outside the scan.
          await setTransport(tester, container, duration: rate, position: 0);
          expect(clockShowing('0 /      48000'), findsOneWidget);
          final short = layout(tester);

          await setTransport(
            tester,
            container,
            duration: longFile,
            position: longFile - 1,
          );
          expect(clockShowing('327385087 /  327385088'), findsOneWidget);
          expect(layout(tester), short);
        });
      });
    }
  }

  testWidgets('a font size change widens the clock, which then holds', (
    tester,
  ) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.playback,
      tab: WorkspaceTabs.renderer,
    );
    await setTransport(
      tester,
      container,
      duration: longFile,
      position: beforeHour,
    );
    final medium = tester.getRect(find.byType(TransportClock));

    container.read(fontSizeModeProvider.notifier).set(FontSizeMode.large);
    await tester.pump();
    final large = layout(tester);
    expect(large['clock']!.width, greaterThan(medium.width));

    await setTransport(tester, container, duration: longFile, position: atHour);
    expect(clockShowing('1:00:00.000 / 1:53:40.523'), findsOneWidget);
    expect(layout(tester), large);
  });

  testWidgets('the Creator topbar keeps its layout across tabs', (
    tester,
  ) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.creator,
      tab: WorkspaceTabs.elements,
    );
    final elements = layout(tester);

    for (final tab in WorkspaceTabs.allowedIn(WorkspaceMode.creator)) {
      container.read(activeTabProvider.notifier).set(tab);
      await tester.pump();
      expect(layout(tester), elements, reason: tab);
    }
  });

  testWidgets('the scrub bar sits 16 px before the transport, 400 px wide', (
    tester,
  ) async {
    await pumpTopbar(
      tester,
      mode: WorkspaceMode.playback,
      tab: WorkspaceTabs.renderer,
    );
    final bar = tester.getRect(find.byType(TransportScrubBar));
    final transport = tester.getRect(find.byType(TransportControls));
    expect(bar.width, 400);
    expect(transport.left - bar.right, 16);
  });

  testWidgets('a value past the reserved width widens the clock', (
    tester,
  ) async {
    final container = await pumpTopbar(
      tester,
      mode: WorkspaceMode.playback,
      tab: WorkspaceTabs.renderer,
    );
    const tenHours = 10 * 3600 * rate;
    await setTransport(tester, container, duration: tenHours, position: 0);
    final reserved = tester.getRect(find.byType(TransportClock)).width;

    await setTransport(
      tester,
      container,
      duration: tenHours,
      position: tenHours,
    );
    expect(clockShowing('10:00:00.000 / 10:00:00.000'), findsOneWidget);
    expect(
      tester.getRect(find.byType(TransportClock)).width,
      greaterThan(reserved),
    );
    expect(tester.takeException(), isNull);
  });
}
