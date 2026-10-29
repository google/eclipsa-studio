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

// ───────────────────────────────────────────────────────────────────────
// Theme schema — the colour tokens that make up one theme variant.
//
// Hand-written on purpose: this is the contract that class T forwards
// over and that the token generator validates against. The *values*
// live in app/design/tokens/ and are generated into theme_tokens.dart;
// only the shape lives here. Adding a field here means adding it to
// every token file, and the generator fails the build until you do.
// ───────────────────────────────────────────────────────────────────────

/// Which knob the theme draws.
///
/// The styles differ by how the instrument is built as well as by
/// hue. The knobs here stack their layers in a different order, so no
/// set of colour tokens turns one into the other.
enum KnobStyle {
  /// The Dark theme's knob: the accent arc is the OUTERMOST ring, a
  /// light rim sits inside it, and the body is a neutral brushed disc
  /// with a conic sheen and a pale pointer. The accent appears only in
  /// the arc.
  brushed,

  /// The Light theme's knob: an accent-coloured body under a glare
  /// highlight, with the fill arc INSIDE the rim rather than outside
  /// it. Drawn by [KnobA].
  knobA,

  /// Classic: a bar knob. The dish is the well the transport buttons
  /// are sunk into, round (`bgControls` in a `chromeRimDark` rim over
  /// a `chromeRimLight` edge); a `borderStrong` cap sits in it, and a
  /// `textSecondary` bar runs across the cap from rim to rim, its
  /// flanks shaded against a light at the top left of the screen
  /// under a lit top face with a dimple at the pointer end. The scale
  /// is printed on the plate outside the dish in `textTertiary`: an
  /// arc along the sweep with ticks every 12 dB and `fontMeter` labels
  /// from 56 px up. No accent arc and no LED: the bar's angle is the
  /// value. Drawn by `BarKnobPainter` in `knob_line_painters.dart`.
  bar,

  /// High Contrast: a `borderWidth` white ring, an accent arc twice that
  /// width inside it, a pointer bar from the centre to the ring and a
  /// 0 dB mark. No fill and no gradient. Drawn by
  /// `OutlinedKnobPainter`.
  outlined,
}

/// Which top chrome the theme draws.
///
/// The `beveled` style changes the structure of the titlebar and top
/// bar as well as their colours, and structure is not something a
/// colour token can carry. Each widget in
/// the top chrome branches on this in one place.
enum ChromeStyle {
  /// Dark: one radial-gradient surface across titlebar and top
  /// bar with 1 px inset bevel lines, 20 px tabs in the accent colour
  /// with a fading underline, flat transport glyphs with no button
  /// chrome. Adopted one widget at a time.
  beveled,

  /// Light: a light `chromeBg` bar over the body, with raised buttons
  /// built from three rims (`chromeRim` outside, `chromeRimDark` and
  /// `chromeRimLight` inside) and a soft drop shadow. The active tab is
  /// such a button with bold `chromeTabOn` text; an inactive tab is a
  /// 2 px `chromeTabOn` outline with `chromeTabOff` text. Adopted one
  /// widget at a time, like `beveled`.
  raised,

  /// Classic: one matte `chromeBg` plate for titlebar and top bar with
  /// a 1 px `chromeRim` line under the bar. The transport buttons, the
  /// play button, the clock and the dropdown are wells cut into it:
  /// `bgControls` fill in a 1 px `chromeRimDark` rim over a 1 px
  /// `chromeRimLight` edge below the shape (`recessedWell`). The active
  /// tab carries a 2 px `purple` bar in a 4 px well under its label;
  /// inactive tabs carry nothing.
  recessed,

  /// High Contrast: a `chromeBg` bar under a `borderWidth` `chromeRim`
  /// rule. Transport buttons are `borderWidth` `chromeRimLight`
  /// boxes at `radiusSm`; play is a solid `chromeTabOn` box with
  /// an `accentFg` glyph. The active tab is a solid `chromeTabOn`
  /// block with `accentFg` text; inactive tabs are `chromeTabOff`
  /// text. No gradient and no shadow anywhere in the chrome.
  outlined,
}

/// The boolean question most chrome call sites ask of a [ChromeStyle]:
/// does the body sit on one flat ground, or does the style lift it?
extension ChromeStyleGround on ChromeStyle {
  /// True for `recessed` and `outlined`, which draw the body on one
  /// colour with no radial lift and no light bar over it. False for
  /// `beveled` and `raised`. The switch below is exhaustive, so adding
  /// a style fails the analyzer here until the style is sorted into
  /// one of the two groups.
  bool get flatGround => switch (this) {
    ChromeStyle.recessed || ChromeStyle.outlined => true,
    ChromeStyle.beveled || ChromeStyle.raised => false,
  };
}

/// Which dropdown control the theme draws. See `SelectorChrome` in
/// `widgets/console_widgets.dart`, the one place that reads it.
enum ControlStyle {
  /// Dark and Light: a 24 px `controlBg` fill at `radiusSm` inside a
  /// 1 px `border` rim, a `fontBody` `controlFg` label and a 12 px caret
  /// in the same colour.
  filled,

