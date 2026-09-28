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
import 'package:eclipsa_studio/widgets/theme_cycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The cycle is a dev tool, so the bar is "does not lie and does not get
// stuck": it must visit every theme, wrap, and
// actually swap the values T serves. Which theme you are on is answered
// by the status bar, not by this class — see statusbar.dart.
void main() {
  late WidgetRef capturedRef;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
  }

  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('is silent — the status bar reports the theme, not a toast', (
    tester,
  ) async {
    // Previously this raised a SnackBar per press. ScaffoldMessenger
    // queues them, so holding the shortcut down left the strip draining
    // for ~20s after you stopped. Replaced by a persistent status-bar
    // readout; nothing transient should come back here.
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();

    for (var i = 0; i < 12; i++) {
      ThemeCycle.next(capturedRef);
      await tester.pump();
    }
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('visits every theme and wraps', (tester) async {
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();

    final seen = <AppThemeMode>[];
    for (var i = 0; i < AppThemeMode.values.length; i++) {
      ThemeCycle.next(capturedRef);
      await tester.pump();
      seen.add(capturedRef.read(themeModeProvider));
    }

    expect(
      seen.toSet(),
      AppThemeMode.values.toSet(),
      reason: 'one full cycle must visit every theme',
    );
    expect(
      seen.last,
      AppThemeMode.classic,
      reason: 'a full cycle must return to where it started',
    );
  });

  testWidgets('visits every theme', (tester) async {
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();

    final seen = <AppThemeMode>[];
    for (var i = 0; i < AppThemeMode.values.length; i++) {
      ThemeCycle.next(capturedRef);
      await tester.pump();
      seen.add(capturedRef.read(themeModeProvider));
    }
    expect(seen, contains(AppThemeMode.light));
    expect(seen, contains(AppThemeMode.dark));
  });

  testWidgets('actually swaps the values T serves', (tester) async {
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();
    final before = T.bgBase;

    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pump();
    expect(T.bgBase, isNot(before));

    // Dark is the default. Setting it again while it is active keeps
    // its values.
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pump();
    expect(T.bgBase, isNot(before));

    // Light's body tokens were dark's byte-for-byte until ES-751 made
    // them the light palette. The cycle must show it.
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.light);
    await tester.pump();
    expect(T.bgBase, isNot(before), reason: 'Light has a ground of its own');
  });
}
