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

// Pins the launch safety notice (ES-634): when it is due, its copy,
// that Esc and a
// barrier tap leave it open, that Enter accepts, and what each button
// returns with and without the checkbox.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/session/app_preferences.dart';
import 'package:eclipsa_studio/widgets/app_dialog.dart';
import 'package:eclipsa_studio/widgets/safety_notice_dialog.dart';

Future<Future<SafetyNoticeChoice?>> _open(WidgetTester tester) async {
  // A desktop-sized surface: the default 800×600 is shorter than the
  // three paragraphs under the wide test font.
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  late Future<SafetyNoticeChoice?> result;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = showAppDialog<SafetyNoticeChoice>(
                  context: context,
                  escape: DialogEscape.none,
                  builder: (_) => const SafetyNoticeDialog(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('safetyNoticeDue', () {
    test('is due on a fresh install', () {
      expect(safetyNoticeDue({}), isTrue);
      expect(
        safetyNoticeDue({AppPreferences.kSafetyNoticeSuppressedRevision: null}),
        isTrue,
      );
    });

    test('is not due once suppressed for the current revision', () {
      expect(
        safetyNoticeDue({
          AppPreferences.kSafetyNoticeSuppressedRevision: kSafetyNoticeRevision,
        }),
        isFalse,
      );
    });

    test('is due again after a revision bump', () {
      expect(
        safetyNoticeDue({
          AppPreferences.kSafetyNoticeSuppressedRevision:
              kSafetyNoticeRevision - 1,
        }),
        isTrue,
      );
    });
  });

  testWidgets('shows the notice copy', (tester) async {
    await _open(tester);
    expect(find.text('Listening safety'), findsOneWidget);
    for (final paragraph in kSafetyNoticeBody) {
      expect(find.text(paragraph), findsOneWidget);
    }
    expect(find.text("Don't show this again"), findsOneWidget);
    expect(find.text('I understand'), findsOneWidget);
    expect(find.text('Quit'), findsOneWidget);
  });

  testWidgets('Esc and a barrier tap leave it open', (tester) async {
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('Listening safety'), findsOneWidget);
  });

  testWidgets('Enter accepts, unsuppressed by default', (tester) async {
    final result = await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, (accepted: true, suppress: false));
  });

  testWidgets('I understand with the checkbox ticked suppresses', (
    tester,
  ) async {
    final result = await _open(tester);
    await tester.tap(find.text("Don't show this again"));
    await tester.pump();
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    expect(await result, (accepted: true, suppress: true));
  });

  testWidgets('Quit returns not accepted', (tester) async {
    final result = await _open(tester);
    await tester.tap(find.text('Quit'));
    await tester.pumpAndSettle();
    expect((await result)!.accepted, isFalse);
  });
}
