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

// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Regenerate with `./build.sh gen-tokens` (macOS) or
// `.\build.ps1 gen-tokens` (Windows). The source of truth is
// app/design/tokens/themes.json and the DTCG token files beside it.
// Editing this file directly will be overwritten, and CI fails
// the build if it drifts from the tokens.

import 'package:flutter/material.dart';

import 'theme_data.dart';

/// Visual role of a theme. Drives Material [Brightness].
/// Decoupled from [AppThemeMode] so several themes can share
/// one role.
enum AppThemeRole { dark, light, highContrast }

/// The themes the app ships. Persisted by `.name`, so these
/// names are a storage format and must not change once
/// shipped. Reordering is safe.
enum AppThemeMode { dark, light, classic, highContrast }

/// Descriptive metadata for one theme.
class AppThemeMeta {
  const AppThemeMeta({
    required this.id,
    required this.label,
    required this.role,
  });

  /// Stable identifier. Never changes once shipped.
  final String id;

  /// Human-readable name shown in Settings. Safe to rename.
  final String label;

  /// Drives Brightness.
  final AppThemeRole role;
}

const Map<AppThemeMode, AppThemeMeta> kThemeMeta = {
  AppThemeMode.dark: AppThemeMeta(
    id: 'dark',
    label: 'Dark',
    role: AppThemeRole.dark,
  ),
  AppThemeMode.light: AppThemeMeta(
    id: 'light',
    label: 'Light',
    role: AppThemeRole.light,
  ),
  AppThemeMode.classic: AppThemeMeta(
    id: 'classic',
    label: 'Classic',
    role: AppThemeRole.dark,
  ),
  AppThemeMode.highContrast: AppThemeMeta(
    id: 'high-contrast',
    label: 'High Contrast',
    role: AppThemeRole.highContrast,
  ),
};

