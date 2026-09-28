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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Guards the generated token layer. The drift check that `theme_tokens.dart`
// still matches `app/design/tokens/` lives in the generator (`build.sh
// gen-tokens --check`); this covers the parts a Python diff can't see: that
// the registry stays wired to the enum, that persistence round-trips, and
// that class T forwards to the generated data.
void main() {
  group('theme registry', () {
    test('every mode has metadata, and ids are unique and stable', () {
      expect(kThemeMeta.length, AppThemeMode.values.length);
      for (final mode in AppThemeMode.values) {
        expect(kThemeMeta[mode], isNotNull, reason: 'no meta for $mode');
      }
      final ids = kThemeMeta.values.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate theme id');
    });

    test('every theme carries its shipped name', () {
      // The label is what Settings, the status bar and the gallery
      // show.
      expect(kThemeMeta[AppThemeMode.dark]!.label, 'Dark');
      expect(kThemeMeta[AppThemeMode.light]!.label, 'Light');
      expect(kThemeMeta[AppThemeMode.classic]!.label, 'Classic');
      expect(kThemeMeta[AppThemeMode.highContrast]!.label, 'High Contrast');
    });

    test('the enum is in the registry order, Dark first', () {
      // Settings, the status bar cycle and the gallery all iterate
      // AppThemeMode.values, so the registry's order is the order the
      // user sees. D leads because it is the default.
      expect(AppThemeMode.values, [
        AppThemeMode.dark,
        AppThemeMode.light,
        AppThemeMode.classic,
        AppThemeMode.highContrast,
      ]);
      expect(T.defaultMode, AppThemeMode.dark);
    });

    test('each mode resolves to its own theme data', () {
      expect(T.themeFor(AppThemeMode.light), same(kThemeLight));
      expect(T.themeFor(AppThemeMode.dark), same(kThemeDark));
      expect(T.themeFor(AppThemeMode.classic), same(kThemeClassic));
      expect(T.themeFor(AppThemeMode.highContrast), same(kThemeHighContrast));
    });

    test('roles drive brightness, not the enum identity', () {
      expect(kThemeMeta[AppThemeMode.classic]!.role, AppThemeRole.dark);
      expect(
        kThemeMeta[AppThemeMode.highContrast]!.role,
        AppThemeRole.highContrast,
      );
      expect(kThemeMeta[AppThemeMode.dark]!.role, AppThemeRole.dark);
      expect(kThemeMeta[AppThemeMode.light]!.role, AppThemeRole.light);
    });
  });

  group('persistence', () {
    test('every enum name round-trips through themeModeFromId', () {
      for (final mode in AppThemeMode.values) {
        expect(themeModeFromId(mode.name), mode);
      }
    });

    test('the names and the ids resolve, nothing else', () {
      // The theme setting is stored as the enum name; the id names the
      // token file and the golden images. No older spelling resolves.
      expect(themeModeFromId('dark'), AppThemeMode.dark);
      expect(themeModeFromId('light'), AppThemeMode.light);
      expect(themeModeFromId('classic'), AppThemeMode.classic);
      expect(themeModeFromId('high-contrast'), AppThemeMode.highContrast);
      expect(themeModeFromId('highContrast'), AppThemeMode.highContrast);
      expect(themeModeFromId('themeD'), isNull);
      expect(themeModeFromId('d'), isNull);
      expect(themeModeFromId('conceptDColB'), isNull);
    });

    test('an unknown id returns null so callers pick their own fallback', () {
      expect(themeModeFromId('solarized'), isNull);
      expect(themeModeFromId(''), isNull);
    });
  });

  group('class T forwards to the generated data', () {
    tearDown(() => T.setMode(T.defaultMode));

    test('themeFor resolves each mode to its generated const', () {
      expect(T.themeFor(AppThemeMode.classic), same(kThemeClassic));
      expect(T.themeFor(AppThemeMode.highContrast), same(kThemeHighContrast));
      expect(T.themeFor(AppThemeMode.dark), same(kThemeDark));
    });

    test('setMode swaps the values every T.* getter reads', () {
      T.setMode(AppThemeMode.classic);
      expect(T.bgBase, kThemeClassic.bgBase);
      T.setMode(AppThemeMode.highContrast);
      expect(T.bgBase, kThemeHighContrast.bgBase);
      expect(T.bgBase, isNot(kThemeClassic.bgBase));
    });

    test('brightness comes from the role', () {
      // Light carries the light role and is Brightness.light; the
      // dark and highContrast roles are both Brightness.dark.
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        expect(
          T.brightness,
          mode == AppThemeMode.light ? Brightness.light : Brightness.dark,
          reason: mode.name,
        );
      }
    });
  });

  group('typography', () {
    test('every theme names a family the app actually bundles', () {
      // The generator cross-checks these against pubspec.yaml, because
      // an undeclared family is the one failure Flutter does not report:
      // it silently substitutes the system face.
      // The set is pubspec.yaml's `fonts:` families: Inter and JetBrains
      // Mono, shared by every theme.
      const bundled = {'Inter', 'JetBrains Mono'};
      for (final mode in AppThemeMode.values) {
        final t = T.themeFor(mode);
        expect(bundled, contains(t.uiFamily), reason: '${mode.name} ui');
        expect(bundled, contains(t.monoFamily), reason: '${mode.name} mono');
      }
    });

    test('families are per-theme, and T forwards them', () {
      T.setMode(AppThemeMode.classic);
      expect(T.uiFamily, kThemeClassic.uiFamily);
      expect(T.monoFamily, kThemeClassic.monoFamily);
      T.setMode(AppThemeMode.highContrast);
      expect(T.uiFamily, kThemeHighContrast.uiFamily);
      T.setMode(AppThemeMode.classic);
    });

    test('every theme reads Inter and JetBrains Mono', () {
      for (final mode in AppThemeMode.values) {
        expect(T.themeFor(mode).uiFamily, 'Inter', reason: mode.name);
        expect(
          T.themeFor(mode).monoFamily,
          'JetBrains Mono',
          reason: mode.name,
        );
      }
    });
  });

  group('token values', () {
    test('the three alpha tokens kept their alpha through generation', () {
      // The only non-opaque tokens in the set. #RRGGBBAA -> 0xAARRGGBB
      // is the easiest conversion in the generator to get backwards, and
      // a silent full-alpha result would look plausible everywhere else.
      expect(kThemeClassic.gizmoBg.a, lessThan(1.0));
      expect(kThemeClassic.pastEndScrim.a, lessThan(1.0));
      expect(kThemeClassic.purpleDim.a, lessThan(1.0));
      expect(kThemeClassic.bgBase.a, 1.0);
    });

    test('chromeStyle: one per theme, and no two themes share one', () {
      // Each theme has its own chrome style: A recessed, C outlined,
      // D beveled, E raised.
      const expected = {
        AppThemeMode.classic: ChromeStyle.recessed,
        AppThemeMode.highContrast: ChromeStyle.outlined,
        AppThemeMode.dark: ChromeStyle.beveled,
        AppThemeMode.light: ChromeStyle.raised,
      };
      expect(expected.values.toSet().length, expected.length);
      for (final mode in AppThemeMode.values) {
        expect(
          T.themeFor(mode).chromeStyle,
          expected[mode],
          reason: '${mode.name} chromeStyle',
        );
      }
    });

    // The landing card was selected by chromeStyle until ES-699. It is its
    // own token so a theme that takes a raised top bar does not thereby
    // take Light's card ground.
    test(
      'cardStyle: chrome for Light, outlined for High Contrast, floating for Dark',
      () {
        const expected = {
          AppThemeMode.classic: CardStyle.flat,
          AppThemeMode.highContrast: CardStyle.outlined,
          AppThemeMode.dark: CardStyle.floating,
          AppThemeMode.light: CardStyle.chrome,
        };
        for (final mode in AppThemeMode.values) {
          expect(T.themeFor(mode).cardStyle, expected[mode], reason: mode.name);
        }
      },
    );

    test('controlStyle: filled for both concepts, well for A, outlined '
        'for C', () {
      const expected = {
        AppThemeMode.classic: ControlStyle.well,
        AppThemeMode.highContrast: ControlStyle.outlined,
        AppThemeMode.dark: ControlStyle.filled,
        AppThemeMode.light: ControlStyle.filled,
      };
      for (final mode in AppThemeMode.values) {
        expect(
          T.themeFor(mode).controlStyle,
          expected[mode],
          reason: mode.name,
        );
      }
    });

    test('the chrome heights are the same in every theme', () {
      // T.topbar and T.statusbar are static consts, because
      // a component's size does not vary by theme, only how it is drawn
      // and coloured.
      expect(T.topbar, 44);
      expect(T.statusbar, 28);
      for (final mode in AppThemeMode.values) {
        final t = T.themeFor(mode);
        if (t.chromeStyle != ChromeStyle.beveled) {
          expect(t.chromeHi, t.chromeBg, reason: '${mode.name} chromeHi');
        }
      }
      expect(kThemeDark.chromeHi, isNot(kThemeDark.chromeBg));
    });

    test('the video strip is a bgBase fill on a flat-ground chrome', () {
      // The recessed and outlined styles draw the strip body on the
      // page ground with no radial lift.
      for (final mode in AppThemeMode.values) {
        final t = T.themeFor(mode);
        if (!t.chromeStyle.flatGround) continue;
        expect(t.videoBg, t.bgBase, reason: '${mode.name} videoBg');
        expect(t.videoHi, t.bgBase, reason: '${mode.name} videoHi');
      }
      for (final t in [kThemeDark, kThemeLight]) {
        expect(
          t.videoHi,
          isNot(t.videoBg),
          reason: 'the Dark and Light themes lift',
        );
      }
    });

    test('the status bar is a bgDeep fill on a flat-ground chrome', () {
      // The recessed and outlined styles fill the bar with bgDeep and
      // no gradient. The height is the static const T.statusbar; only
      // the ground is per-theme.
      for (final mode in AppThemeMode.values) {
        final t = T.themeFor(mode);
        if (!t.chromeStyle.flatGround) continue;
        expect(t.statusbarBg, t.bgDeep, reason: '${mode.name} statusbarBg');
        expect(t.statusbarHi, t.bgDeep, reason: '${mode.name} statusbarHi');
      }
      // The Dark theme's bar is a gradient; the Light theme's is the
      // chrome's flat light fill.
      expect(kThemeDark.statusbarHi, isNot(kThemeDark.statusbarBg));
      expect(kThemeLight.statusbarBg, kThemeLight.chromeBg);
      expect(kThemeLight.statusbarHi, kThemeLight.chromeBg);
    });

    test('the Dark and Light themes set their own ruler, playhead and '
        'chip', () {
      // The Dark theme's ticks are borderLight and its playhead is
      // pink; the Light theme's playhead is a red that nothing else in
      // the theme uses.
      final d = kThemeDark;
      expect(d.rulerTick, d.borderLight);
      expect(d.rulerLabel, d.textTertiary);
      expect(d.playhead, d.pink);
      final e = kThemeLight;
      expect(e.rulerTick, e.textGhost);
      expect(e.rulerLabel, e.textSecondary);
      expect(e.playhead, const Color(0xFFB84545));
      // The video lane's chip: amber in the Dark theme, the chrome's
      // ink in the Light theme.
      expect(d.videoInk, const Color(0xFFF4BF38));
      expect(e.videoInk, e.chromeInk);
    });

    test('Light is light on the chrome and on the body', () {
      // Until ES-751 the theme was a light bar over a dark body
      // (bgBase #101010). The body is light now, and the bar stays
      // #E7E4DF.
      final e = T.themeFor(AppThemeMode.light);
      expect(e.chromeBg.computeLuminance(), greaterThan(0.7));
      expect(e.bgBase.computeLuminance(), greaterThan(0.5));
      expect(e.bgDeep.computeLuminance(), greaterThan(0.5));
      expect(e.bgElevated.computeLuminance(), greaterThan(0.5));
      expect(e.textPrimary.computeLuminance(), lessThan(0.05));
    });

    test('gizmoBg stays dark in every theme', () {
      // Documented invariant on the field: it scrims arbitrary 3D scenes,
      // so it must not follow bgDeep into white on the light theme.
      for (final mode in AppThemeMode.values) {
        final t = T.themeFor(mode);
        expect(
          t.gizmoBg.computeLuminance(),
          lessThan(0.2),
          reason: '${mode.name} gizmoBg is too light to scrim a 3D scene',
        );
      }
    });
  });

  group('decoration builders', () {
    // The three builders are the only place the shape tokens are
    // composed rather than read, and they are what moved when radii
    // became per-theme. Each is checked against the active theme's own
    // values, so a builder that reads the wrong token (decoCard on
    // radiusSm) or freezes on one theme's numbers fails here and says
    // which theme and which field.
    tearDown(() => T.setMode(T.defaultMode));

    double radiusOf(BoxDecoration d) =>
        (d.borderRadius! as BorderRadius).topLeft.x;

    for (final mode in AppThemeMode.values) {
      test('${mode.name} builders read that theme\'s shape tokens', () {
        T.setMode(mode);
        final t = T.themeFor(mode);

        final control = T.decoControl();
        expect(radiusOf(control), t.radiusSm);
        expect(control.color, t.bgControls);
        expect(control.border!.top.width, t.borderWidth);

        final card = T.decoCard();
        expect(radiusOf(card), t.radiusMd);
        expect(card.color, t.bgElevated);
        expect(card.border!.top.width, t.borderWidth);

        final inset = T.decoInset();
        expect(radiusOf(inset), t.radiusSm);
        expect(inset.color, t.bgDeep);
        expect(inset.border!.top.width, t.borderWidth);
      });
    }

    test('a theme with a different radiusSm actually changes the output', () {
      // concept-d-col-b and design-e both read radiusSm 6 off the
      // Dropdown component, against dark's 4. Without a case where the
      // values differ, the loop above would pass against a builder
      // frozen on one theme.
      expect(kThemeDark.radiusSm, isNot(kThemeClassic.radiusSm));
      T.setMode(AppThemeMode.classic);
      final darkRadius = radiusOf(T.decoControl());
      T.setMode(AppThemeMode.dark);
      expect(radiusOf(T.decoControl()), isNot(darkRadius));
    });
  });
}
