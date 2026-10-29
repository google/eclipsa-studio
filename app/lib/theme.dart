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

import 'package:flutter/material.dart';

import 'logging/log.dart';
import 'theme_data.dart';
import 'theme_tokens.dart';

// The schema and the generated token values are part of this
// library's public face: every `import 'theme.dart'` in the app
// already expects AppThemeMode and AppThemeData to come with it.
export 'theme_data.dart';
export 'theme_tokens.dart';

/// Theme colour for an audio-element type, the one colour that stands for
/// the type wherever an element is drawn: its glyph, its Elements row and
/// waveform, and its sources in the 3D scene and the visualizers. A type
/// the session loader keeps but does not recognise takes the Channel
/// colour.
Color aeTypeColor(String type) {
  final t = type.toLowerCase();
  if (t.contains('object')) return T.typeObject;
  if (t.contains('scene')) return T.typeScene;
  return T.typeChannel;
}

/// Font size presets. Medium is the reference (1.0×); small and large scale
/// relative to it.
enum FontSizeMode {
  small('Small', 0.85),
  medium('Medium', 1.0),
  large('Large', 1.15);

  const FontSizeMode(this.label, this.scale);
  final String label;
  final double scale;
}

// ─────────────────────────────────────────────────────────────────────────────
// T — global theme accessor (static getters backed by swappable instance)
//
// All existing call sites (T.bgBase, T.purple, etc.) continue to work.
// CustomPainters read T at paint-time and pick up theme changes.
// ─────────────────────────────────────────────────────────────────────────────

class T {
  T._();

  /// The theme a fresh install opens in, and the one a stored
  /// preference that names no theme falls back to.
  static const AppThemeMode defaultMode = AppThemeMode.dark;

  static AppThemeData _current = kThemeDark;
  static AppThemeMode _mode = defaultMode;

  static AppThemeMode get mode => _mode;

  static void setMode(AppThemeMode mode) {
    Log.d(LogCat.app, 'Theme: ${_mode.name} → ${mode.name}');
    _mode = mode;
    _current = themeFor(mode);
  }

  static AppThemeData themeFor(AppThemeMode mode) => themeDataFor(mode);

  /// Metadata for the active theme — label, stable id, role.
  static AppThemeMeta get meta => kThemeMeta[_mode]!;

  /// Material brightness for the active theme, derived from its
  /// role so a new dark-role theme needs no code change here.
  static Brightness get brightness =>
      meta.role == AppThemeRole.light ? Brightness.light : Brightness.dark;

  // Backgrounds
  static Color get bgDeep => _current.bgDeep;
  static Color get bgBase => _current.bgBase;
  static Color get landingGroundTop => _current.landingGroundTop;
  static Color get landingGroundBottom => _current.landingGroundBottom;
  static Color get bgSurface => _current.bgSurface;
  static Color get bgElevated => _current.bgElevated;
  static Color get bgHover => _current.bgHover;
  static Color get bgControls => _current.bgControls;

  // Borders
  static Color get border => _current.border;
  static Color get borderLight => _current.borderLight;
  static Color get borderStrong => _current.borderStrong;

  // Accent
  static Color get purple => _current.purple;
  static Color get pink => _current.pink;
  static Color get purpleLight => _current.purpleLight;
  static Color get purpleDim => _current.purpleDim;
  static Color get accentFg => _current.accentFg;

  static Color get accentFill => _current.accentFill;
  static Color get accentInk => _current.accentInk;

  // Brand mark — see EclipsaStudioMark (widgets/eclipsa_studio_mark.dart).

  // Element types
  static Color get typeObject => _current.typeObject;
  static Color get typeChannel => _current.typeChannel;
  static Color get typeScene => _current.typeScene;

  // 3D objects
  static Color get objCyan => _current.objCyan;
  static Color get objGreen => _current.objGreen;
  static Color get objAmber => _current.objAmber;

  // 3D axes
  static Color get axisX => _current.axisX;
  static Color get axisY => _current.axisY;
  static Color get axisZ => _current.axisZ;
  static Color get gizmoBg => _current.gizmoBg;
  static Color get pastEndScrim => _current.pastEndScrim;

  // Indicators
  static Color get indicatorGreen => _current.indicatorGreen;

  // Meters
  static Color get meterGreen => _current.meterGreen;
  static Color get meterYellow => _current.meterYellow;
  static Color get meterAmber => _current.meterAmber;
  static Color get meterRed => _current.meterRed;

