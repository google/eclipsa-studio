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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import 'app_button.dart';
import 'chrome_surface.dart';
import 'console_widgets.dart' show SelectorChrome;

/// A [height] px chip, selected or not.
///
/// The Renderer view's output targets (`OptionGrid`), the Mix view's mix
/// presentation tabs and add buttons, and its LAYOUTS bar's layout chips
/// are drawn with it, so a chosen thing looks the same in every one of
/// them: the selected drawing marks the active monitoring target and
/// the active mix presentation; the plain drawing marks a choice that
/// can be clicked, or, without a tap, a label such as a tagged layout.
///
/// ## Drawing
///
/// Selected, in every theme: a flat `accentFill` at `radiusSm` with no
/// rim under a w600 `accentInk` label, the colours of the affirmative
/// [AppButton] (4.8:1 or more on the fill).
///
/// Plain, by `T.chromeStyle`, each from the theme's own button faces:
///
/// - `beveled` (Dark): the raised face of the landing card's buttons
///   ([AppButton.raisedButtonFace]), lifted by its shadow, with a
///   `textSecondary` label.
/// - `raised` (Light): a lifted [RaisedFace] with a `chromeTabOn` label,
///   as the transport buttons draw.
/// - `recessed` (Classic): a [recessedWell] with a `textSecondary`
///   label, the transport buttons' well.
/// - `outlined` (High Contrast): a `borderWidth` `borderStrong` outline
///   on `bgControls` with a `textSecondary` label.
///
/// [child] draws on the face with [labelStyle] in [ink] as its default
/// text style and [ink] as its icon colour, [hPad] in from each side.
///
/// ## Input
///
/// A chip with [onTap] is a [ChromePressable]: it takes keyboard focus,
/// Enter activates it, and it announces as a button with
/// [semanticLabel]. Hover tints a plain face as the theme's buttons do.
/// Focus rings the chip's edge at 1.5 px, in [SelectorChrome.focusColor]
/// on a plain chip and in the label's ink on a selected one, whose fill
/// is the focus colour itself in some themes.
///
/// A chip without [onTap] is a label: it draws at rest, takes no input
/// and is announced by its content alone. A chip that is not [enabled]
/// cannot be chosen: its face and rim draw at 40%, it takes no input,
/// and it announces as a disabled button. Its label stays at full
/// strength so it reads on the dimmed face: `textPrimary` when it is
/// selected, since `accentInk` does not reach 4.5:1 on the dimmed accent
/// fill in every theme, and `textTertiary` when it is not
/// (`textSecondary` in Light, where `textTertiary` is 4.11:1 on the
/// dimmed face).
///
/// Self-tracks theme and font mode, so a `const` instance redraws on a
/// switch.
class ConsoleChip extends ConsumerWidget {
  const ConsoleChip({
    super.key,
    required this.child,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.semanticLabel,
    this.alignment = Alignment.center,
    this.mouseCursor = SystemMouseCursors.click,
  }) : assert(
         onTap == null || semanticLabel != null,
         'A chip that takes a tap needs a semanticLabel to be announced as '
         'a button',
       );

  /// The chip's height.
  static const double height = 24;

  /// The space between the face's edge and [child], each side.
  static const double hPad = 8;

  /// The label's metrics for the state; selected labels draw at w600.
  /// Colour is [ink].
  static TextStyle labelStyle({required bool selected}) => TextStyle(
    fontSize: T.fontBody,
    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
  );

  /// The label's ink for the state, per the class doc.
  static Color ink({required bool selected, bool enabled = true}) {
    if (selected) return enabled ? T.accentInk : T.textPrimary;
    if (!enabled) {
      return T.chromeStyle == ChromeStyle.raised
          ? T.textSecondary
          : T.textTertiary;
    }
    return T.chromeStyle == ChromeStyle.raised
        ? T.chromeTabOn
        : T.textSecondary;
  }

  final Widget child;
  final bool selected;
  final bool enabled;

  /// Null draws a label that takes no input.
  final VoidCallback? onTap;

