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

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/playback/playback_session.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:eclipsa_studio/widgets/topbar.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

IamfMixPresentation _presentation(int id, String? name) => IamfMixPresentation(
  id: id,
  name: name,
  language: null,
  loudnessLufs: null,
  truePeakDbtp: null,
  elements: const [],
  layoutType: null,
  soundSystem: null,
);

/// The top bar's mix presentation switcher is a ConsoleSelector in both
/// modes: it switches the active presentation, shows a disabled
/// placeholder when there is none, and follows the theme.
void main() {
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  Future<ProviderContainer> pumpTopbar(WidgetTester tester) async {
    // Wide: the test font draws square glyphs, so the topbar's text is
    // about twice its shipped width.
    tester.view.physicalSize = const Size(2400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [eclipsaStudioEngineProvider.overrideWithValue(null)],
        child: MaterialApp(
          theme: eclipsaStudioTheme(),
          home: const Scaffold(body: Topbar()),
        ),
      ),
    );
    return ProviderScope.containerOf(tester.element(find.byType(Topbar)));
  }

  Finder selector() => find.byType(ConsoleSelector<int>);

  ConsoleSelector<int> selectorWidget(WidgetTester tester) =>
      tester.widget<ConsoleSelector<int>>(selector());

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(selector());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, label));
    await tester.pumpAndSettle();
  }

  testWidgets('Creator: picking a mix sets it active and resets the sub-mix', (
    tester,
  ) async {
    final container = await pumpTopbar(tester);
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(mixesNotifierProvider.notifier).set(const [
      Mix(id: 1, name: 'Main Mix', subMixes: [SubMix(), SubMix()]),
      Mix(id: 2, name: 'Stereo Downmix', subMixes: [SubMix()]),
      Mix(id: 3, name: 'Dialogue', subMixes: [SubMix()]),
    ]);
    container.read(activeSubMixProvider.notifier).set(1);
    await tester.pump();
    expect(selectorWidget(tester).width, 180);
    expect(selectorWidget(tester).enabled, isTrue);
    expect(
      find.descendant(of: selector(), matching: find.text('Main Mix')),
      findsOneWidget,
    );

    await pick(tester, 'Dialogue');
    expect(container.read(activeMixProvider), 2);
    expect(container.read(activeSubMixProvider), 0);
    expect(
      find.descendant(of: selector(), matching: find.text('Dialogue')),
      findsOneWidget,
    );
  });

  testWidgets('Creator: picking the active mix keeps its sub-mix', (
    tester,
  ) async {
    final container = await pumpTopbar(tester);
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(mixesNotifierProvider.notifier).set(const [
      Mix(id: 1, name: 'Main Mix', subMixes: [SubMix(), SubMix()]),
      Mix(id: 2, name: 'Stereo Downmix', subMixes: [SubMix()]),
    ]);
    container.read(activeSubMixProvider.notifier).set(1);
    await tester.pump();

    await pick(tester, 'Main Mix');
    expect(container.read(activeMixProvider), 0);
    expect(container.read(activeSubMixProvider), 1);
  });

  testWidgets('Creator with no mixes: a disabled placeholder', (tester) async {
    final container = await pumpTopbar(tester);
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(mixesNotifierProvider.notifier).set(const []);
    await tester.pump();
    expect(selectorWidget(tester).enabled, isFalse);
    expect(
      find.descendant(
        of: selector(),
        matching: find.text('No mix presentations'),
      ),
      findsOneWidget,
    );
    await tester.tap(selector(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('Playback: picking a presentation switches the session', (
    tester,
  ) async {
    final container = await pumpTopbar(tester);
    container.read(workspaceModeProvider.notifier).enterPlayback();
    container
        .read(playbackSessionProvider.notifier)
        .open(
          path: '/tmp/test.iamf',
          report: IamfProbeReport(
            ok: true,
            errorMessage: null,
            sampleRate: 48000,
            totalSamples: 48000,
            audioElements: const [],
            mixPresentations: [
              _presentation(10, 'Main'),
              _presentation(11, null),
            ],
          ),
          sampleRate: 48000,
          totalFrames: 48000,
          audioElements: const [],
        );
    await tester.pump();
    expect(
      find.descendant(of: selector(), matching: find.text('Main')),
      findsOneWidget,
    );

    // A presentation without a name is listed by its position.
    await pick(tester, 'Mix Presentation 2');
    expect(container.read(playbackSessionProvider)!.activeMixIndex, 1);
    expect(
      find.descendant(
        of: selector(),
        matching: find.text('Mix Presentation 2'),
      ),
      findsOneWidget,
    );
  });

  // Creator has the default mix; Playback with no file open has none,
  // so it draws the disabled control.
  for (final (mode, dim) in [
    (WorkspaceMode.creator, 1.0),
    (WorkspaceMode.playback, 0.4),
  ]) {
    testWidgets('${mode.name}: the control follows theme and font size', (
      tester,
    ) async {
      final container = await pumpTopbar(tester);
      final workspace = container.read(workspaceModeProvider.notifier);
      mode == WorkspaceMode.creator
          ? workspace.enterCreator()
          : workspace.enterPlayback();
      await tester.pump();
      Decoration? control() => tester
          .widget<Container>(
            find
                .descendant(of: selector(), matching: find.byType(Container))
                .first,
          )
          .decoration;
      double? labelSize() => tester
          .widget<Text>(
            find.descendant(of: selector(), matching: find.byType(Text)).first,
          )
          .style
          ?.fontSize;
      for (final theme in AppThemeMode.values) {
        container.read(themeModeProvider.notifier).set(theme);
        await tester.pump();
        expect(
          control(),
          SelectorChrome.decoration(hover: false, dim: dim),
          reason: theme.name,
        );
      }
      final medium = labelSize();
      container.read(fontSizeModeProvider.notifier).set(FontSizeMode.large);
      await tester.pump();
      expect(labelSize(), T.fontBody);
      expect(labelSize(), greaterThan(medium!));
    });
  }
}