  // Correlation heatmap
  static Color get corrNeg => _current.corrNeg;
  static Color get corrZero => _current.corrZero;
  static Color get corrPos => _current.corrPos;

  // Text
  static Color get textPrimary => _current.textPrimary;
  static Color get textSecondary => _current.textSecondary;
  static Color get textTertiary => _current.textTertiary;
  static Color get textMuted => _current.textMuted;
  static Color get textGhost => _current.textGhost;

  // Selected / active surfaces
  static Color get bgSelected => _current.bgSelected;

  // Mono readout values
  static Color get textValue => _current.textValue;
  static Color get textValueDim => _current.textValueDim;
  static Color get textInactive => _current.textInactive;

  static Color get white => _current.white;
  static Color get errorRed => _current.errorRed;

  // Font scaling
  static FontSizeMode _fontMode = FontSizeMode.medium;
  static FontSizeMode get fontMode => _fontMode;
  static void setFontMode(FontSizeMode mode) {
    _fontMode = mode;
    Log.d(LogCat.app, 'Font size: ${mode.label} (${mode.scale}x)');
  }

  /// Scale a raw font size by the current font mode.
  static double fs(double base) => base * _fontMode.scale;

  // ── Named font sizes (scaled by font mode) ──────────────────
  static double get fontMeter => fs(8); // meter tick labels
  static double get fontCaption => fs(10); // captions, ghost text
  static double get fontSmall => fs(11); // secondary, tertiary
  static double get fontBody => fs(12); // default body text
  static double get fontBodyL => fs(13); // body emphasis
  static double get fontHeading => fs(14); // card/section headings
  static double get fontTitle => fs(16); // section titles
  static double get fontDialog => fs(18); // dialog titles
  static double get fontDisplay => fs(22); // large display text
  static double get fontHero => fs(36); // hero numbers (LUFS)

  /// Letter spacing as [percent] of [size]. Tracking of 3 % on
  /// 13.824 px text, as the Dark theme's status bar uses, is 0.4147 px.
  ///
  /// An absolute tracking value is only right at one text size, and
  /// the app scales every size by the font mode. A fixed absolute
  /// value leaves the tracking unchanged while the size moves, so the
  /// call sites take the percentage and the size they actually draw.
  static double tracking(double size, double percent) => size * percent / 100;

  // ── Font families ────────────────────────────────────────────
  /// Per-theme getters rather than `static const`, so a theme can carry
  /// its own face. Values come from app/design/tokens/ and are cross-checked
  /// against pubspec.yaml by the generator, so a family the app cannot
  /// load fails the build instead of falling back to the system font.
  static String get uiFamily => _current.uiFamily;
  static String get monoFamily => _current.monoFamily;

  // ── Composed text styles ─────────────────────────────────────
  //
  // Named styles for the recurring text roles. A typography
  // direction change (weight, letter spacing, family) is then a
  // one-line edit here instead of a repo-wide sweep. Use these for
  // the plain role; one-off variations stay inline (or copyWith).
  // Getters read the live theme — never store them in fields.

  /// Default body text.
  static TextStyle get styleBody =>
      TextStyle(color: textPrimary, fontSize: fontBody);

  /// Body text, de-emphasized (descriptions, secondary lines).
  static TextStyle get styleBodySecondary =>
      TextStyle(color: textSecondary, fontSize: fontBody);

  /// Form / control labels.
  static TextStyle get styleLabel =>
      TextStyle(color: textMuted, fontSize: fontSmall);

  /// Caps label of a panel, bar or strip: the Renderer view's AUDIO
  /// ELEMENTS and MONITORING, the Mix view's NAME, LANG, OUTPUT MIX GAIN
  /// and LAYOUTS, and the Settings window's section headers.
  static TextStyle get styleSectionLabel => TextStyle(
    color: textMuted,
    fontSize: fontBody,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
  );

  /// Captions under content.
  static TextStyle get styleCaption =>
      TextStyle(color: textMuted, fontSize: fontCaption);

  /// Ghost text — placeholders, empty-state hints.
  static TextStyle get styleHint =>
      TextStyle(color: textGhost, fontSize: fontCaption);

  /// Card / section headings.
  static TextStyle get styleHeading =>
      TextStyle(color: textPrimary, fontSize: fontHeading);

