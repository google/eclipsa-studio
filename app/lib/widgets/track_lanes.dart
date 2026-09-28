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

import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../waveform/waveform_style.dart';

/// The chrome of an audio element's lanes on the timeline, per
/// [ChromeStyle]: the block around the channel lanes, the lanes' own
/// fill, the channel label cells in the gutter beside them and the
/// format chip at the block's end. The Elements view composes these
/// around `MultiChannelWaveform`; the Theme Gallery renders them with
/// fixed values.
///
/// - `recessed` (Classic): the block is the element's colour at 4%
///   inside a 0.5 px border of it at 25%, at `radiusSm`; lanes paint
///   no fill of their own; a label is `fontSmall` `textSecondary`; the
///   chip is `fontMeter` in the element's colour at 70% on `bgDeep` at
///   70%, radius 2.
/// - `outlined` (High Contrast): the block is the element's colour at 10%
///   inside a `borderWidth` border of it at full strength; lanes paint
///   no fill; a `textPrimary` label; the chip is the element's colour
///   on `bgBase`.
/// - `beveled` (the Dark theme): 20 px lanes of `bgSurface` (`#16181B`) divided
///   by 1 px `border` lines (`#3C3D50`) inside a 1 px `border` edge, no radius;
///   a label cell is 34 px of `bgDeep` (within 7/255 of `#111217` at 78%) with
///   a white label; the chip is `videoInk` on `bgBase` at 92%, radius 2,
///   tracking -0.3.
/// - `raised` (the Light theme): 20 px lanes of `bgControls` (`#16181B`, within
///   3/255) divided by 1 px `borderLight` lines (`#232B3A`) inside a 1 px
///   `borderLight` edge, no radius; a label cell is a `bgControls` chip inside
///   a 1 px `borderLight` border at radius 4, 2 px in from the lane's top and
///   bottom, with a `chromeTabOn` label; the chip is `chromeTabOn` text with no
///   ground.
///
/// Lanes are 2 px apart and labels are regular weight in every style.
/// Labels are drawn at `fontSmall` and chips at `fontMeter` in every
/// style. The waveform's colour stays the element type's in every
/// style.
BoxDecoration trackBlockDecoration(Color elementColor) =>
    switch (T.chromeStyle) {
      ChromeStyle.recessed => BoxDecoration(
        color: elementColor.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: elementColor.withValues(alpha: 0.25),
          width: trackBlockBorderWidth(),
        ),
      ),
      // High Contrast: the element colour at full strength, `borderWidth`
      // wide, around a 10% fill.
      ChromeStyle.outlined => BoxDecoration(
        color: elementColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: elementColor, width: trackBlockBorderWidth()),
      ),
      // The block's fill shows between the lanes as their dividers, and
      // its border, in the same colour, insets the lanes so the outer
      // edge is as wide as a divider.
      ChromeStyle.beveled => BoxDecoration(
        color: T.border,
        border: Border.all(color: T.border, width: trackBlockBorderWidth()),
      ),
      ChromeStyle.raised => BoxDecoration(
        color: T.borderLight,
        border: Border.all(
          color: T.borderLight,
          width: trackBlockBorderWidth(),
        ),
      ),
    };

/// Width of the block's border: 0.5 px in `recessed` (Classic),
/// `borderWidth` (2) in `outlined` (High Contrast), 1 px in `beveled`
/// and `raised`. The gutter beside the block pads by the same amount
/// so its cells stay level with the lanes.
double trackBlockBorderWidth() => switch (T.chromeStyle) {
  ChromeStyle.recessed => 0.5,
  ChromeStyle.outlined => T.borderWidth,
  ChromeStyle.beveled || ChromeStyle.raised => 1,
};

/// The lanes' own fill, or null where the waveform paints only its
/// wave (`recessed` and `outlined`).
Color? trackLaneFill() => switch (T.chromeStyle) {
  ChromeStyle.recessed || ChromeStyle.outlined => null,
  ChromeStyle.beveled => T.bgSurface,
  ChromeStyle.raised => T.bgControls,
};

/// [base] with the lane fill and corner of the active style.
WaveformStyle trackLaneStyle(WaveformStyle base) {
  final fill = trackLaneFill();
  if (fill == null) return base;
  return base.copyWith(backgroundColor: fill, borderRadius: 0);
}

/// Space between two lanes, the same in every theme; a component's size does
/// not vary by theme, only how it is drawn and coloured.
double trackLaneSpacing() => 2;

/// The ground behind the panel column and the label gutter, drawn as
/// one strip down the whole sidebar.
///
/// Its colour is [T.trackPanelBg]. The card drawing needs a ground
/// darker than the card: `#101010` under `#282828` panels, and Light
/// keeps the relation on its own ramp, `bgDeep` `#CFCBC5` under
/// `bgSurface` `#E7E4DF` cards. The Dark theme puts the strip at
/// `#181716`, a warm grey above the page ground.
Color trackPanelStripColor() => T.trackPanelBg;

