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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import 'console_chip.dart';

/// A closed set of choices as a grid of equal buttons that fills the
/// width it is given, one of which is selected. The Renderer view's
/// output targets are one.
///
/// ## Layout
///
/// The buttons are [height] px tall and sit in rows [gap] px apart,
/// [gap] px between neighbours. The column count is the most buttons
/// that fit the width at the widest label, measured at the selected
/// weight and the current font size with [_hPad] each side, so every
/// label fits on one line in every font-size mode; see [columnCount].
/// Every row fills the width with equal buttons, so a last row with
/// fewer buttons has wider ones.
///
/// ## Drawing
///
/// Each option is a [ConsoleChip], which draws the four themes' faces,
/// the hover, press and focus drawings and an unavailable option's
/// dimmed face; its class doc has them. Each takes keyboard focus,
/// Enter activates it, and it announces as a button with its label, its
/// selected state and whether it is enabled, in a group of which one is
/// selected. The grid needs a bounded width.
///
/// An option in [unavailable] cannot be chosen. The selected option can
/// be unavailable: the Renderer view keeps the active target when the
/// output device has fewer channels than it needs.
///
/// Self-tracks theme and font mode, so a `const` instance redraws on a
/// switch.
class OptionGrid<V> extends ConsumerWidget {
  const OptionGrid({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.unavailable = const {},
  });

  /// The selected option.
  final V value;

  /// The options in grid order, each with its label.
  final List<(V, String)> options;

  /// Called with the option that was activated. Not called for the
  /// selected option or an [unavailable] one.
  final ValueChanged<V> onChanged;

  /// Options drawn dimmed that take no input.
  final Set<V> unavailable;

  /// The height of each button.
  static const double height = ConsoleChip.height;

  /// The space between buttons in a row and between rows.
  static const double gap = T.gapXs;

  /// Horizontal padding each side of a label, measured from the
  /// button's outer edge; a theme's rims draw inside it.
  static const double _hPad = ConsoleChip.hPad;

  /// The number of columns for [count] options in [width] px when the
  /// widest label measures [widestLabel] px: the most buttons that fit
  /// side by side at the widest label plus [_hPad] each side, [gap]
  /// apart; at least one, and never more than [count].
  static int columnCount({
    required double width,
    required double widestLabel,
    required int count,
  }) {
    final cell = widestLabel + 2 * _hPad;
    final fit = ((width + gap) / (cell + gap)).floor();
    return fit.clamp(1, math.max(1, count));
  }

  /// The width of the widest label at the selected weight, measured in
  /// [context]'s ambient text style and scale as the rendered [Text]
  /// is.
  static double widestLabel(BuildContext context, Iterable<String> labels) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: base.merge(ConsoleChip.labelStyle(selected: true)),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return widest;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        assert(constraints.hasBoundedWidth, 'OptionGrid needs a bounded width');
        final width = constraints.maxWidth;
        final columns = columnCount(
          width: width,
          widestLabel: widestLabel(context, [for (final o in options) o.$2]),
          count: options.length,
        );
        final rows = <Widget>[];
        for (var start = 0; start < options.length; start += columns) {
          final end = math.min(start + columns, options.length);
          rows.add(
            Row(
              children: [
                for (var i = start; i < end; i++) ...[
                  if (i > start) const SizedBox(width: gap),
                  Expanded(child: _button(options[i])),
                ],
              ],
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              rows[r],
            ],
          ],
        );
      },
    );
  }

  Widget _button((V, String) option) {
    final (v, label) = option;
    final selected = v == value;
    final live = !unavailable.contains(v);
    // The selected option keeps its tap, so it stays focusable and
    // announces as enabled; the tap reports nothing.
    return Semantics(
      inMutuallyExclusiveGroup: true,
      child: ConsoleChip(
        selected: selected,
        enabled: live,
        semanticLabel: label,
        onTap: () {
          if (!selected) onChanged(v);
        },
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
        ),
      ),
    );
  }
}