  /// Section titles.
  static TextStyle get styleTitle =>
      TextStyle(color: textPrimary, fontSize: fontTitle);

  /// Dialog titles.
  static TextStyle get styleDialogTitle => TextStyle(
    color: textPrimary,
    fontSize: fontDialog,
    fontWeight: FontWeight.w600,
  );

  /// ALL-CAPS eyebrow / section-header labels. Prefer the shared
  /// `EyebrowLabel` widget (widgets/eyebrow_label.dart), which
  /// upper-cases for you; direct users of this style upper-case
  /// the string themselves.
  static TextStyle get styleEyebrow => TextStyle(
    color: textSecondary,
    fontSize: fontCaption,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
  );

  /// Mono numeric readouts (time, dB, sample rates).
  static TextStyle get styleValue =>
      TextStyle(fontFamily: monoFamily, fontSize: fontBody, color: textValue);

  /// Small mono readouts (meter scales, fine print values).
  static TextStyle get styleValueSmall =>
      TextStyle(fontFamily: monoFamily, fontSize: fontMeter, color: textValue);

  // Sizes (constant across themes)
  /// Custom window titlebar strip (replaces the hidden native one).
  /// 28 matches the native macOS titlebar height so the centered
  /// title text lines up vertically with the traffic-light buttons.
  static const double titlebar = 28;

  /// Height of the top bar. 44 in every theme: a component's size does
  /// not vary by theme, only how it is drawn and coloured.
  static const double topbar = 44;

  /// Height of the status bar. 28 in every theme, for the same reason
  /// as [topbar].
  static const double statusbar = 28;
  static const double trackPanel = 180;
  // Per-theme getters rather than const, because the themes differ by
  // corner radius. One const call site had to go for this
  // (adm_probe_inspector); spacing has 110 const call sites, so it
  // stays global.
  static double get radius => _current.radius;
  static double get radiusSm => _current.radiusSm;
  static double get radiusMd => _current.radiusMd;

  /// Default hairline width for the decoration builders below.
  static double get borderWidth => _current.borderWidth;

  /// Which knob drawing the active theme uses.
  static KnobStyle get knobStyle => _current.knobStyle;

  /// Which top chrome the active theme draws.
  static ChromeStyle get chromeStyle => _current.chromeStyle;

  // ── Chrome (titlebar + top bar) ──────────────────────────────
  static Color get chromeBg => _current.chromeBg;
  static Color get chromeHi => _current.chromeHi;

  /// A `chromeBg` face on hover: pulled 40% toward `chromeRim`, the
  /// blend the top bar's raised buttons and Light's landing card take.
  static Color get chromeHoverFace => Color.lerp(chromeBg, chromeRim, 0.4)!;
  static Color get chromeInk => _current.chromeInk;
  static Color get chromeTabOn => _current.chromeTabOn;
  static Color get chromeTabOff => _current.chromeTabOff;
  static Color get chromeRim => _current.chromeRim;
  static Color get chromeRimDark => _current.chromeRimDark;
  static Color get chromeRimLight => _current.chromeRimLight;

  // ── Video strip ──────────────────────────────────────────────
  static Color get videoBg => _current.videoBg;
  static Color get videoHi => _current.videoHi;

  // ── Status bar ───────────────────────────────────────────────
  static Color get statusbarBg => _current.statusbarBg;
  static Color get statusbarHi => _current.statusbarHi;

  // ── Timeline ─────────────────────────────────────────────────
  static Color get rulerTick => _current.rulerTick;
  static Color get rulerLabel => _current.rulerLabel;
  static Color get playhead => _current.playhead;
  static Color get videoInk => _current.videoInk;
  static Color get trackPanelBg => _current.trackPanelBg;
  static Color get gutterBg => _current.gutterBg;

  // ── Dropdown controls ────────────────────────────────────────
  static ControlStyle get controlStyle => _current.controlStyle;
  static CardStyle get cardStyle => _current.cardStyle;
  static Color get controlBg => _current.controlBg;
  static Color get controlFg => _current.controlFg;

  // ── Spacing (4px baseline grid) ─────────────────────────────
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 12;
  static const double gapLg = 16;
  static const double gapXl = 24;

  // Off-grid half-steps, promoted from literals that had been
  // copy-pasted across dozens of call sites (ES-407). Deliberately
  // between grid steps — use the tokens, not bare 6 / 14.
  static const double gapPair = 6; // icon↔label / label↔value pairing
  static const double gapSection = 14; // section gap in dialogs/flows