/// Dark, the default theme: the full-contrast dark colour concept. Dark grounds with a purple accent, a pink secondary accent and a lit tab underline; the values are the ones the app draws and the contrast gate in contrast.json checks them.
const AppThemeData kThemeDark = AppThemeData(
  bgDeep: Color(0xFF0D0D10), // deepest (timeline, 3D scene)
  bgBase: Color(0xFF101010), // panels, sidebars
  landingGroundTop: Color(0xFF101010), // landing screen ground, top edge
  landingGroundBottom: Color(0xFF101010), // landing screen ground, bottom edge
  bgSurface: Color(0xFF16181B), // cards, elevated panels
  bgElevated: Color(0xFF1B1A1C), // dialogs, popovers
  bgHover: Color(0xFF2B2929), // hover state
  bgControls: Color(0xFF232222), // buttons, inputs
  border: Color(0xFF3C3D50), // default border
  borderLight: Color(0xFF2D2B32), // light separator
  borderStrong: Color(0xFF3F4054), // strong border (focused)
  purple: Color(0xFFAA83F6), // primary accent
  pink: Color(0xFFE06090),
  purpleLight: Color(0xFFB490FF), // active state / highlight
  purpleDim: Color(0xFF2C233C), // subtle accent bg
  accentFg: Color(0xFFFFFFFF), // white over the purple→pink gradient
  accentFill: Color(0xFFAA83F6), // the fill of an affirmative AppButton
  accentInk: Color(0xFF101010),
  typeObject: Color(0xFF34D399), // emerald
  typeChannel: Color(0xFFAA83F6), // channel elements - the accent in this theme
  typeScene: Color(0xFF818CF8), // indigo
  objCyan: Color(0xFF67E8F9),
  objGreen: Color(0xFF6EE7B7),
  objAmber: Color(0xFFFCD34D),
  axisX: Color(0xFFFF6B6B),
  axisY: Color(0xFF5BE37A),
  axisZ: Color(0xFF5B9BFF),
  gizmoBg: Color(0x99000000), // 60% black — contrast vs dark scene
  pastEndScrim: Color(0x14FFFFFF), // 8% white haze over dark tracks
  indicatorGreen: Color(0xFF35C759), // matches the theme green
  meterGreen: Color(0xFF35C759),
  meterYellow: Color(0xFFFAC800),
  meterAmber: Color(0xFFFF9500),
  meterRed: Color(0xFFFF5C60), // Correlation heatmap (−1 → 0 → +1)
  corrNeg: Color(0xFF4A89E8),
  corrZero: Color(0xFFE0E0E0),
  corrPos: Color(0xFFE85C5C), // Text: cool silver hierarchy
  textPrimary: Color(0xFFE3E1F2), // headings, primary
  textSecondary: Color(0xFFC8C7C7), // labels, descriptions
  textTertiary: Color(0xFF98919E), // inactive, disabled
  textMuted: Color(0xFF898989), // subtle labels
  textGhost: Color(0xFF677283), // barely visible (grid lines)
  bgSelected: Color(0xFF372E46), // selected row/card bg
  textValue: Color(0xFFA7A7A7), // numeric readouts
  textValueDim: Color(0xFF848484), // secondary values
  textInactive: Color(0xFF606265), // inactive controls
  white: Color(0xFFFFFFFF),
  errorRed: Color(0xFFDC2626),
  uiFamily: 'Inter', // UI text face
  monoFamily: 'JetBrains Mono', // numeric readouts: time, dB, sample rates
  radius: 8.0, // large surfaces: dialogs, cards
  radiusSm: 6.0, // controls, chips, wells - the common one
  radiusMd: 6.0, // grouped panels
  borderWidth: 1.0, // hairline width used by the decoration builders
  knobStyle: KnobStyle.brushed, // which knob drawing this theme uses
  chromeStyle: ChromeStyle.beveled, // which top chrome this theme draws
  chromeBg: Color(0xFF262523), // ground of the top bar
  chromeHi: Color(0xFF302E2F), // centre of the beveled chrome's radial gradient
  chromeInk: Color(0xFFC8C7C7), // text on the chrome ground: labels, the clock
  chromeTabOn: Color(0xFFAA83F6), // the active workspace tab
  chromeTabOff: Color(0xFFC8C7C7), // an inactive workspace tab
  chromeRim: Color(0xFF2D2B32),
  chromeRimDark: Color(0xFF3C3D50),
  chromeRimLight: Color(0xFF3F4054), // light rim inside chromeRimDark
  statusbarBg: Color(0xFF171615), // ground of the status bar
  statusbarHi: Color(0xFF1B1A19), // bottom of the status bar gradient
  rulerTick: Color(0xFF2D2B32), // the time ruler's tick marks
  rulerLabel: Color(0xFF98919E), // the time ruler's labels
  playhead: Color(0xFFE06090), // the playhead line and its head: the pink token
  videoInk: Color(0xFFF4BF38), // the video lane's metadata chip ink
  videoBg: Color(0xFF0F0F11), // ground of the video strip
  videoHi: Color(0xFF221F24), // centre of the video strip radial lift
  trackPanelBg: Color(0xFF181716), // Elements track panel column ground
  gutterBg: Color(0xFF1D1B1B), // timeline scroll and zoom gutters
  controlStyle: ControlStyle.filled, // which dropdown control this theme draws
  cardStyle: CardStyle.floating, // which landing card this theme draws
  controlBg: Color(0xFF1B1A1C),
  controlFg: Color(0xFFFFFFFF),
);

