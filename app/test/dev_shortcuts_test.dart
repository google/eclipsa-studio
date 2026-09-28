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
import 'package:eclipsa_studio/widgets/dev_shortcuts.dart';
import 'package:eclipsa_studio/widgets/theme_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// `t` and `g` carry no modifier, so the risk they carry is not "does
// the shortcut work" but "does it fire when it must not". A bare letter
// that hijacks a text field makes every name box in the app unusable,
// and it fails silently — the character still appears, the theme just
// also changes. That is the case worth pinning.
void main() {
  late WidgetRef capturedRef;
  final controller = TextEditingController();

  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) =>
              DevShortcuts(navigatorKey: navigatorKey, child: child!),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return TextField(controller: controller);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  tearDown(() {
    T.setMode(AppThemeMode.classic);
    controller.clear();
  });

  testWidgets('t cycles the theme', (tester) async {
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();

    expect(capturedRef.read(themeModeProvider), isNot(AppThemeMode.classic));
  });

  testWidgets('t does not cycle while a text field has focus', (tester) async {
    await pump(tester);
    capturedRef.read(themeModeProvider.notifier).set(AppThemeMode.classic);
    await tester.pump();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(DevShortcuts.typing, isTrue, reason: 'field should hold focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();

    expect(
      capturedRef.read(themeModeProvider),
      AppThemeMode.classic,
      reason: 'typing in a field must not cycle the theme',
    );
  });

  testWidgets('the keystroke still reaches the field', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();

    // Entered through the text-input connection, the same route a real
    // keypress takes. The point is that a disabled action leaves the
    // field's own input path alone.
    await tester.enterText(find.byType(TextField), 'target');
    await tester.pump();

    expect(controller.text, 'target');
  });

  testWidgets('g opens the gallery and g again closes it', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pump(tester);
    // Focus starts on nothing, so the bare key is live.
    expect(ThemeGallery.isOpen, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    expect(find.text('Theme Gallery'), findsOneWidget);
    expect(ThemeGallery.isOpen, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    expect(find.text('Theme Gallery'), findsNothing);
    expect(ThemeGallery.isOpen, isFalse);
  });

  group('what each build binds', () {
    // Tests run in debug, so a widget test can only exercise the debug
    // map. These call the binding builder directly with each flag.
    const cycleKey = SingleActivator(LogicalKeyboardKey.keyT);
    const galleryKey = SingleActivator(LogicalKeyboardKey.keyG);

    test('a release build binds t but not g', () {
      final map = bindings(gallery: false);
      expect(map, contains(cycleKey), reason: 'the theme cycle ships');
      expect(
        map,
        isNot(contains(galleryKey)),
        reason: 'the gallery is debug-only',
      );
    });

    test('a debug build binds both', () {
      final map = bindings(gallery: true);
      expect(map, contains(cycleKey));
      expect(map, contains(galleryKey));
    });
  });
}
