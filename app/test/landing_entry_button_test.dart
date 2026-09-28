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

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/app_button.dart';
import 'package:eclipsa_studio/workspace/landing_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The landing card's entry buttons are one drawing in every theme: a
/// regular [AppButton], 36 px tall, in the card's ink. Light once
/// drew them as raised faces beside a Material button the app's
/// compact desktop density had shrunk, so the two stood 48 px and
/// 32 px in the app while a widget test, which has no platform
/// density, measured them equal.
class _FakeSessions extends RecentSessionsNotifier {
  @override
  List<String> build() => const ['/a/one.esp'];
}

class _FakeQcFiles extends RecentQcFilesNotifier {
  @override
  List<String> build() => const ['/b/only.iamf'];
}

const _labels = [
  'New Session',
  'Import ADM…',
  'Open Existing Session…',
  'Open IAMF or MP4 for Playback…',
];

void main() {
  Future<void> pumpThemed(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        recentSessionsProvider.overrideWith(_FakeSessions.new),
        recentQcFilesProvider.overrideWith(_FakeQcFiles.new),
      ],
      child: MaterialApp(
        theme: eclipsaStudioTheme(),
        home: const LandingScreen(),
      ),
    ),
  );

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..physicalSize = const Size(1400, 1000)
      ..devicePixelRatio = 1.0;
  });

  tearDown(() {
    T.setMode(AppThemeMode.classic);
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });

  /// The [AppButton] carrying a given entry button's label.
  Finder buttonFor(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(AppButton));

  for (final mode in AppThemeMode.values) {
    testWidgets('entry buttons are AppButtons in ${mode.name}', (tester) async {
      T.setMode(mode);
      await pumpThemed(tester);
      for (final label in _labels) {
        expect(
          buttonFor(label),
          findsOneWidget,
          reason: '$label must be an AppButton in ${mode.name}',
        );
      }
    });
  }

  // The app theme takes Flutter's platform default visual density,
  // which is compact on desktop and takes 8 px off each side of a
  // Material button's padding. AppButton draws no Material button, so
  // it has to measure the same under the desktop density as under the
  // test's default one.
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('the button is 36 px tall in every theme on $platform', (
      tester,
    ) async {
      // Reset inside the body: the binding checks the override is
      // unset when the body returns, before tearDown runs.
      debugDefaultTargetPlatformOverride = platform;
      try {
        for (final mode in AppThemeMode.values) {
          T.setMode(mode);
          // A fresh tree: `const LandingScreen()` is canonicalised, so
          // pumping it again over the last theme short-circuits at
          // Element.updateChild and the screen keeps the old theme.
          await tester.pumpWidget(const SizedBox());
          await pumpThemed(tester);
          for (final label in _labels) {
            expect(
              tester.getRect(buttonFor(label)).height,
              equals(36),
              reason: '$label in ${mode.name} on $platform',
            );
          }
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('the label is the same type in every theme', (tester) async {
    final styles = <AppThemeMode, TextStyle>{};
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await tester.pumpWidget(const SizedBox());
      await pumpThemed(tester);
      styles[mode] = tester.widget<Text>(find.text('New Session')).style!;
    }
    final reference = styles[AppThemeMode.dark]!;
    for (final entry in styles.entries) {
      expect(entry.value.fontSize, equals(reference.fontSize));
      expect(entry.value.fontWeight, equals(reference.fontWeight));
    }
  });

  // Light draws the card on the chromeBg ground, and every ink on
  // the card is chromeInk there, 8.01:1 on chromeBg.
  testWidgets('Light inks the card in chromeInk', (tester) async {
    T.setMode(AppThemeMode.light);
    await pumpThemed(tester);
    expect(
      tester.widget<Text>(find.text('New Session')).style!.color,
      equals(T.chromeInk),
      reason: 'the entry label',
    );
    expect(
      tester.widget<Text>(find.text('one.esp')).style!.color,
      equals(T.chromeInk),
      reason: 'the Recent file name',
    );
    expect(
      tester.widget<Text>(find.text('/a')).style!.color,
      equals(T.chromeInk),
      reason: 'the Recent folder line',
    );
    expect(
      tester.widget<Text>(find.text('RECENT').first).style!.color,
      equals(T.chromeInk),
      reason: 'the Recent eyebrow',
    );
  });
}
