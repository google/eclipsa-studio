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

// Pins the unsaved-changes question on exit (ES-844): the macOS Quit path
// and the window close both go through confirmExit, which stops the exit
// on Cancel or a Save that did not complete, and does not ask again once
// the exit is marked confirmed (the quit that follows a window close).

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/workspace/workspace_close.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session whose Save never completes, as when the Save panel is
/// cancelled.
class _SaveFails extends SessionNotifier {
  @override
  Future<bool> save() async => false;
}

void main() {
  late ProviderContainer container;
  late WidgetRef widgetRef;
  late BuildContext dialogContext;

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool dirty,
    bool saveFails = false,
  }) async {
    container = ProviderContainer(
      overrides: [if (saveFails) sessionProvider.overrideWith(_SaveFails.new)],
    );
    addTearDown(container.dispose);
    container.read(workspaceModeProvider.notifier).enterCreator();
    if (dirty) container.read(sessionProvider.notifier).markDirty();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              dialogContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  /// Starts [confirmExit], answers the prompt with [answer] if one
  /// appears, and returns the result and whether a prompt appeared.
  Future<(bool, bool)> exit(WidgetTester tester, String? answer) async {
    final result = confirmExit(dialogContext, widgetRef);
    await tester.pumpAndSettle();
    final asked = find.text('Unsaved Changes').evaluate().isNotEmpty;
    if (asked && answer != null) {
      await tester.tap(find.text(answer));
      await tester.pumpAndSettle();
    }
    return (await result, asked);
  }

  testWidgets('a clean session exits without asking', (tester) async {
    await pumpApp(tester, dirty: false);
    expect(await exit(tester, null), (true, false));
  });

  testWidgets('Cancel stops the exit, and the next exit asks again', (
    tester,
  ) async {
    await pumpApp(tester, dirty: true);
    expect(await exit(tester, 'Cancel'), (false, true));
    expect(container.read(exitConfirmedProvider), isFalse);
    expect(await exit(tester, 'Discard'), (true, true));
  });

  testWidgets('a confirmed exit is not asked again', (tester) async {
    await pumpApp(tester, dirty: true);
    // The window close asks, and Discard lets it go.
    expect(await exit(tester, 'Discard'), (true, true));
    // Nothing is marked until the window closes.
    expect(container.read(exitConfirmedProvider), isFalse);
    // _handleWindowClose marks it just before closing; the macOS
    // terminate request that follows then does not ask.
    markExitConfirmed(widgetRef);
    expect(await exit(tester, null), (true, false));
  });

  testWidgets('exitWouldPrompt matches whether confirmExit asks', (
    tester,
  ) async {
    await pumpApp(tester, dirty: false);
    expect(exitWouldPrompt(widgetRef), isFalse);
    container.read(sessionProvider.notifier).markDirty();
    expect(exitWouldPrompt(widgetRef), isTrue);
    markExitConfirmed(widgetRef);
    expect(exitWouldPrompt(widgetRef), isFalse);
  });

  testWidgets('Playback never prompts on exit', (tester) async {
    await pumpApp(tester, dirty: true);
    container.read(workspaceModeProvider.notifier).enterPlayback();
    expect(exitWouldPrompt(widgetRef), isFalse);
    expect(await exit(tester, null), (true, false));
  });

  testWidgets('a Save that does not complete stops the exit', (tester) async {
    await pumpApp(tester, dirty: true, saveFails: true);
    expect(await exit(tester, 'Save'), (false, true));
    expect(container.read(exitConfirmedProvider), isFalse);
  });

  // A second Quit while the prompt is open never reaches Dart on macOS:
  // AppDelegate answers it while a request is in flight (manual test).
  // This covers the dialog guard for two calls that do reach it.
  testWidgets('confirmExit while the prompt is open does not stack a '
      'second prompt', (tester) async {
    await pumpApp(tester, dirty: true);
    final first = confirmExit(dialogContext, widgetRef);
    await tester.pumpAndSettle();
    final second = confirmExit(dialogContext, widgetRef);
    await tester.pumpAndSettle();
    expect(find.text('Unsaved Changes'), findsOneWidget);
    expect(await second, isFalse);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(await first, isTrue);
  });
}