/// Light: a light chrome bar with raised buttons over light work areas. The body's grounds, borders and text are one warm grey ramp extended from the chrome family; the values are the ones the app draws and the contrast gate in contrast.json checks them.
const AppThemeData kThemeLight = AppThemeData(
  bgDeep: Color(0xFFCFCBC5), // deepest (timeline, 3D scene)
  bgBase: Color(0xFFDAD7D1), // panels, sidebars
  landingGroundTop: Color(0xFFE4E5E6), // landing screen ground, top edge
  landingGroundBottom: Color(0xFFD4D5D6), // landing screen ground, bottom edge
  bgSurface: Color(0xFFE7E4DF), // cards, elevated panels
  bgElevated: Color(0xFFF0EDE8), // dialogs, popovers
  bgHover: Color(0xFFC7C3BC), // hover state
  bgControls: Color(0xFFF7F5F1), // buttons, inputs
  border: Color(0xFFBDB9B2), // default border
  borderLight: Color(0xFFD3CFC8), // light separator
  borderStrong: Color(0xFF8A8680), // strong border (focused)
  purple: Color(0xFF3D66B0), // primary accent
  pink: Color(0xFFB93C6F),
  purpleLight: Color(0xFF2E56A0), // active state / highlight
  purpleDim: Color(0xFFC4D2E9), // subtle accent bg
  accentFg: Color(0xFFFFFFFF), // white over the accent
  accentFill: Color(0xFF3D66B0), // the fill of an affirmative AppButton
  accentInk: Color(0xFFFFFFFF),
  typeObject: Color(0xFF1E8A5A), // emerald
  typeChannel: Color(0xFF9E6212), // amber
  typeScene: Color(0xFF4C4FB8), // indigo
  objCyan: Color(0xFF0E7490),
  objGreen: Color(0xFF15803D),
  objAmber: Color(0xFFB45309),
  axisX: Color(0xFFC93A3A),
  axisY: Color(0xFF1F8A4E),
  axisZ: Color(0xFF2F5FCB),
  gizmoBg: Color(0xAA000000), // 67% black: contrast vs the light scene
  pastEndScrim: Color(0x24000000), // 14% black haze over light tracks
  indicatorGreen: Color(0xFF1B8A46), // the running indicator
  meterGreen: Color(0xFF178C42),
  meterYellow: Color(0xFF9C6208),
  meterAmber: Color(0xFFB24A0B),
  meterRed: Color(0xFFC93737), // Correlation heatmap (−1 → 0 → +1)
  corrNeg: Color(0xFF3A73C8),
  corrZero: Color(0xFFC9C5BE),
  corrPos: Color(0xFFD04848), // Text: cool silver hierarchy
  textPrimary: Color(0xFF2F2D29), // headings, primary
  textSecondary: Color(0xFF57544D), // labels, descriptions
  textTertiary: Color(0xFF6B675F), // inactive, disabled
  textMuted: Color(0xFF767269), // subtle labels
  textGhost: Color(0xFFB8B3AC), // barely visible (grid lines)
  bgSelected: Color(0xFFB4C7E6), // selected row/card bg
  textValue: Color(0xFF2F2D29), // numeric readouts
  textValueDim: Color(0xFF57544D), // secondary values
  textInactive: Color(0xFF8A867E), // inactive controls
  white: Color(0xFFFFFFFF),
  errorRed: Color(0xFFB84545),
  uiFamily: 'Inter', // UI text face
  monoFamily: 'JetBrains Mono', // numeric readouts: time, dB, sample rates
  radius: 8.0, // large surfaces: dialogs, cards
  radiusSm: 6.0, // controls, chips, wells - the common one
  radiusMd: 6.0, // grouped panels
  borderWidth: 1.0, // hairline width used by the decoration builders
  knobStyle: KnobStyle.knobA, // which knob drawing this theme uses
  chromeStyle: ChromeStyle.raised, // which top chrome this theme draws
  chromeBg: Color(0xFFE7E4DF), // ground of the top bar
  chromeHi: Color(0xFFE7E4DF), // centre of the beveled chrome's radial gradient
  chromeInk: Color(0xFF44413C), // text on the chrome ground: labels, the clock
  chromeTabOn: Color(0xFF2E56A0), // the active workspace tab
  chromeTabOff: Color(0xFF818181), // an inactive workspace tab
  chromeRim: Color(0xFFC0BDB7),
  chromeRimDark: Color(0xFF3B3A36),
  chromeRimLight: Color(0xFFF9F5EF), // light rim inside chromeRimDark
  statusbarBg: Color(0xFFE7E4DF), // ground of the status bar
  statusbarHi: Color(0xFFE7E4DF), // bottom of the status bar gradient
  rulerTick: Color(0xFFB8B3AC), // the time ruler's tick marks
  rulerLabel: Color(0xFF57544D), // the time ruler's labels
  playhead: Color(0xFFB84545), // the playhead line and its head
  videoInk: Color(0xFF44413C), // the video lane's metadata chip ink
  videoBg: Color(0xFFDAD7D1), // ground of the video strip
  videoHi: Color(0xFFE2DFD9), // centre of the video strip radial lift
  trackPanelBg: Color(0xFFCFCBC5), // Elements track panel column ground
  gutterBg: Color(0xFFDAD7D1), // timeline scroll and zoom gutters
  controlStyle: ControlStyle.filled, // which dropdown control this theme draws
  cardStyle: CardStyle.chrome, // which landing card this theme draws
  controlBg: Color(0xFFF0EDE8),
  controlFg: Color(0xFF2F2D29),
);