  /// Classic: a 24 px well sunk into the panel: `controlBg` fill at
  /// `radiusSm`, no outer border, a 1 px `chromeRimDark` line along the
  /// top inside edge, `controlFg` label and caret.
  well,

  /// High Contrast: a 24 px `controlBg` box with a `borderWidth` border at
  /// `radiusSm`, `controlFg` label and caret. The border is
  /// `borderStrong` at rest and `controlFg` under the pointer. High
  /// Contrast's tokens set the border to 2 px and the radius to 6.
  outlined,
}

/// Which landing card the theme draws. See `landing_screen.dart`.
///
/// The landing screen branches on this, in one place per widget. It
/// was first selected by `chromeStyle`, which names the top chrome, so
/// any theme with a raised top bar took the raised landing card with
/// it (ES-699). A separate token lets a theme choose its top bar and its
/// landing card independently.
enum CardStyle {
  /// One `bgElevated` card at radius 12 with a hairline `border`.
  flat,

  /// Light: the same card on the `chromeBg` ground with `chromeInk`
  /// type, so the landing reads on the ground the top bar uses.
  /// `T.radius` corners and a `chromeRim` hairline, the line the bar
  /// draws under itself; the ground is 1.13:1 against `bgBase`.
  chrome,

  /// High Contrast: one `bgElevated` card at `T.radius` with a
  /// `borderWidth` `borderStrong` border.
  outlined,

  /// Dark: the `flat` card with no border, on a radial-gradient ground
  /// lighter at the top edge, with raised entry buttons (ES-755, ES-757).
  floating,
}

class AppThemeData {
  // Backgrounds
  final Color bgDeep;
  final Color bgBase;

  /// The landing screen's ground: a vertical gradient from
  /// [landingGroundTop] to [landingGroundBottom], painted behind the
  /// whole window while the landing screen shows (ES-757). Equal values
  /// draw a flat ground.
  final Color landingGroundTop;
  final Color landingGroundBottom;
  final Color bgSurface;
  final Color bgElevated;
  final Color bgHover;
  final Color bgControls;

  // Borders
  final Color border;
  final Color borderLight;
  final Color borderStrong;

  // Accent
  final Color purple;
  final Color pink;
  final Color purpleLight;
  final Color purpleDim;
  final Color accentFg; // text/icons over a purple fill
  final Color accentFill; // the fill of an affirmative AppButton
  final Color accentInk; // the label on accentFill

  // Element types
  final Color typeObject;
  final Color typeChannel;
  final Color typeScene;

  // 3D objects
  final Color objCyan;
  final Color objGreen;
  final Color objAmber;

  // 3D axes (X, Y, Z)
  final Color axisX;
  final Color axisY;
  final Color axisZ;

  /// Background scrim for the axes gizmo (and similar overlays that
  /// sit on top of arbitrary 3D scenes). Always a dark tint so the
  /// gizmo stays readable against light scenes too, and so a light
  /// theme's `bgDeep` could not take the contrast away.
  final Color gizmoBg;

  /// Scrim for timeline regions past a track's end of media. Per-theme
  /// on purpose: a fixed black tint is near-invisible over the dark
  /// themes' backgrounds and overweight on light — dark themes haze
  /// with white, light dims with black.
  final Color pastEndScrim;

  /// Default "active / on" indicator color (LED-style dots). Decoupled
  /// from `typeObject` so element-taxonomy color changes don't silently
  /// recolor every status dot in the app.
  final Color indicatorGreen;

  // Meters
  final Color meterGreen;
  final Color meterYellow;

  /// Top of the level ramp (−6 to 0 dBFS). On a level meter, red is
  /// not part of the ramp: [meterRed] marks the sticky clip latch.
  final Color meterAmber;
  final Color meterRed;

  /// Diverging correlation scale (ρ): corrNeg → corrZero → corrPos
  /// maps −1 → 0 → +1. Decoupled from axis/meter colors so the
  /// heatmap can be tuned per theme without touching those.
  final Color corrNeg;
  final Color corrZero;
  final Color corrPos;

  // Text
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textMuted;
  final Color textGhost;

  // Selected / active surfaces
  final Color bgSelected;

  // Mono readout values
  final Color textValue;
  final Color textValueDim;
  final Color textInactive;

  final Color white;
  final Color errorRed;

  // Typography
  //
  // Per-theme so a theme can carry its own face. Only one call site
  // read these inside a `const` expression, against the 110 that pin
  // the spacing tokens as static const.
  //
  // Values must match a family declared in pubspec.yaml; otherwise
  // Flutter falls back to the system face without reporting an error.

  /// UI text face.
  final String uiFamily;

  /// Monospace face for numeric readouts (time, dB, sample rates).
  final String monoFamily;

  // Shape. Per-theme because the themes differ by corner radius and
  // bevel as well as by colour. Moving these cost one const removal
  // across the whole app, against the 110 that keep spacing global.

  /// Corner radius for large surfaces (dialogs, cards).
  final double radius;

