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

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/component_index.dart';
import 'package:eclipsa_studio/widgets/theme_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The generator enforces the registry's own rules (a class must exist
// where it says, a name-match must not carry a node id). What it cannot
// check is the half that lives in Dart: that the gallery actually
// renders what the index holds, and that the index reaches the screen
// rather than being generated and then ignored.
void main() {
  group('component index', () {
    test('every entry names a class and a Dart file', () {
      expect(kComponentIndex, isNotEmpty);
      for (final e in kComponentIndex.entries) {
        expect(e.key, e.value.name, reason: 'map key must be the class name');
        expect(e.value.declaredIn, endsWith('.dart'));
        expect(e.value.declaredIn, startsWith('lib/'));
        expect(e.value.summary, isNotEmpty, reason: '${e.key} has no summary');
      }
    });

    test('useCount is the sum of the per-file counts', () {
      for (final c in kComponentIndex.values) {
        final sum = c.usedIn.values.fold(0, (a, b) => a + b);
        expect(c.useCount, sum, reason: '${c.name} count disagrees with map');
      }
    });

    test('a component is never recorded as using itself', () {
      // The generator excludes the declaring file, because a constructor
      // declaration `const ConsoleLed({...})` matches the same pattern
      // as a call site and would inflate every component by one.
      for (final c in kComponentIndex.values) {
        expect(
          c.usedIn.keys,
          isNot(contains(c.declaredIn)),
          reason: '${c.name} counts its own declaration',
        );
      }
    });

    test('the gallery is never counted as a usage', () {
      // It renders every component, so counting it would report "1 file"
      // for everything and mean nothing. Components whose only caller is
      // the gallery are meant to read as zero.
      for (final c in kComponentIndex.values) {
        expect(
          c.usedIn.keys,
          isNot(contains('lib/widgets/theme_gallery.dart')),
          reason: '${c.name} counts the gallery',
        );
      }
    });
  });

  group('the gallery renders the index', () {
    Future<void> pump(WidgetTester tester) async {
      T.setMode(AppThemeMode.classic);
      // 2000px tall so the whole component list lays out without the
      // scroll view culling the cards this test looks for.
      tester.view.physicalSize = const Size(1600, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: ThemeGallery())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a component shows its class name and declaring file', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('AppButton'), findsWidgets);
      expect(find.text('lib/widgets/app_button.dart'), findsWidgets);
    });

    testWidgets('the use count comes from the generated index', (tester) async {
      await pump(tester);
      final info = kComponentIndex['AppButton']!;
      final files = info.usedIn.length;
      expect(
        find.text('${info.useCount} uses · $files files'),
        findsOneWidget,
        reason: 'the chip must show generated counts, not hardcoded text',
      );
    });

    testWidgets('a component with no call sites says so', (tester) async {
      await pump(tester);
      // GainSlider is declared and never built anywhere in the app. The
      // chip must name that rather than showing "0 uses", which reads
      // like a missing measurement instead of a real answer.
      expect(kComponentIndex['GainSlider']!.useCount, 0);
      expect(find.text('no call sites'), findsWidgets);
    });

    testWidgets('every registry entry has a card in the gallery', (
      tester,
    ) async {
      // The registry is what the gallery documents, so an entry with no
      // card is a component the index claims to cover and does not.
      // Removing KnobA's demo once dropped it from the screen while it
      // stayed in the registry, and nothing noticed.
      await pump(tester);
      for (final name in kComponentIndex.keys) {
        expect(find.text(name), findsWidgets, reason: '$name has no card');
      }
    });
  });
}