/// Classic. Meant to resemble classic field recording instruments: graphite-blue with matte chrome, wells sunk into the panel for the transport, the clock and the dropdown, a bar knob in the same well and a violet accent.
const AppThemeData kThemeClassic = AppThemeData(
  bgDeep: Color(0xFF0B0E14), // deepest (timeline, 3D scene)
  bgBase: Color(0xFF10141B), // panels, sidebars
  landingGroundTop: Color(0xFF10141B), // landing screen ground, top edge
  landingGroundBottom: Color(0xFF10141B), // landing screen ground, bottom edge
  bgSurface: Color(0xFF151A22), // cards, elevated panels
  bgElevated: Color(0xFF1A202A), // dialogs, popovers
  bgHover: Color(0xFF222937), // hover state
  bgControls: Color(0xFF0C0F15), // buttons, inputs
  border: Color(0xFF262D3A), // default border
  borderLight: Color(0xFF202733), // light separator
  borderStrong: Color(0xFF3A4658), // strong border (focused)
  purple: Color(0xFF7C4DFF), // primary accent
  pink: Color(0xFFE06090),
  purpleLight: Color(0xFFA98BFF), // active state / highlight
  purpleDim: Color(0x2B7C4DFF), // subtle accent bg
  accentFg: Color(0xFFFFFFFF), // white over the purple→pink gradient
  accentFill: Color(0xFF7C4DFF), // the fill of an affirmative AppButton
  accentInk: Color(0xFFFFFFFF),
  typeObject: Color(0xFF34D399), // emerald
  typeChannel: Color(0xFFFBBF24), // amber
  typeScene: Color(0xFF818CF8), // indigo
  objCyan: Color(0xFF67E8F9),
  objGreen: Color(0xFF6EE7B7),
  objAmber: Color(0xFFFCD34D),
  axisX: Color(0xFFFF6B6B),
  axisY: Color(0xFF5BE37A),
  axisZ: Color(0xFF5B9BFF),
  gizmoBg: Color(0x99000000), // 60% black — contrast vs dark scene
  pastEndScrim: Color(0x14FFFFFF), // 8% white haze over dark tracks
  indicatorGreen: Color(0xFF34D399), // matches typeObject in dark
  meterGreen: Color(0xFF22C55E),
  meterYellow: Color(0xFFEAB308),
  meterAmber: Color(0xFFF97316),
  meterRed: Color(0xFFEF4444), // Correlation heatmap (−1 → 0 → +1)
  corrNeg: Color(0xFF4A89E8),
  corrZero: Color(0xFFE0E0E0),
  corrPos: Color(0xFFE85C5C), // Text: cool silver hierarchy
  textPrimary: Color(0xFFE2E6EE), // headings, primary
  textSecondary: Color(0xFF97A3BA), // labels, descriptions
  textTertiary: Color(0xFF8190AA), // inactive, disabled
  textMuted: Color(0xFF6B7A99), // subtle labels
  textGhost: Color(0xFF38435A), // barely visible (grid lines)
  bgSelected: Color(0xFF1C2140), // selected row/card bg
  textValue: Color(0xFFCBD1E2), // numeric readouts
  textValueDim: Color(0xFF8A94AA), // secondary values
  textInactive: Color(0xFF56647A), // inactive controls
  white: Color(0xFFFFFFFF),
  errorRed: Color(0xFFDC2626),
  uiFamily: 'Inter', // UI text face
  monoFamily: 'JetBrains Mono', // numeric readouts: time, dB, sample rates
  radius: 8.0, // large surfaces: dialogs, cards
  radiusSm: 4.0, // controls, chips, wells - the common one
  radiusMd: 6.0, // grouped panels
  borderWidth: 1.0, // hairline width used by the decoration builders
  knobStyle: KnobStyle.bar, // which knob drawing this theme uses
  chromeStyle: ChromeStyle.recessed, // which top chrome this theme draws
  chromeBg: Color(0xFF151A22), // ground of the top bar
  chromeHi: Color(0xFF151A22), // centre of the beveled chrome's radial gradient
  chromeInk: Color(0xFF97A3BA), // text on the chrome ground: labels, the clock
  chromeTabOn: Color(0xFFE2E6EE), // the active workspace tab
  chromeTabOff: Color(0xFF8190AA), // an inactive workspace tab
  chromeRim: Color(0xFF202733),
  chromeRimDark: Color(0xFF080A0F),
  chromeRimLight: Color(0xFF2A3342), // light rim inside chromeRimDark
  statusbarBg: Color(0xFF0B0E14), // ground of the status bar
  statusbarHi: Color(0xFF0B0E14), // bottom of the status bar gradient
  rulerTick: Color(0xFF38435A), // the time ruler's tick marks
  rulerLabel: Color(0xFF8190AA), // the time ruler's labels
  playhead: Color(0xFFE06090), // the playhead line and its head: the pink token
  videoInk: Color(0xFF67E8F9), // the video lane's metadata chip ink
  videoBg: Color(0xFF10141B), // ground of the video strip
  videoHi: Color(0xFF10141B), // centre of the video strip radial lift
  trackPanelBg: Color(0xFF151A22), // Elements track panel column ground
  gutterBg: Color(0xFF151A22), // timeline scroll and zoom gutters
  controlStyle: ControlStyle.well, // which dropdown control this theme draws
  cardStyle: CardStyle.flat, // which landing card this theme draws
  controlBg: Color(0xFF0C0F15),
  controlFg: Color(0xFFCBD1E2),
);