  // ── Icon sizes ──────────────────────────────────────────────
  // Small sizes below iconXs (10/11/13) in meters, badges, and
  // console widgets — plus the inspector error banner's 20 — are
  // optically tuned one-offs and stay at their call sites;
  // everything else uses the scale.
  static const double iconXs = 12;
  static const double iconSm = 15;
  static const double iconMd = 18;
  static const double iconLg = 22;
  static const double iconXl = 28; // empty-state / drop-target icons
  static const double iconHero = 48; // full-screen notice icons

  // ── Shadows ─────────────────────────────────────────────────
  // No decorative drop shadows anywhere — panels and menus separate
  // from the canvas with borders only (see topbar / viz_panel).
  // The one sanctioned BoxShadow use is the *state glow*: a
  // color-tinted, offset-free blur (radius ≤ 6) that marks an
  // active / focused / engaged control (transport play focus ring,
  // console toggles, renderer speaker chips). Anything else with a
  // BoxShadow is a bug.

  // ── Indicator dots / status markers ─────────────────────────
  // Off-grid: 6 px is the optical LED size at 1×, not aligned to
  // the icon/gap scale.
  static const double dotSm = 6;

  // ── Tooltip wait ──────────────────────────────────────────
  //
  // Hover delay before any Tooltip appears.  Wired in via the
  // MaterialApp's tooltipTheme below — individual Tooltip widgets
  // should NOT pass waitDuration explicitly, that just drifts out
  // of sync.  500 ms matches the macOS HIG / Windows default and
  // is short enough for pro use but long enough not to flash on
  // incidental mouse movement.
  static const Duration tooltipWait = Duration(milliseconds: 500);

  /// Widest a tooltip grows before its text wraps, wired in through the
  /// same tooltipTheme. A long tooltip (the 9.1.6 channel-order note)
  /// otherwise spans the whole window.
  static const double tooltipMaxWidth = 360;

  // ── Motion ──────────────────────────────────────────────────
  static const Duration motionFast = Duration(milliseconds: 100);
  static const Duration motionMed = Duration(milliseconds: 150);

  // ── Composed decorations ─────────────────────────────────────
  //
  // Builders for the recurring surface patterns. Like the text
  // styles above: use for the plain pattern, keep one-off
  // decorations inline. Builders read the live theme.

  /// Buttons, inputs, small interactive containers.
  static BoxDecoration decoControl({
    Color? color,
    Color? borderColor,
    double? borderWidth,
  }) => BoxDecoration(
    color: color ?? bgControls,
    borderRadius: BorderRadius.circular(radiusSm),
    border: Border.all(
      color: borderColor ?? borderLight,
      width: borderWidth ?? T.borderWidth,
    ),
  );

  /// Elevated cards / grouped panels.
  static BoxDecoration decoCard({Color? color, Color? borderColor}) =>
      BoxDecoration(
        color: color ?? bgElevated,
        borderRadius: BorderRadius.circular(radiusMd),
        border: Border.all(
          color: borderColor ?? borderLight,
          width: borderWidth,
        ),
      );

  /// Recessed wells (timeline, meter tracks, deep insets).
  static BoxDecoration decoInset({Color? borderColor}) => BoxDecoration(
    color: bgDeep,
    borderRadius: BorderRadius.circular(radiusSm),
    border: Border.all(color: borderColor ?? borderLight, width: borderWidth),
  );
}

ThemeData eclipsaStudioTheme() {
  return ThemeData(
    useMaterial3: false,
    brightness: T.brightness,
    scaffoldBackgroundColor: T.bgDeep,
    fontFamily: T.uiFamily,
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: T.textPrimary, fontSize: T.fontBody),
      bodySmall: TextStyle(color: T.textSecondary, fontSize: T.fontCaption),
      labelSmall: TextStyle(color: T.textMuted, fontSize: T.fontCaption),
    ),
    // Global tooltip behavior — see T.tooltipWait. Setting it here
    // means individual Tooltip widgets inherit the correct delay
    // without having to repeat waitDuration at every call site.
    tooltipTheme: const TooltipThemeData(
      waitDuration: T.tooltipWait,
      constraints: BoxConstraints(minHeight: 24, maxWidth: T.tooltipMaxWidth),
    ),
  );
}
