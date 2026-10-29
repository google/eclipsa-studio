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
import 'package:eclipsa_studio/widgets/transport_controls.dart';
import 'package:eclipsa_studio/widgets/transport_scrub_bar.dart';
import 'package:eclipsa_studio/window_geometry.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/golden_fonts.dart';

/// The Creator topbar with the Elements tab active fits the preferred
/// minimum window width in every theme and font size, scrub bar
/// included (ES-988). The app's fonts are loaded so the text has its
/// shipped width: at 1400 px the bar measured 223 to 237 px in the
/// small font, 131 to 139 px in the medium font and 37 to 42 px in the
/// large font. Playback's bar is 80 to 95 px wider, so Creator is the
/// case to test.
void main() {
  setUpAll(loadGoldenFonts);
  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  for (final theme in AppThemeMode.values) {
    for (final font in FontSizeMode.values) {
      testWidgets('${theme.name}, ${font.name} font', (tester) async {
        T.setMode(theme);
        T.setFontMode(font);
        tester.view.physicalSize = Size(kPreferredMinWindowSize.width, 200);
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
        container.read(workspaceModeProvider.notifier).enterCreator();
        container.read(activeTabProvider.notifier).set(WorkspaceTabs.elements);
        await tester.pump();

        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(TransportScrubBar));
        final transport = tester.getRect(find.byType(TransportControls));
        // The bar draws its playhead knob only when it is at least as
        // wide as the knob: 10 px while hovered.
        expect(bar.width, greaterThanOrEqualTo(10));
        expect(transport.left - bar.right, moreOrLessEquals(16));
      });
    }
  }
}