  /// Corner radius for controls, chips and wells. The common one.
  final double radiusSm;

  /// Corner radius between the two (grouped panels).
  final double radiusMd;

  /// Hairline width for the decoration builders. Call sites that pass
  /// their own width keep it; this is the default the builders use.
  final double borderWidth;

  /// Which knob drawing this theme uses. See [KnobStyle].
  final KnobStyle knobStyle;

  /// Which top chrome this theme draws. See [ChromeStyle].
  final ChromeStyle chromeStyle;

  // Chrome: the titlebar and top bar. Separate from the body tokens
  // because the bar is its own surface: Light draws a `chromeBg` bar
  // one step above its `bgBase` body, and Dark draws the bar as a
  // radial gradient from [chromeHi] to [chromeBg].

  /// Ground of the top bar. For a `beveled` chrome, the edge of its
  /// radial gradient; [chromeHi] is the centre.
  final Color chromeBg;

  /// Centre of the `beveled` chrome's radial gradient. Equals
  /// [chromeBg] wherever the chrome is a flat fill.
  final Color chromeHi;

  /// Text on the chrome ground: labels, the clock.
  final Color chromeInk;

  /// The active workspace tab's text, and the `raised` control tint.
  final Color chromeTabOn;

  /// An inactive workspace tab's text.
  final Color chromeTabOff;

  /// Outer rim of a raised chrome button; the bar's bottom line.
  final Color chromeRim;

  /// Dark rim just inside [chromeRim]; the bar's bottom edge.
  final Color chromeRimDark;

  /// Light rim inside [chromeRimDark], the highlight of a raised face.
  final Color chromeRimLight;

  /// Ground of the status bar. For a `beveled` chrome, the top of its
  /// vertical gradient; [statusbarHi] is the bottom.
  final Color statusbarBg;

  /// Bottom of the `beveled` status bar's gradient. Equals
  /// [statusbarBg] wherever the bar is a flat fill.
  final Color statusbarHi;

  /// The time ruler's tick marks.
  final Color rulerTick;

  /// The time ruler's labels.
  final Color rulerLabel;

  /// The playhead line and its head.
  final Color playhead;

  /// The video lane's metadata chip ink.
  final Color videoInk;

  /// Ground of the video strip between the top bar and the timeline.
  final Color videoBg;

  /// Centre of the video strip's radial lift; equals [videoBg] where
  /// the strip is a flat fill.
  final Color videoHi;

  /// Ground of the Elements view's track panel column. `bgBase` where
  /// the column takes the page ground and draws no fill of its own.
  final Color trackPanelBg;

  /// Ground of the timeline's scroll and zoom gutters, the strip along
  /// the bottom and the one down the right edge.
  final Color gutterBg;

  /// Which dropdown control this theme draws. See [ControlStyle].
  final ControlStyle controlStyle;

  /// Which landing card this theme draws. See [CardStyle].
  final CardStyle cardStyle;

  /// Fill of a dropdown's closed control and of its open menu.
  final Color controlBg;

  /// Label and caret of a dropdown's closed control.
  final Color controlFg;

  const AppThemeData({
    required this.bgDeep,
    required this.bgBase,
    required this.landingGroundTop,
    required this.landingGroundBottom,
    required this.bgSurface,
    required this.bgElevated,
    required this.bgHover,
    required this.bgControls,
    required this.border,
    required this.borderLight,
    required this.borderStrong,
    required this.purple,
    required this.pink,
    required this.purpleLight,
    required this.purpleDim,
    required this.accentFg,
    required this.accentFill,
    required this.accentInk,
    required this.typeObject,
    required this.typeChannel,
    required this.typeScene,
    required this.objCyan,
    required this.objGreen,
    required this.objAmber,
    required this.axisX,
    required this.axisY,
    required this.axisZ,
    required this.gizmoBg,
    required this.pastEndScrim,
    required this.indicatorGreen,
    required this.meterGreen,
    required this.meterYellow,
    required this.meterAmber,
    required this.meterRed,
    required this.corrNeg,
    required this.corrZero,
    required this.corrPos,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textMuted,
    required this.textGhost,
    required this.bgSelected,
    required this.textValue,
    required this.textValueDim,
    required this.textInactive,
    required this.white,
    required this.errorRed,
    required this.uiFamily,
    required this.monoFamily,
    required this.radius,
    required this.radiusSm,
    required this.radiusMd,
    required this.borderWidth,
    required this.knobStyle,
    required this.chromeStyle,
    required this.chromeBg,
    required this.chromeHi,
    required this.chromeInk,
    required this.chromeTabOn,
    required this.chromeTabOff,
    required this.chromeRim,
    required this.chromeRimDark,
    required this.chromeRimLight,
    required this.statusbarBg,
    required this.statusbarHi,
    required this.rulerTick,
    required this.rulerLabel,
    required this.playhead,
    required this.videoInk,
    required this.videoBg,
    required this.videoHi,
    required this.trackPanelBg,
    required this.gutterBg,
    required this.controlStyle,
    required this.cardStyle,
    required this.controlBg,
    required this.controlFg,
  });
}
