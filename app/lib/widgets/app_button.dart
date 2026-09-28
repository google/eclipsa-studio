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

import '../theme.dart';
import 'chrome_surface.dart';

/// What an [AppButton] does. The drawing is the same in every theme;
/// the role picks the ink and, for the affirmative, the fill.
enum AppButtonRole {
  /// A rimmed button in the primary ink: the entry points on the
  /// landing card, inline actions in panels and dialogs.
  standard,

  /// The one confirming action of a dialog: `accentFill` under
  /// `accentInk`. One per footer.
  affirmative,

  /// A rimmed button with an `errorRed` label: delete, discard, reset.
  destructive,

  /// No rim, `textSecondary` label: cancel and dismiss actions that sit
  /// beside an affirmative.
  quiet,
}

/// How a [AppButtonRole.standard] [AppButton] sits on its ground. The
/// landing card picks it by the theme's card style (ES-755).
enum AppButtonFace {
  /// The rimmed box every theme draws by default.
  flat,

  /// Raised off the ground: [RaisedFace] where the chrome style is
  /// raised (Light), [AppButton.raisedButtonFace] elsewhere (Dark).
  raised,

  /// Sunk slightly into the ground: Classic's [recessedWell], the well
  /// its transport buttons, clock and dropdown sit in. The well is the
  /// same disabled; only the ink dims.
  recessed,
}

/// The two sizes an [AppButton] comes in.
enum AppButtonSize {
  /// 36 px, `fontHeading` label: landing entry points, dialog footers
  /// and alert actions.
  regular,

  /// 28 px, `fontSmall` label: inline actions in panels and settings.
  compact,
}