  /// Names the chip for assistive technology when it takes input.
  final String? semanticLabel;

  /// Where [child] sits inside the padding.
  final AlignmentGeometry alignment;

  /// The cursor over a chip that takes a tap.
  final MouseCursor mouseCursor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    // A label is announced by its text alone: "selected" would offer a
    // choice it does not take.
    if (onTap == null && enabled) {
      return _draw(
        context,
        const PressableState(
          enabled: true,
          hovered: false,
          pressed: false,
          focused: false,
        ),
      );
    }
    return Semantics(
      selected: selected,
      child: ChromePressable(
        onTap: enabled ? onTap : null,
        semanticLabel: semanticLabel,
        mouseCursor: mouseCursor,
        builder: _draw,
      ),
    );
  }

  Widget _draw(BuildContext context, PressableState state) {
    final ink = ConsoleChip.ink(selected: selected, enabled: enabled);
    // The content takes its own width; the Stack places it by
    // [alignment] when the parent fixes a wider chip (a grid cell), and
    // takes the content's width when the parent leaves it free (a row
    // or a wrap).
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: hPad),
      child: Align(
        alignment: alignment,
        widthFactor: 1,
        child: DefaultTextStyle.merge(
          style: labelStyle(selected: selected).copyWith(color: ink),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          child: IconTheme.merge(
            data: IconThemeData(color: ink, size: T.iconXs),
            child: child,
          ),
        ),
      ),
    );
    final face = _face(state, ink);
    // The face and the label are separate layers, so an unavailable
    // chip can dim the face alone and keep its label at full strength;
    // the ring draws over both.
    return SizedBox(
      height: height,
      child: Stack(
        alignment: alignment,
        children: [
          Positioned.fill(
            child: enabled ? face : Opacity(opacity: 0.4, child: face),
          ),
          content,
          if (state.focused) Positioned.fill(child: _ring(ink)),
        ],
      ),
    );
  }

  /// The focus ring, on the chip's edge.
  Widget _ring(Color ink) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(T.radiusSm),
      border: Border.all(
        color: selected ? ink : SelectorChrome.focusColor,
        width: 1.5,
      ),
    ),
  );

  /// The face for the state. A plain face takes the hover and press
  /// drawings of the theme's buttons: Dark tints the face in the ink,
  /// Light draws the pressed [RaisedFace], Classic and High Contrast keep
  /// the hover fill while pressed, as their transport buttons do.
  Widget _face(PressableState state, Color ink) {
    if (selected) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: T.accentFill,
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
      );
    }
    final hovered = state.hovered;
    switch (T.chromeStyle) {
      case ChromeStyle.beveled:
        // Hover and press tint the face in the ink, as AppButton does.
        final overlay = state.pressed
            ? ink.withValues(alpha: 0.16)
            : (hovered ? ink.withValues(alpha: 0.08) : null);
        return Container(
          decoration: AppButton.raisedButtonFace(
            pressed: state.pressed,
            enabled: enabled,
          ),
          foregroundDecoration: overlay == null
              ? null
              : BoxDecoration(
                  color: overlay,
                  borderRadius: BorderRadius.circular(T.radiusSm),
                ),
        );
      case ChromeStyle.raised:
        return RaisedFace(
          radius: T.radiusSm,
          pressed: state.pressed,
          lifted: enabled,
          face: hovered && !state.pressed ? T.chromeHoverFace : null,
          child: const SizedBox.expand(),
        );
      case ChromeStyle.recessed:
        return DecoratedBox(
          decoration: recessedWell(
            radius: T.radiusSm,
            fill: hovered ? T.bgHover : null,
          ),
        );
      case ChromeStyle.outlined:
        return DecoratedBox(
          decoration: BoxDecoration(
            color: hovered ? T.bgHover : T.bgControls,
            borderRadius: BorderRadius.circular(T.radiusSm),
            border: Border.all(color: T.borderStrong, width: T.borderWidth),
          ),
        );
    }
  }
}