/// High Contrast: black, white and one lavender interaction accent, 8 px corners on large surfaces and 6 px on controls, 2 px strokes, no gradient and no shadow. Every gated pair is at or above 4.5:1.
const AppThemeData kThemeHighContrast = AppThemeData(
  bgDeep: Color(0xFF000000),
  bgBase: Color(0xFF000000),
  landingGroundTop: Color(0xFF000000), // landing screen ground, top edge
  landingGroundBottom: Color(0xFF000000), // landing screen ground, bottom edge
  bgSurface: Color(0xFF0A0A0A),
  bgElevated: Color(0xFF121212),
  bgHover: Color(0xFF1F1F1F),
  bgControls: Color(0xFF000000),
  border: Color(0xFFA0A0A0),
  borderLight: Color(0xFF5C5C5C),
  borderStrong: Color(0xFFFFFFFF),
  purple: Color(0xFFC4A0FF),
  pink: Color(0xFFED6C9C),
  purpleLight: Color(0xFFD9C2FF),
  purpleDim: Color(0x33C4A0FF),
  accentFg: Color(0xFF000000), // text/icons over a purple fill
  accentFill: Color(0xFFC4A0FF), // the fill of an affirmative AppButton
  accentInk: Color(0xFF000000),
  typeObject: Color(0xFF4ADE80),
  typeChannel: Color(0xFFFBBF24),
  typeScene: Color(0xFFA5B4FC),
  objCyan: Color(0xFF67E8F9),
  objGreen: Color(0xFF6EE7B7),
  objAmber: Color(0xFFFDE68A),
  axisX: Color(0xFFFF8080),
  axisY: Color(0xFF80FFA0),
  axisZ: Color(0xFF80B4FF),
  gizmoBg: Color(0xCC000000), // 80% black for strong HC contrast
  pastEndScrim: Color(0x26FFFFFF), // 15% white — strong HC signal
  indicatorGreen: Color(0xFF4ADE80),
  meterGreen: Color(0xFF4ADE80),
  meterYellow: Color(0xFFFFD60A),
  meterAmber: Color(0xFFFF9F0A),
  meterRed: Color(0xFFFF4D4D),
  corrNeg: Color(0xFF80B4FF),
  corrZero: Color(0xFFCCCCCC),
  corrPos: Color(0xFFF87171),
  textPrimary: Color(0xFFFFFFFF),
  textSecondary: Color(0xFFE8E8E8),
  textTertiary: Color(0xFFBFBFBF),
  textMuted: Color(0xFFA6A6A6),
  textGhost: Color(0xFF808080),
  bgSelected: Color(0xFF2A2A2A),
  textValue: Color(0xFFFFFFFF),
  textValueDim: Color(0xFFBFBFBF),
  textInactive: Color(0xFF8A8A8A),
  white: Color(0xFFFFFFFF),
  errorRed: Color(0xFFFF4D4D),
  uiFamily: 'Inter', // UI text face
  monoFamily: 'JetBrains Mono', // numeric readouts: time, dB, sample rates
  radius: 8.0, // large surfaces: dialogs, cards
  radiusSm: 6.0, // controls, chips, wells - the common one
  radiusMd: 6.0, // grouped panels
  borderWidth: 2.0, // hairline width used by the decoration builders
  knobStyle: KnobStyle.outlined, // which knob drawing this theme uses
  chromeStyle: ChromeStyle.outlined, // which top chrome this theme draws
  chromeBg: Color(0xFF000000), // ground of the top bar
  chromeHi: Color(0xFF000000), // centre of the beveled chrome's radial gradient
  chromeInk: Color(0xFFE8E8E8), // text on the chrome ground: labels, the clock
  chromeTabOn: Color(0xFFC4A0FF), // the active workspace tab
  chromeTabOff: Color(0xFFE8E8E8), // an inactive workspace tab
  chromeRim: Color(0xFFA0A0A0),
  chromeRimDark: Color(0xFF5C5C5C),
  chromeRimLight: Color(0xFFFFFFFF), // light rim inside chromeRimDark
  statusbarBg: Color(0xFF000000), // ground of the status bar
  statusbarHi: Color(0xFF000000), // bottom of the status bar gradient
  rulerTick: Color(0xFFA0A0A0), // the time ruler's tick marks
  rulerLabel: Color(0xFFE8E8E8), // the time ruler's labels
  playhead: Color(0xFFFFD60A), // the playhead line and its head
  videoInk: Color(0xFF67E8F9), // the video lane's metadata chip ink
  videoBg: Color(0xFF000000), // ground of the video strip
  videoHi: Color(0xFF000000), // centre of the video strip radial lift
  trackPanelBg: Color(0xFF0A0A0A), // Elements track panel column ground
  gutterBg: Color(0xFF0A0A0A), // timeline scroll and zoom gutters
  controlStyle: ControlStyle.outlined,
  cardStyle: CardStyle.outlined, // which landing card this theme draws
  controlBg: Color(0xFF000000),
  controlFg: Color(0xFFFFFFFF),
);

/// The [AppThemeData] for [mode].
AppThemeData themeDataFor(AppThemeMode mode) => switch (mode) {
  AppThemeMode.dark => kThemeDark,
  AppThemeMode.light => kThemeLight,
  AppThemeMode.classic => kThemeClassic,
  AppThemeMode.highContrast => kThemeHighContrast,
};

/// Resolve a persisted theme name (the token id or the enum
/// name) to a mode. Returns null if unrecognised, so callers
/// choose their own fallback.
AppThemeMode? themeModeFromId(String id) {
  for (final entry in kThemeMeta.entries) {
    if (entry.value.id == id || entry.key.name == id) {
      return entry.key;
    }
  }
  return null;
}
