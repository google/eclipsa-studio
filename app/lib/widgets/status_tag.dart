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

/// A small tag that names a state or a kind: the loudness bar's LIVE,
/// MOMENTARY, SHORT-TERM and TRUE PEAK, the Visualizers panel's
/// EXPERIMENTAL, the Playback inspector's SELECTED, the Loudness
/// Report's IAMF and MON, and the Most common, Coming soon and YouTube
/// tags in the format, export and profile pickers.
///
/// One geometry for every tag: [label] at [textStyle] (`fontCaption`,
/// w600, 0.5 tracking), [hPad] by 2 px of padding, `radiusSm`, after
/// an [icon] of [iconSize] if one is given. The label keeps its case.
/// [color] is the ink of the label and icon; the fill is [color] at
/// 12%, or `bgControls` under a `textTertiary` ink when no colour is
/// given. [fill] replaces the fill. An [outlined] tag draws a 1 px rim
/// in [color] at 60% and no fill, so its label reads on the surface
/// behind it at full contrast.
///
/// Self-tracks theme and font mode, so a `const` instance redraws on a
/// switch.
class StatusTag extends ConsumerWidget {
  const StatusTag(
    this.label, {
    super.key,
    this.color,
    this.fill,
    this.icon,
    this.outlined = false,
  });

  /// Horizontal padding each side, inside any rim.
  static const double hPad = 5;

  /// The rim's width when [outlined].
  static const double rimWidth = 1;

  /// The icon's size.
  static const double iconSize = 11;

  /// The label's style; [color] is applied at the draw site.
  static TextStyle textStyle({Color? color}) => TextStyle(
    fontSize: T.fontCaption,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    color: color,
  );

  final String label;
  final Color? color;
  final Color? fill;
  final IconData? icon;
  final bool outlined;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final ink = color ?? T.textTertiary;
    final text = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: textStyle(color: ink),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: 2),
      decoration: BoxDecoration(
        color: outlined
            ? null
            : fill ??
                  (color == null ? T.bgControls : ink.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: outlined
            ? Border.all(color: ink.withValues(alpha: 0.6), width: rimWidth)
            : null,
      ),
      child: icon == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: iconSize, color: ink),
                const SizedBox(width: 4),
                Flexible(child: text),
              ],
            ),
    );
  }
}