/// The app's text button, one drawing in every theme.
///
/// A rounded box at `radiusSm` and a fixed height, drawn from the
/// theme's tokens by [role] and [size], with hover, press, focus and
/// keyboard activation from [ChromePressable]. It draws no Material
/// button underneath, so the desktop visual density that shrinks a
/// `TextButton` by 8 px a side in the app does not apply to it, and a
/// widget test measures what the app shows.
///
/// [onPressed] null renders the button disabled: the ink and rim dim
/// to 40%, the affirmative fill drops to `bgControls`, and taps and
/// keyboard activation are ignored.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.role = AppButtonRole.standard,
    this.size = AppButtonSize.regular,
    this.icon,
    this.foreground,
    this.mainAxisAlignment = MainAxisAlignment.center,
    this.tooltip,
    this.autofocus = false,
    this.face = AppButtonFace.flat,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonRole role;
  final AppButtonSize size;

  /// A leading glyph, at `iconMd` in the regular size and `iconSm` in
  /// the compact one.
  final IconData? icon;

  /// Overrides the label and glyph colour of a [AppButtonRole.standard]
  /// or [AppButtonRole.quiet] button. The landing card passes
  /// `chromeInk` where the card sits on the chrome ground, where the
  /// text tokens do not reach the contrast floor.
  final Color? foreground;

  /// Where the label sits when the button is wider than its content: a
  /// stretched landing entry button starts left, a footer button
  /// centres. Under loose constraints the button is as wide as its
  /// content and this makes no difference.
  final MainAxisAlignment mainAxisAlignment;

  final String? tooltip;

  /// Takes focus when built, so Enter activates the default action of a
  /// dialog.
  final bool autofocus;

  /// How a [AppButtonRole.standard] button sits on its ground; the
  /// other roles always draw [AppButtonFace.flat]. The landing card's
  /// entry buttons set it (ES-755).
  final AppButtonFace face;

  /// The height of each size.
  static double heightOf(AppButtonSize size) => switch (size) {
    AppButtonSize.regular => 36,
    AppButtonSize.compact => 28,
  };

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final compact = size == AppButtonSize.compact;
    final affirmative = role == AppButtonRole.affirmative;

    final ink = switch (role) {
      AppButtonRole.standard => foreground ?? T.textPrimary,
      AppButtonRole.affirmative => T.accentInk,
      AppButtonRole.destructive => T.errorRed,
      AppButtonRole.quiet => foreground ?? T.textSecondary,
    };
    // Disabled dims once, at the ink: a second dim over the whole
    // drawing took a label under the floor.
    final inkDrawn = enabled
        ? ink
        : (affirmative ? T.textTertiary : ink.withValues(alpha: 0.4));
    final rim = switch (role) {
      AppButtonRole.quiet || AppButtonRole.affirmative => null,
      _ => enabled ? T.borderStrong : T.borderStrong.withValues(alpha: 0.4),
    };
    final fill = affirmative ? (enabled ? T.accentFill : T.bgControls) : null;
    final labelStyle = TextStyle(
      color: inkDrawn,
      fontSize: compact ? T.fontSmall : T.fontHeading,
      fontWeight: FontWeight.w500,
    );

    return ChromePressable(
      onTap: onPressed,
      tooltip: tooltip,
      semanticLabel: label,
      autofocus: autofocus,
      builder: (context, state) {
        // Hover and press tint the face in the ink, so the overlay
        // reads on every ground a button sits on: a dialog, a panel,
        // the landing card's chromeBg in Light.
        final overlay = state.pressed
            ? ink.withValues(alpha: 0.16)
            : (state.hovered ? ink.withValues(alpha: 0.08) : null);
        // Focus draws a 2 px ring over the face in the ink, which is
        // the one colour known to contrast with every ground a button
        // sits on: textPrimary on the body, chromeInk on Light's
        // chromeBg landing card, accentInk on the accent fill. Drawn
        // in the foreground so it neither moves the label nor hides
        // under the fill.
        final ring = state.focused ? (affirmative ? T.accentInk : ink) : null;
        // The box hugs its content under loose constraints and fills a
        // tight width, as the landing card's stretched entries do. A
        // Container with an alignment fills any bounded parent, which
        // stretched an alert's OK across the footer; IntrinsicWidth on
        // the row is what keeps the button as wide as its label.
        final drawn = role == AppButtonRole.standard
            ? face
            : AppButtonFace.flat;
        final content = IntrinsicWidth(
          child: Row(
            mainAxisAlignment: mainAxisAlignment,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: compact ? T.iconSm : T.iconMd,
                  color: inkDrawn,
                ),
                SizedBox(width: compact ? T.gapPair : T.gapSm),
              ],
              Flexible(
                child: Text(
                  label,
                  style: labelStyle,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
        final padding = EdgeInsets.symmetric(horizontal: compact ? 10 : 12);
        // Light: the raised button face (RaisedFace) that the top bar's
        // tabs and transport draw. Its hover tints the face,
        // as the doc on RaisedFace.face requires, rather than an overlay
        // over the rims; the focus ring still draws over it.
        if (drawn == AppButtonFace.raised &&
            T.chromeStyle == ChromeStyle.raised) {
          return Container(
            height: heightOf(size),
            foregroundDecoration: ring == null
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(T.radius),
                    border: Border.all(color: ring, width: 2),
                  ),
            child: RaisedFace(
              radius: T.radius,
              pressed: state.pressed,
              lifted: enabled,
              face: state.hovered && !state.pressed ? T.chromeHoverFace : null,
              // The rims take 3 px of each side.
              child: Padding(
                padding: padding - const EdgeInsets.symmetric(horizontal: 3),
                child: content,
              ),
            ),
          );
        }
        return Container(
          height: heightOf(size),
          padding: padding,
          decoration: switch (drawn) {
            AppButtonFace.raised => raisedButtonFace(
              pressed: state.pressed,
              enabled: enabled,
            ),
            // Hover and press tint it through the overlay below, as
            // they do the flat box.
            AppButtonFace.recessed => recessedWell(radius: T.radiusSm),
            AppButtonFace.flat => BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(T.radiusSm),
              border: Border.all(
                color: rim ?? const Color(0x00000000),
                width: T.borderWidth,
              ),
            ),
          },
          foregroundDecoration: overlay == null && ring == null
              ? null
              : BoxDecoration(
                  color: overlay,
                  borderRadius: BorderRadius.circular(T.radiusSm),
                  border: ring == null
                      ? null
                      : Border.all(color: ring, width: 2),
                ),
          child: content,
        );
      },
    );
  }

  /// The [AppButtonFace.raised] face outside Light. Pressed, the
  /// gradient turns over and the shadow goes, so the face reads as
  /// pushed into the card; disabled, it sits flat without the shadow.
  /// The landing page's version pill draws it too.
  static BoxDecoration raisedButtonFace({
    required bool pressed,
    required bool enabled,
  }) {
    final top = Color.lerp(T.bgControls, T.bgHover, 0.5)!;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(T.radiusSm),
      border: Border.all(color: T.bgDeep, width: T.borderWidth),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: pressed ? [T.bgControls, top] : [top, T.bgControls],
      ),
      boxShadow: pressed || !enabled
          ? null
          : const [
              BoxShadow(
                color: Color(0x40000000),
                offset: Offset(0, 1),
                blurRadius: 3,
              ),
              BoxShadow(
                color: Color(0x1F000000),
                offset: Offset(0, 4),
                blurRadius: 8,
              ),
            ],
    );
  }
}
