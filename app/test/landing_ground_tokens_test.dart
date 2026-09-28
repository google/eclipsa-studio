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

import 'dart:ui' as ui;

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/landing_glow.dart';
import 'package:eclipsa_studio/workspace/landing_ground.dart';
import 'package:eclipsa_studio/workspace/landing_screen.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// The landing screen's ground tokens (ES-757): Light draws a gradient,
/// the other themes a flat `bgBase`, and the landing screen is
/// transparent over the ground the app root paints.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  group('the ground pair per theme', () {
    test('Light runs from #E4E5E6 to #D4D5D6', () {
      final t = T.themeFor(AppThemeMode.light);
      expect(t.landingGroundTop, const Color(0xFFE4E5E6));
      expect(t.landingGroundBottom, const Color(0xFFD4D5D6));
    });

    for (final mode in [
      AppThemeMode.dark,
      AppThemeMode.classic,
      AppThemeMode.highContrast,
    ]) {
      test('${mode.name} is flat bgBase', () {
        final t = T.themeFor(mode);
        expect(t.landingGroundTop, t.bgBase);
        expect(t.landingGroundBottom, t.bgBase);
      });
    }
  });

  group('LandingGround', () {
    final key = GlobalKey();

    Future<void> pump(WidgetTester tester, AppThemeMode mode) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: RepaintBoundary(key: key, child: const LandingGround()),
          ),
        ),
      );
      ProviderScope.containerOf(
        tester.element(find.byType(LandingGround)),
      ).read(themeModeProvider.notifier).set(mode);
      await tester.pump();
    }

    Future<(int, int)> topAndBottomRed() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int red(int x, int y) => bytes.getUint8((y * image.width + x) * 4);
      return (red(0, 0), red(0, image.height - 1));
    }

    testWidgets('Light is #E4E5E6 at the top row and #D4D5D6 at the '
        'bottom row', (tester) async {
      await pump(tester, AppThemeMode.light);
      expect(find.byType(LandingGlow), findsNothing);
      await tester.runAsync(() async {
        final (top, bottom) = await topAndBottomRed();
        expect(top, closeTo(0xE4, 1));
        expect(bottom, closeTo(0xD4, 1));
      });
    });

    testWidgets('Classic and High Contrast render their flat pair', (
      tester,
    ) async {
      for (final mode in [AppThemeMode.classic, AppThemeMode.highContrast]) {
        await pump(tester, mode);
        expect(find.byType(LandingGlow), findsNothing, reason: mode.name);
        final base = (T.themeFor(mode).bgBase.r * 255).round();
        await tester.runAsync(() async {
          final (top, bottom) = await topAndBottomRed();
          expect(top, base, reason: mode.name);
          expect(bottom, base, reason: mode.name);
        });
      }
    });

    testWidgets('Dark paints the glow over its flat ground', (tester) async {
      await pump(tester, AppThemeMode.dark);
      expect(find.byType(LandingGlow), findsOneWidget);
      // The glow is transparent at the corners, so bgBase shows there.
      await tester.runAsync(() async {
        final (top, bottom) = await topAndBottomRed();
        expect(top, 0x10);
        expect(bottom, 0x10);
      });
    });
  });

  group('the landing screen', () {
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
      ProviderScope.containerOf(
        tester.element(find.byType(LandingScreen)),
      ).read(themeModeProvider.notifier).set(mode);
      await tester.pump();
    }

    Color scaffoldGround(WidgetTester tester) =>
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;

    testWidgets('is transparent over the ground in every theme', (
      tester,
    ) async {
      for (final mode in AppThemeMode.values) {
        await pumpLanding(tester, mode);
        expect(scaffoldGround(tester).a, 0, reason: mode.name);
      }
    });
  });
}
