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

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:eclipsa_studio/workspace/landing_screen.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoSessions extends RecentSessionsNotifier {
  @override
  List<String> build() => const [];
}

class _NoQcFiles extends RecentQcFilesNotifier {
  @override
  List<String> build() => const [];
}

/// When the landing screen shows, and the version pill in its corner
/// (ES-755, ES-757).
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  test('the landing screen does not show without the engine', () {
    final container = ProviderContainer(
      overrides: [
        engineLoadProvider.overrideWithValue(
          const EngineLoadResult.failure(
            EngineFailureKind.libraryNotLoaded,
            'test',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(landingVisibleProvider), isFalse);
  });

  group('the version pill', () {
    Future<void> pumpLanding(WidgetTester tester, AppThemeMode mode) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            recentSessionsProvider.overrideWith(_NoSessions.new),
            recentQcFilesProvider.overrideWith(_NoQcFiles.new),
            appVersionProvider.overrideWithValue('9.9.9'),
            landingVisibleProvider.overrideWithValue(true),
          ],
          child: const MaterialApp(home: LandingScreen()),
        ),
      );
      // Through the provider: its build applies the saved theme to T.
      ProviderScope.containerOf(
        tester.element(find.byType(LandingScreen)),
      ).read(themeModeProvider.notifier).set(mode);
      await tester.pump();
    }

    Finder pill() => find.ancestor(
      of: find.text('v9.9.9'),
      matching: find.byType(ChromePressable),
    );

    testWidgets('is a button named for the release notes', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLanding(tester, AppThemeMode.dark);
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Release Notes, version 9.9.9'),
        ),
        matchesSemantics(
          label: 'Release Notes, version 9.9.9',
          tooltip: 'Release Notes',
          isButton: true,
          hasTapAction: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('draws RaisedFace in Light and not elsewhere', (tester) async {
      for (final mode in AppThemeMode.values) {
        await pumpLanding(tester, mode);
        expect(
          find.descendant(of: pill(), matching: find.byType(RaisedFace)),
          mode == AppThemeMode.light ? findsOneWidget : findsNothing,
          reason: mode.name,
        );
      }
    });
  });
}
