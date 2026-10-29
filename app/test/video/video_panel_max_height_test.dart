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

// The video panel takes at most 600 px and half the height between the
// top bar and the status bar, and leaves the workspace view under it
// kMinWorkspaceViewHeight (ES-1027). videoPanelMaxHeight sets the limit.
// VideoPanel keeps to it unless the limit is less than its 100 px strip
// and 1 px border. The Creator views under the panel (Elements, Mix and
// Renderer) lay out in kMinWorkspaceViewHeight without overflowing, in
// every theme and at every font size. The Inspector view scrolls.

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/video/video_panel.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/views/mix_view.dart';
import 'package:eclipsa_studio/views/renderer_view.dart';
import 'package:eclipsa_studio/widgets/app_shell.dart';
import 'package:eclipsa_studio/widgets/resize_handle.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/golden_fonts.dart';
import '../support/mix_state_engine.dart';

void main() {
  group('videoPanelMaxHeight', () {
    test('half the height between the bars', () {
      expect(videoPanelMaxHeight(800), 400);
      expect(videoPanelMaxHeight(1100), 550);
    });

    test('600 px at most', () {
      expect(videoPanelMaxHeight(1400), 600);
    });

    test('less when the view below would get under its minimum', () {
      // Half of 600 would leave the view 300 px.
      expect(videoPanelMaxHeight(600), 600 - kMinWorkspaceViewHeight);
    });
  });

  group('VideoPanel.maxHeight', () {
    late ValueNotifier<double> maxHeight;

    Future<void> pumpPanel(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      maxHeight = ValueNotifier(double.infinity);
      addTearDown(maxHeight.dispose);
      final c = ProviderContainer(
        overrides: [videoProvider.overrideWith(_StubVideoNotifier.new)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  child: ValueListenableBuilder<double>(
                    valueListenable: maxHeight,
                    builder: (_, h, _) => VideoPanel(maxHeight: h),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    double panelHeight(WidgetTester tester) =>
        tester.getSize(find.byType(VideoPanel)).height;

    Future<void> setMaxHeight(WidgetTester tester, double h) async {
      maxHeight.value = h;
      await tester.pump();
    }

    Future<void> dragBy(WidgetTester tester, double dy) async {
      await tester.drag(find.byType(ResizeHandle), Offset(0, dy));
      await tester.pump();
    }

    testWidgets('the default height gives way to a lower limit', (
      tester,
    ) async {
      await pumpPanel(tester);
      expect(panelHeight(tester), 225); // the 224 px strip and its border

      await setMaxHeight(tester, 150);

      expect(panelHeight(tester), 150);
    });

    testWidgets('a drag stops at the limit and turns back at once', (
      tester,
    ) async {
      await pumpPanel(tester);
      await setMaxHeight(tester, 400);

      await dragBy(tester, 500);
      expect(panelHeight(tester), 400);

      // The drag stored the limit, not the 724 px it asked for, so the
      // 150 px back up shrink the panel by about as much.
      await dragBy(tester, -150);
      expect(panelHeight(tester), closeTo(250, 25));
    });

    testWidgets('a lower limit keeps the dragged height for when it rises '
        'again', (tester) async {
      await pumpPanel(tester);
      await dragBy(tester, 200);
      final dragged = panelHeight(tester);
      expect(dragged, greaterThan(400));

      await setMaxHeight(tester, 250);
      expect(panelHeight(tester), 250);

      await setMaxHeight(tester, double.infinity);
      expect(panelHeight(tester), dragged);
    });

    testWidgets('the strip keeps 100 px under any limit', (tester) async {
      await pumpPanel(tester);

      await setMaxHeight(tester, 50);

      expect(panelHeight(tester), 101);
    });
  });

  group('workspace views at kMinWorkspaceViewHeight', () {
    // Text takes the fonts and the theme the app draws with.
    setUpAll(loadGoldenFonts);

    final views = <String, Widget>{
      'Elements': const ElementsView(),
      'Mix': const MixView(),
      'Renderer': const RendererView(),
    };

    for (final MapEntry(key: name, value: view) in views.entries) {
      for (final theme in AppThemeMode.values) {
        for (final font in FontSizeMode.values) {
          testWidgets('$name, ${theme.name}, ${font.name} font: no '
              'overflow', (tester) async {
            T.setMode(theme);
            // fontSizeModeProvider starts from T.fontMode, so this sets
            // the views' font size without a preference write.
            T.setFontMode(font);
            addTearDown(() => T.setMode(T.defaultMode));
            addTearDown(() => T.setFontMode(FontSizeMode.medium));
            tester.view.physicalSize = const Size(1400, 900);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.reset);
            final c = ProviderContainer(
              overrides: [
                eclipsaStudioEngineProvider.overrideWithValue(MixStateEngine()),
                // The Renderer view's output switcher, without a device.
                outputDeviceChannelsProvider.overrideWithValue(16),
              ],
            );
            addTearDown(c.dispose);
            c.read(workspaceModeProvider.notifier).enterCreator();
            _seedSession(c);

            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: c,
                child: MaterialApp(
                  theme: eclipsaStudioTheme(),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 1400,
                        height: kMinWorkspaceViewHeight,
                        child: view,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();

            expect(tester.takeException(), isNull);
            // The Renderer view's 3D viewer leaves timers to run out.
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 1));
          });
        }
      }
    }
  });
}

/// Three elements, the third left out of the one mix so the Mix view
/// draws its add strip as well as two channel strips.
void _seedSession(ProviderContainer c) {
  AudioElement element(int id, String type, String layout) => AudioElement(
    id: id,
    name: 'Element $id',
    type: type,
    layout: layout,
    codec: 'WAV 24bit',
    color: 0xFF34D399,
    wavPath: '/media/e$id.wav',
  );
  c.read(elementsProvider.notifier).set([
    element(1, 'Channel', '7.1.4'),
    element(2, 'Scene', 'Ambisonics 3OA'),
    element(3, 'Channel', 'Stereo'),
  ]);
  c.read(mixesNotifierProvider.notifier).set(const [
    Mix(
      id: 1,
      name: 'Main',
      subMixes: [
        SubMix(
          elementSettings: [
            MixElementSettings(elementId: 1),
            MixElementSettings(elementId: 2),
            MixElementSettings(elementId: 3, included: false),
          ],
        ),
      ],
    ),
  ]);
}

/// The video state without a backend: [VideoNotifier.build] builds a
/// decoder, and these tests need none.
class _StubVideoNotifier extends VideoNotifier {
  @override
  VideoState build() => const VideoState();
}
