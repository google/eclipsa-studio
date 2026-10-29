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

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/eclipsa_audio_lockup.dart';
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

    // The cards are constructed const, so no LandingScreen rebuild
    // reaches them; they watch theme and font mode themselves. Both
    // switches happen after the first frame, so a card that missed one
    // keeps the previous theme's title ink or the previous title size.
    testWidgets('the cards follow a theme and a font-size switch', (
      tester,
    ) async {
      addTearDown(() => T.setFontMode(FontSizeMode.medium));
      for (final mode in AppThemeMode.values) {
        await pumpLanding(tester, mode);
        final expected = T.cardStyle == CardStyle.chrome
            ? T.chromeInk
            : T.textPrimary;
        for (final title in ['CREATOR', 'PLAYBACK']) {
          expect(
            tester.widget<Text>(find.text(title)).style!.color,
            expected,
            reason: '${mode.name}: $title',
          );
        }
      }

      final medium = T.fontTitle;
      ProviderScope.containerOf(
        tester.element(find.byType(LandingScreen)),
      ).read(fontSizeModeProvider.notifier).set(FontSizeMode.large);
      await tester.pump();
      expect(T.fontTitle, greaterThan(medium));
      for (final title in ['CREATOR', 'PLAYBACK']) {
        expect(
          tester.widget<Text>(find.text(title)).style!.fontSize,
          T.fontTitle,
          reason: '$title at Large',
        );
      }
    });

    // The caption sits somewhere on the gradient, depending on the
    // window height, so it has to clear 4.5:1 on both ends. The ink is
    // textSecondary, which contrast.json gates on landingGroundBottom;
    // this pins the caption to that token and checks both ends here.
    testWidgets('the Authoring for caption clears 4.5:1 on both ends of '
        'the ground in every theme', (tester) async {
      for (final mode in AppThemeMode.values) {
        await pumpLanding(tester, mode);
        final ink = tester
            .widget<Text>(find.text('Authoring for'))
            .style!
            .color!;
        expect(ink, T.textSecondary, reason: mode.name);
        for (final (end, ground) in [
          ('landingGroundTop', T.landingGroundTop),
          ('landingGroundBottom', T.landingGroundBottom),
        ]) {
          expect(
            _contrast(ink, ground),
            greaterThanOrEqualTo(4.5),
            reason: '${mode.name}: caption on $end',
          );
        }
      }
    });

    testWidgets('the Eclipsa Audio lockup takes the colourway of the '
        'landing ground, the same at both ends', (tester) async {
      for (final mode in AppThemeMode.values) {
        await pumpLanding(tester, mode);
        final top = EclipsaAudioColorway.forGround(T.landingGroundTop);
        expect(
          EclipsaAudioColorway.forGround(T.landingGroundBottom),
          top,
          reason: '${mode.name}: the two ends pick different colourways',
        );
        expect(
          tester
              .widget<EclipsaAudioLockup>(find.byType(EclipsaAudioLockup))
              .colorway,
          top,
          reason: mode.name,
        );
      }
    });
  });
}

/// WCAG 2.x contrast ratio of two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
