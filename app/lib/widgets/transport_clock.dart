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

/// The transport's position / duration readout, as the top bar shows
/// it. Presentational: the top bar binds it to the transport and to the
/// time-or-samples toggle; the Theme Gallery renders it with fixed text.
///
/// Every style draws a box 30 px tall with 10 px of side padding and the
/// readout at `fontBodyL` in the monospace face with tabular figures, so the
/// readout does not jitter as digits change. Four drawings, chosen by the
/// theme's [ChromeStyle]:
///
/// - `beveled` (the Dark theme): no box, `textValue` with
///   `T.tracking(T.fontBodyL, 3)`, the slash at half opacity.
/// - `raised` (the Light theme): a 1 px `chromeInk` outline at `radiusSm`,
///   `chromeInk` with the same tracking, the slash at half opacity.
/// - `recessed`: Classic, a [recessedWell] at `radiusMd`, `textValue`
///   with no tracking, the slash in `textGhost`.
/// - `outlined`: High Contrast, a `borderWidth` `chromeRimDark` outline at
///   `radiusSm`, `textValue` with no tracking, the slash in
///   `textGhost`.
///
/// With [widest] set, the readout's box is at least the size of
/// `widest / widest` drawn in the same style, and the current readout is
/// centred in it.
class TransportClock extends StatelessWidget {
  const TransportClock({
    super.key,
    required this.position,
    required this.duration,
    this.widest,
    this.onTap,
    this.tooltip,
  });

  final String position;
  final String duration;

  /// The longest value the readout can show in its display mode, used
  /// for both the position and the duration. The top bar sets it so the
  /// readout keeps one width as the values change length, and the
  /// controls beside it keep their place.
  final String? widest;

  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // Only `beveled` and `raised` track the digits and tint the slash.
    final flat = T.chromeStyle.flatGround;
    final base = TextStyle(
      fontFamily: T.monoFamily,
      fontFeatures: const [FontFeature.tabularFigures()],
      // The readout is fontBodyL in every style.
      fontSize: T.fontBodyL,
      letterSpacing: flat ? null : T.tracking(T.fontBodyL, 3),
      color: switch (T.chromeStyle) {
        ChromeStyle.raised => T.chromeInk,
        ChromeStyle.beveled ||
        ChromeStyle.recessed ||
        ChromeStyle.outlined => T.textValue,
      },
    );
    final slash = flat ? T.textGhost : base.color!.withValues(alpha: 0.5);
    TextSpan readout(String position, String duration) => TextSpan(
      style: base,
      children: [
        TextSpan(text: position),
        TextSpan(
          text: ' / ',
          style: TextStyle(color: slash),
        ),
        TextSpan(text: duration),
      ],
    );
    Widget text = Text.rich(readout(position, duration));
    if (widest != null) {
      // The widest readout is laid out but not painted, so the box takes
      // its size under the same text style, scaler and locale as the
      // visible readout drawn over it.
      text = Stack(
        alignment: Alignment.center,
        children: [
          Visibility(
            visible: false,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Text.rich(readout(widest!, widest!)),
          ),
          text,
        ],
      );
    }
    final box = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: switch (T.chromeStyle) {
        ChromeStyle.beveled => null,
        ChromeStyle.raised => BoxDecoration(
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(color: T.chromeInk),
        ),
        ChromeStyle.recessed => recessedWell(radius: T.radiusMd),
        ChromeStyle.outlined => BoxDecoration(
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(color: T.chromeRimDark, width: T.borderWidth),
        ),
      },
      child: text,
    );
    final tapped = onTap == null
        ? box
        : GestureDetector(onTap: onTap, child: box);
    return tooltip == null
        ? tapped
        : Tooltip(message: tooltip!, preferBelow: false, child: tapped);
  }
}
