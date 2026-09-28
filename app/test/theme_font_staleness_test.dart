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

// Pins the const-skip rule (ES-507): a widget that reads `T.*` and is
// constructed as `const` never gets a rebuild from its parent, because
// the canonical instance is identical across parent builds and
// `Element.updateChild` short-circuits. Such a widget must watch
// `themeModeProvider` and `fontSizeModeProvider` itself, or it stays
// on the old theme and font size after a switch.
//
// The subjects below are const-constructed under a parent that never
// rebuilds, so the only path to a fresh build() is the widget's own
// watch. Each is asserted twice: a theme switch changes its colour and
// a font-mode switch changes its text size.

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/eyebrow_label.dart';
import 'package:eclipsa_studio/widgets/remove_x_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void _noop() {}

/// The widgets under test, each a canonical const instance, and the
/// Text each one draws. Adding a self-tracking widget here pins it.
const List<Widget> _subjects = [
  EyebrowLabel('Section'),
  RemoveXButton(onTap: _noop),
];

const Map<String, String> _textOf = {
  'EyebrowLabel': 'SECTION',
  'RemoveXButton': '✕',
};

void main() {
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Column(children: _subjects)),
        ),
      ),
    );
    await tester.pump();
  }

  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!;

  tearDown(() {
    T.setMode(T.defaultMode);
    T.setFontMode(FontSizeMode.medium);
  });

  for (final subject in _subjects) {
    final name = subject.runtimeType.toString();
    final text = _textOf[name]!;

    testWidgets('$name follows a theme switch', (tester) async {
      await pump(tester);
      container.read(themeModeProvider.notifier).set(AppThemeMode.dark);
      await tester.pump();
      final dark = styleOf(tester, text).color;

      container.read(themeModeProvider.notifier).set(AppThemeMode.light);
      await tester.pump();
      final light = styleOf(tester, text).color;

      expect(
        light,
        isNot(dark),
        reason: '$name kept its Dark colour after switching to Light',
      );
    });

    testWidgets('$name follows a font-mode switch', (tester) async {
      await pump(tester);
      container.read(fontSizeModeProvider.notifier).set(FontSizeMode.medium);
      await tester.pump();
      final medium = styleOf(tester, text).fontSize!;

      container.read(fontSizeModeProvider.notifier).set(FontSizeMode.large);
      await tester.pump();
      final large = styleOf(tester, text).fontSize!;

      expect(
        large,
        closeTo(medium * FontSizeMode.large.scale, 0.01),
        reason: '$name kept its Medium text size after switching to Large',
      );
    });
  }
}
