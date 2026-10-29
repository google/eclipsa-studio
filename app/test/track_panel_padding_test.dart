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
import 'package:eclipsa_studio/widgets/track_lanes.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The controls in an element's header keep clear of the panel's
/// edges in every theme, including Light's card (ES-763).
void main() {
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  AudioElement elem(int id, {String type = 'Channel'}) => AudioElement(
    id: id,
    name: 'element with a long name $id',
    type: type,
    layout: type == 'Object' ? 'Mono' : 'Stereo',
    codec: 'Opus',
    color: 0xFF34D399,
  );

  Future<ProviderContainer> pumpRows(
    WidgetTester tester,
    AppThemeMode mode, {
    FontSizeMode font = FontSizeMode.medium,
    AudioElement? element,
    bool excluded = false,
  }) async {
    T.setMode(mode);
    T.setFontMode(font);
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
    final e = element ?? elem(1);
    container.read(elementsProvider.notifier).set([e]);
    if (excluded) {
      container.read(mixesNotifierProvider.notifier).set([
        Mix(
          id: 1,
          name: 'Mix',
          subMixes: [
            SubMix(
              elementSettings: [
                MixElementSettings(elementId: e.id, included: false),
              ],
            ),
          ],
        ),
      ]);
    }
    await tester.pumpAndSettle();
    return container;
  }

  /// The card's or column's box, as [TrackPanel] decorates it (inside
  /// the card's margin).
  Rect panelBox(WidgetTester tester) => tester.getRect(
    find
        .descendant(
          of: find.byType(TrackPanel).first,
          matching: find.byType(DecoratedBox),
        )
        .first,
  );

  for (final mode in AppThemeMode.values) {
    testWidgets('${mode.name}: the M button keeps 4 px or more from the '
        "panel's right edge", (tester) async {
      await pumpRows(tester, mode);
      final box = panelBox(tester);
      // The button's face, not only its glyph, must clear the edge.
      final button = tester.getRect(
        find
            .ancestor(
              of: find
                  .descendant(
                    of: find.byType(TrackPanel).first,
                    matching: find.text('M'),
                  )
                  .first,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(
        box.right - button.right,
        greaterThanOrEqualTo(4),
        reason: 'M button to panel edge',
      );
    });

    // The default header only: a Channel element in the mix at 0 dB.
    // The excluded-element badge and the Object sliders are not drawn.
    testWidgets('${mode.name}: the default header fits at the narrowest '
        'panel', (tester) async {
      final container = await pumpRows(tester, mode);
      container.read(trackPanelWidthProvider.notifier).set(120);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    // The tallest header, an Object element excluded from the mix with
    // its Not in mix presentation line drawn, in every font size at the
    // narrowest panel and the default width (ES-765). The add-element drop
    // zone below it is laid out too.
    for (final font in FontSizeMode.values) {
      for (final width in [120.0, 180.0]) {
        testWidgets('${mode.name}, ${font.name} font, ${width.toInt()} px: '
            'an excluded Object header fits', (tester) async {
          final container = await pumpRows(
            tester,
            mode,
            font: font,
            element: elem(1, type: 'Object'),
            excluded: true,
          );
          container.read(trackPanelWidthProvider.notifier).set(width);
          await tester.pumpAndSettle();
          expect(find.text('Not in mix presentation'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
