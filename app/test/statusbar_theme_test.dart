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

import 'dart:io';

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/statusbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The active theme is reported persistently in the status bar rather
// than announced in a toast. That readout is the only answer to "which
// theme am I on?" while cycling with the `t` key, so it has to track
// the actual theme and not go stale.
//
// The status bar renders without the native engine (it degrades to
// "Engine unavailable"), so this needs no dylib.
void main() {
  late WidgetRef capturedRef;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    capturedRef = ref;
                    return const Statusbar();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('shows the active theme and follows a switch', (tester) async {
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();
    expect(find.text(kThemeMeta[AppThemeMode.classic]!.label), findsOneWidget);

    // Every theme, including the concept ones, must be nameable here —
    // this is what tells them apart when two look similar.
    for (final mode in AppThemeMode.values) {
      capturedRef.read(themeModeProvider.notifier).set(mode);
      await tester.pump();
      expect(
        find.text(kThemeMeta[mode]!.label),
        findsOneWidget,
        reason: 'status bar did not follow the switch to ${mode.name}',
      );
    }
  });

  testWidgets('the readout ships, unlike the gallery', (tester) async {
    // The readout used to be gated on kThemeGalleryEnabled and so was
    // absent from release builds. All four themes are offered in
    // Settings now, so the status bar names the active one in every
    // build; only the gallery stays behind kDebugMode.
    //
    // Tests run in debug, so this cannot observe a release build
    // directly. What it can pin is that the readout does not depend on
    // the gallery flag: source-gating it again would have to reach
    // through statusbar.dart, which no longer imports theme_gallery.
    final source = File('lib/widgets/statusbar.dart').readAsStringSync();
    expect(
      source,
      isNot(contains('kThemeGalleryEnabled')),
      reason: 'the status bar theme readout must not be debug-gated',
    );
    await pump(tester);
    expect(find.text(kThemeMeta[T.mode]!.label), findsOneWidget);
  });
}