/// The line along the bottom of one track row, under its controls
/// panel and across its channel-label gutter and waveform lanes, so
/// each row is separated from end to end (ES-759): 0.5 px [T.border] in
/// the beveled and recessed drawings, [T.borderWidth] in the outlined
/// one, and none in `raised`, whose panels are cards.
BorderSide? trackRowDivider() => switch (T.chromeStyle) {
  ChromeStyle.beveled ||
  ChromeStyle.recessed => BorderSide(color: T.border, width: 0.5),
  ChromeStyle.outlined => BorderSide(color: T.border, width: T.borderWidth),
  ChromeStyle.raised => null,
};

/// The ground behind one track's controls panel, in the sidebar column
/// left of the lanes. Two drawings:
///
/// - `beveled`, `recessed` and `outlined`: no fill, the
///   [trackRowDivider] along the bottom, so the column reads as a list
///   of rows.
/// - `raised` (the Light theme): a [T.bgSurface] card at [T.radius],
///   no border, over the strip [trackPanelStripColor] paints.
BoxDecoration trackPanelDecoration() {
  final divider = trackRowDivider();
  if (divider != null) {
    return BoxDecoration(border: Border(bottom: divider));
  }
  return BoxDecoration(
    color: T.bgSurface,
    borderRadius: BorderRadius.circular(T.radius),
  );
}

/// The [trackRowDivider] as a decoration for the part of the row right
/// of the panel: the channel-label gutter and the waveform lanes. The
/// lanes and gutter cells keep at least 4 px clear above the row's
/// bottom edge, where the line is drawn.
BoxDecoration trackRowDividerDecoration() {
  final divider = trackRowDivider();
  return BoxDecoration(
    border: divider == null ? null : Border(bottom: divider),
  );
}

/// Vertical space the panel's own border takes outside its content:
/// 0.5 px for the hairline drawings, 0 for the card, matching the
/// border [trackPanelDecoration] returns. A test pins it against the
/// decoration.
double trackPanelBorderHeight() => switch (T.chromeStyle) {
  ChromeStyle.raised => 0,
  ChromeStyle.outlined => T.borderWidth,
  _ => 0.5,
};

/// Inset that separates one panel card from the ground and from the
/// next card. 4 px on every edge in `raised`, zero where the panel has
/// no card to separate.
///
/// 4 px is what the waveform block beside it is inset by
/// (`EdgeInsets.symmetric(vertical: 4)` in `elements_view.dart`), so a
/// card's top edge lines up with its own block's and two adjacent
/// cards sit 8 px apart, as their blocks do. The horizontal inset is
/// the same number so the [T.radius] corners have ground to read
/// against at the column's own edges.
///
/// [TrackPanel] takes it out of the panel's width and padding, so the
/// column's width and the controls' box do not move.
EdgeInsets trackPanelMargin() => T.chromeStyle == ChromeStyle.raised
    ? const EdgeInsets.all(4)
    : EdgeInsets.zero;

/// [base] less whatever [trackPanelMargin] takes, floored at zero.
///
/// `_panelMinHeight` in `elements_view.dart` budgets the controls
/// column, this padding and [trackPanelVerticalOverhead], so a track
/// at that minimum overflows by the inset if the card's margin is
/// taken on top of the base padding. Subtracting it here keeps the
/// content box the same in every theme.
///
/// Where an edge of [base] is smaller than the margin the shortfall is
/// not recovered and the outer box grows by the difference.
/// [trackPanelVerticalOverhead] reports what that costs in height.
EdgeInsets trackPanelPadding(EdgeInsets base) {
  final m = trackPanelMargin();
  return EdgeInsets.fromLTRB(
    max(0.0, base.left - m.left),
    max(0.0, base.top - m.top),
    max(0.0, base.right - m.right),
    max(0.0, base.bottom - m.bottom),
  );
}

/// Height a [TrackPanel] with [base] padding needs beyond its content:
/// the border, plus whatever of [trackPanelMargin] the padding had no
/// room to give back.
///
/// `_panelMinHeight` in `elements_view.dart` adds it, so a track at
/// that minimum does not overflow by the panel's own drawing.
double trackPanelVerticalOverhead(EdgeInsets base) {
  final m = trackPanelMargin();
  final p = trackPanelPadding(base);
  return trackPanelBorderHeight() + m.vertical + p.vertical - base.vertical;
}

