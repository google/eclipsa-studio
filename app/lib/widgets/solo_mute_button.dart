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

/// Compact "S" / "M" monitoring toggle shared by every solo/mute site
/// (elements view track panel, mix view channel strip, renderer view
/// playback cards) so the control looks and behaves the same everywhere.
///
/// Solo uses [T.meterYellow] and Mute uses [T.meterRed] as [activeColor]
/// at all call sites — these sit alongside the meter UI, not error states.
///
/// Four drawings, by `T.chromeStyle`:
///
/// - `beveled`: a [T.bgControls] face in a 0.5 px [T.borderStrong] rim,
///   filled with [activeColor] at 30% and rimmed with it at 60% when
///   engaged, label in [activeColor].
/// - `recessed` (Classic): the transport buttons' well, filled with
///   [activeColor] at 30% when engaged, label in [activeColor].
/// - `outlined` (High Contrast): a [T.borderWidth] [T.borderStrong] outline
///   when off, a solid [activeColor] fill with an [T.accentFg] label
///   when on.
/// - `raised` (the Light theme): off is a flat [T.bgControls] face with no rim
///   and the label in the chrome's blue [T.chromeTabOn]; on is a
///   [T.borderWidth] [T.border] rim over [T.bgElevated] with [activeColor]
///   filling it one pixel inside, and a dark [T.bgBase] label on that fill.
///
/// The engaged label is not inked `borderLight` (`#232B3A`): this
/// control fills with [activeColor], and that ink is 3.78:1 on
/// [T.meterRed] — under the 4.5 `contrast.json` holds `accentFg` on
/// `purple` to, the same text-on-accent-fill role. The gate cannot see
/// the pair, since it is composed at run time from a token and a
/// caller's colour, so the ink is [T.bgBase]: 5.06:1 on [T.meterRed],
/// 7.17:1 on [T.meterYellow] and 8.09:1 on `#8EAADC`, so it still holds
/// if `purple` moves there.
///
/// The button is 20 px with a [T.fontCaption] label in every theme
/// and takes the radius from [T.radiusSm], which is
/// 6 in Light.
class SoloMuteButton extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  /// Fills the parent's width instead of the default 20 px square
  /// (the mix view stretches the pair across its channel strip).
  final bool expand;

  /// When false the button ignores taps and renders dimmed — used for
  /// mix-excluded elements, where engaging solo/mute would have no
  /// audible effect on the element itself (ES-297). Callers pass a
  /// [tooltip] that explains why.
  final bool enabled;

  const SoloMuteButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.activeColor,
    required this.onTap,
    this.expand = false,
    this.enabled = true,
  });

  /// The label's ink, per style and state. A disabled control takes
  /// [T.textGhost] in every style.
  Color get _ink {
    if (!enabled && !active) return T.textGhost;
    return switch (T.chromeStyle) {
      ChromeStyle.beveled ||
      ChromeStyle.recessed => active ? activeColor : T.textTertiary,
      // Light: the engaged face is the active colour, a mid tone on a
      // light ground, so the label is `accentFg` (white, 5.14:1 on
      // meterRed and 5.04:1 on meterYellow); `bgBase` is 3.6:1 there.
      ChromeStyle.raised => active ? T.accentFg : T.chromeTabOn,
      // High Contrast: the engaged face is a solid fill, so the label takes
      // `accentFg`, the ink the theme puts on a fill.
      ChromeStyle.outlined => active ? T.accentFg : T.textSecondary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final text = Center(
      child: Text(
        label,
        style: TextStyle(fontSize: T.fontCaption, color: _ink),
      ),
    );
    // The engaged raised face is two layers: the rim's own container,
    // whose border insets its child by its width, and the accent fill
    // inside it at that much less radius.
    final Widget face = switch (T.chromeStyle) {
      // Classic: the transport buttons' well. Engaged, the well fills
      // with the active colour at 30% under the label in that colour,
      // so the state is light inside the hole rather than a rim.
      ChromeStyle.recessed => Container(
        width: expand ? null : 20,
        height: 20,
        decoration: recessedWell(
          radius: T.radiusSm,
          fill: active ? activeColor.withValues(alpha: 0.3) : null,
        ),
        child: text,
      ),
      ChromeStyle.beveled => Container(
        width: expand ? null : 20,
        height: 20,
        decoration: BoxDecoration(
          color: active ? activeColor.withValues(alpha: 0.3) : T.bgControls,
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: active
              ? Border.all(color: activeColor.withValues(alpha: 0.6), width: 1)
              : Border.all(color: T.borderStrong, width: 0.5),
        ),
        child: text,
      ),
      // High Contrast: a `borderWidth` `borderStrong` outline when off, a
      // solid `activeColor` fill with no outline when on.
      ChromeStyle.outlined => Container(
        width: expand ? null : 20,
        height: 20,
        decoration: BoxDecoration(
          color: active ? activeColor : T.bgControls,
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(
            color: active ? activeColor : T.borderStrong,
            width: T.borderWidth,
          ),
        ),
        child: text,
      ),
      ChromeStyle.raised => Container(
        width: expand ? null : 20,
        height: 20,
        decoration: BoxDecoration(
          color: active ? T.bgElevated : T.bgControls,
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: active
              ? Border.all(color: T.border, width: T.borderWidth)
              : null,
        ),
        child: active
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: activeColor,
                  borderRadius: BorderRadius.circular(
                    T.radiusSm - T.borderWidth,
                  ),
                ),
                child: text,
              )
            : text,
      ),
    };
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: face,
        ),
      ),
    );
  }
}
