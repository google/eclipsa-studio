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
import 'package:eclipsa_studio/widgets/resize_handle.dart';
import 'package:eclipsa_studio/widgets/track_lanes.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The divider between the track panels and the waveforms, which the
/// Elements view's resize handle moves, is 1 px in every theme, as the
/// panel borders and the border under the video are (ES-1009). It was
/// 0.5 px.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  for (final mode in AppThemeMode.values) {
    testWidgets('${mode.name}: the resizable divider is 1 px, under the '
        'handle', (tester) async {
      T.setMode(mode);
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
      container.read(elementsProvider.notifier).set([
        AudioElement(
          id: 1,
          name: 'Bed',
          type: 'Channel',
          layout: 'Stereo',
          codec: 'Opus',
          color: 0xFF34D399,
        ),
      ]);
      await tester.pumpAndSettle();

      // The panel and gutter backdrop, the one box in the panel's ground
      // with a right border: that border is the divider.
      final backdrop = find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final d = w.decoration;
        return d is BoxDecoration &&
            d.color == trackPanelStripColor() &&
            d.border is Border &&
            (d.border! as Border).right != BorderSide.none;
      });
      expect(backdrop, findsOneWidget);
      final border =
          (tester.widget<Container>(backdrop).decoration! as BoxDecoration)
                  .border!
              as Border;
      expect(border.right.width, 1);
      expect(border.right.color, T.border);

      // The handle's lit line ends on the divider's right edge.
      final handle = find.byWidgetPredicate(
        (w) => w is ResizeHandle && w.axis == Axis.horizontal,
      );
      expect(
        tester.getRect(handle).left +
            tester.widget<ResizeHandle>(handle).borderOffset,
        tester.getRect(backdrop).right,
      );
    });
  }
}