/// Padding one track's controls column lays out in. [TrackPanel] takes
/// [trackPanelMargin] out of it, so the box is the same in every
/// theme. `_AudioTrack` passes it; `VideoTrack` pads its own row.
///
/// Left and right are equal, so in `raised` the 4 px card margin
/// leaves 4 px between the card's edge and the controls on both sides
/// (ES-763).
const kTrackPanelPadding = EdgeInsets.only(
  left: 8,
  top: 6,
  right: 8,
  bottom: 4,
);

/// One track's controls panel: the ground, the inset that separates it
/// from the next, and the padding its [child] lays out in.
///
/// [width] is the column's width, which the panel keeps whatever the
/// margin is — the inset comes out of the panel, not out of the
/// column. [basePadding] is the padding the controls want; the margin
/// is taken out of it so [child] lays out in the same box in every
/// theme.
///
/// [child] must size itself to the row. `_AudioTrack` passes a Column
/// at the default `MainAxisSize.max`, which fills the bounded height
/// the row gives it; an opaque card short of its row would leave bare
/// ground above and below it.
///
/// Do not `const`-construct it. It reads `T.*` in [build], so a const
/// call site is canonicalised and skipped on a theme switch and the
/// panel stays on the old ground. Both call sites pass a non-const width.
class TrackPanel extends StatelessWidget {
  const TrackPanel({
    super.key,
    required this.width,
    required this.basePadding,
    required this.child,
  });

  final double width;
  final EdgeInsets basePadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final margin = trackPanelMargin();
    return Container(
      width: width - margin.horizontal,
      margin: margin,
      decoration: trackPanelDecoration(),
      padding: trackPanelPadding(basePadding),
      child: child,
    );
  }
}

/// One channel's label in the gutter beside its lane, [height] tall.
/// [show] is false when the lane is too shallow for a legible label;
/// the cell keeps its ground so the column stays continuous.
class ChannelLabelCell extends StatelessWidget {
  const ChannelLabelCell({
    super.key,
    required this.label,
    required this.height,
    required this.fontSize,
    required this.show,
    this.tooltip,
  });

  final String label;
  final double height;
  final double fontSize;
  final bool show;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final style = T.chromeStyle;
    Widget? text = show
        ? Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: fontSize,
                height: 1.0,
                letterSpacing: style == ChromeStyle.beveled
                    ? T.tracking(fontSize, -3)
                    : null,
                color: switch (style) {
                  ChromeStyle.recessed => T.textSecondary,
                  ChromeStyle.outlined => T.textPrimary,
                  ChromeStyle.beveled => T.white,
                  ChromeStyle.raised => T.chromeTabOn,
                },
              ),
            ),
          )
        : null;
    if (text != null && tooltip != null) {
      text = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 400),
        child: text,
      );
    }
    return switch (style) {
      ChromeStyle.recessed || ChromeStyle.outlined => SizedBox(
        height: height,
        width: double.infinity,
        child: text,
      ),
      ChromeStyle.beveled => Container(
        height: height,
        width: double.infinity,
        color: T.bgDeep,
        child: text,
      ),
      ChromeStyle.raised => Container(
        height: height,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: T.bgControls,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: T.borderLight, width: 1),
          ),
          child: text,
        ),
      ),
    };
  }
}

/// Compact info chip that sticks to the visible edge of a timeline
/// block and truncates when narrow. [color] is the element's colour,
/// which only `recessed` and `outlined` use.
class TrackInfoChip extends StatelessWidget {
  const TrackInfoChip({
    super.key,
    required this.text,
    required this.color,
    this.alignment = Alignment.centerRight,
    this.tooltip,
  });

  final String text;
  final Color color;
  final Alignment alignment;

  /// Optional hover explanation (e.g. the resampling annotation).
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final style = T.chromeStyle;
    final label = Text(
      text,
      style: switch (style) {
        ChromeStyle.recessed => TextStyle(
          color: color.withValues(alpha: 0.7),
          fontSize: T.fontMeter,
        ),
        ChromeStyle.outlined => TextStyle(color: color, fontSize: T.fontMeter),
        ChromeStyle.beveled => TextStyle(
          color: T.videoInk,
          fontSize: T.fontMeter,
          letterSpacing: T.tracking(T.fontMeter, -3),
        ),
        ChromeStyle.raised => TextStyle(
          color: T.chromeTabOn,
          fontSize: T.fontMeter,
        ),
      },
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
    Widget chip = switch (style) {
      ChromeStyle.recessed => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: T.bgDeep.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(2),
        ),
        child: label,
      ),
      ChromeStyle.outlined => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: T.bgBase,
        child: label,
      ),
      ChromeStyle.beveled => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: T.bgBase.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(2),
        ),
        child: label,
      ),
      ChromeStyle.raised => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: label,
      ),
    };
    if (tooltip != null) {
      chip = Tooltip(message: tooltip, child: chip);
    }
    return Align(alignment: alignment, child: chip);
  }
}
