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
import 'chrome_surface.dart';

/// One workspace tab in the top bar: ELEMENTS, MIX, RENDERER.
///
/// Draws one of four tabs, chosen by the theme's [ChromeStyle]. Every
/// style draws the label at `fontBodyL`, at weight 400 when active and
/// 300 when inactive. The beveled and raised tabs track it at
/// `T.tracking(T.fontBodyL, 3)`; the recessed and outlined tabs at
/// 0.5 px. The weights are the same in every theme so a text role has
/// one weight across the themes.
///
/// - `beveled` (the Dark theme): `chromeTabOn` when active over a 2 px
///   underline that fades from transparent to `chromeTabOn` and back, centred
///   15 px below the label's centre; `chromeTabOff` when inactive,
///   `textPrimary` on hover.
/// - `raised` (the Light theme): a 38 px button with no gap to its neighbours.
///   The active tab is a raised face: `chromeRim` outside, `chromeBg` with a
///   `chromeRimDark` edge and a soft shadow, `chromeRimLight` inside,
///   `chromeTabOn` text. An inactive tab is a 2 px `chromeTabOn` outline inset
///   3 px with a faint glow, `chromeTabOff` text, `chromeInk` on hover. The
///   label has no inner text shadow; the face's drop shadow is [RaisedFace]'s.
/// - `recessed` (Classic) and `outlined` (High Contrast): see
///   [_buildRecessed] and [_buildOutlined].
///
/// The underline styles size the underline to the measured glyph
/// width: under a 114 px centred text box with a 102 px glyph run, the
/// line is 102 px.
///
/// Self-tracks theme and font mode: the host constructs it inside a
/// `for`, never `const`, but the gallery may not.
class TopbarTab extends ConsumerStatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const TopbarTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  ConsumerState<TopbarTab> createState() => _TopbarTabState();
}

class _TopbarTabState extends ConsumerState<TopbarTab> {
  bool _hover = false;
  bool _pressed = false;

  /// Measure the rendered width of the label so the underline matches
  /// the glyph run (not a fudged per-character multiplier).
  ///
  /// Takes a layout-only style (family, size, weight, letterSpacing).
  /// Colour does not affect glyph advance widths. The [TextPainter] is
  /// disposed before returning to avoid leaking the engine's paragraph
  /// handle across rebuilds.
  double _labelWidth(TextStyle layoutStyle) {
    final tp = TextPainter(
      text: TextSpan(text: widget.label, style: layoutStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  /// The weight of the label in every style: 400 when active and 300
  /// when inactive.
  FontWeight get _weight => widget.active ? FontWeight.w400 : FontWeight.w300;

  /// The label's layout style (family, size, tracking) at the active
  /// weight. The family is named explicitly so a measurement runs in
  /// the face the Text inherits from the app theme, not the platform
  /// default. Every tab reserves the width of its label at this weight
  /// and its underline or slot is measured from it, so a tab keeps its
  /// width when the weight changes with the active state and the row
  /// does not reflow on a switch.
  TextStyle _activeLayoutStyle(double letterSpacing) => TextStyle(
    fontFamily: T.uiFamily,
    fontSize: T.fontBodyL,
    fontWeight: FontWeight.w400,
    letterSpacing: letterSpacing,
  );

  /// The label in [color] at the state's weight, centred in a box
  /// [width] wide, the active label's width. The beveled and recessed
  /// tabs tween the colour; the outlined and raised tabs change it at
  /// once with their face.
  Widget _label({
    required Color color,
    required double letterSpacing,
    required double width,
    bool animated = true,
  }) {
    final style = _activeLayoutStyle(
      letterSpacing,
    ).copyWith(fontWeight: _weight, color: color);
    // The box is the measured width, so the run must not wrap or clip
    // on a sub-pixel difference between measurement and layout.
    final text = Text(
      widget.label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
    );
    return SizedBox(
      width: width,
      child: Center(
        child: animated
            ? AnimatedDefaultTextStyle(
                duration: T.motionMed,
                curve: Curves.easeOut,
                style: style,
                child: text,
              )
            : DefaultTextStyle(style: style, child: text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the theme changes: otherwise a theme switch while
    // hovering the active tab would leave stale T.* colours until the
    // next hover event. Font mode too, for the size read below.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: T.topbar,
          child: switch (T.chromeStyle) {
            ChromeStyle.beveled => _buildBeveled(),
            ChromeStyle.raised => _buildRaised(),
            ChromeStyle.recessed => _buildRecessed(),
            ChromeStyle.outlined => _buildOutlined(),
          },
        ),
      ),
    );
  }

  Widget _buildBeveled() {
    // The label is fontBodyL in every style.
    final tracking = T.tracking(T.fontBodyL, 3);
    final width = _labelWidth(_activeLayoutStyle(tracking));
    final label = _label(
      color: widget.active
          ? T.chromeTabOn
          : (_hover ? T.textPrimary : T.chromeTabOff),
      letterSpacing: tracking,
      width: width,
    );
    final transparent = T.chromeTabOn.withValues(alpha: 0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: T.gapMd),
      child: Stack(
        children: [
          Center(child: label),
          // The underline's centre sits 15 px below the label centre.
          Positioned(
            top: T.topbar / 2 + 14,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedContainer(
                duration: T.motionMed,
                curve: Curves.easeOut,
                height: 2,
                width: widget.active ? width : 0.0,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [transparent, T.chromeTabOn, transparent],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Classic: the label over a 4 px slot sunk into the
  /// plate (a [recessedWell] at radius 2) with a 2 px `purple` bar lit
  /// in its lower half. Only the active tab has the slot; an inactive
  /// tab is its label alone.
  Widget _buildRecessed() {
    final width = _labelWidth(_activeLayoutStyle(0.5));
    final label = _label(
      color: widget.active
          ? T.chromeTabOn
          : (_hover ? T.textSecondary : T.chromeTabOff),
      letterSpacing: 0.5,
      width: width,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: T.gapLg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          label,
          const Spacer(),
          AnimatedOpacity(
            duration: T.motionMed,
            opacity: widget.active ? 1 : 0,
            child: Container(
              height: 4,
              width: width,
              margin: const EdgeInsets.only(bottom: 4),
              decoration: recessedWell(radius: 2),
              alignment: Alignment.bottomCenter,
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: T.purple,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// High Contrast: a 28 px block at `radiusSm`. Active is `chromeTabOn`
  /// filled with an `accentFg` label; inactive is a `chromeTabOff`
  /// label that takes a `borderWidth` `chromeRimLight` outline under
  /// the pointer.
  Widget _buildOutlined() {
    final active = widget.active;
    final label = _label(
      color: active ? T.accentFg : T.chromeTabOff,
      letterSpacing: 0.5,
      width: _labelWidth(_activeLayoutStyle(0.5)),
      animated: false,
    );
    return Center(
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: active ? T.chromeTabOn : T.chromeTabOn.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(
            color: !active && _hover
                ? T.chromeRimLight
                : T.chromeRimLight.withValues(alpha: 0),
            width: T.borderWidth,
          ),
        ),
        child: Center(child: label),
      ),
    );
  }

  Widget _buildRaised() {
    final active = widget.active;
    // The label is fontBodyL in every style.
    final tracking = T.tracking(T.fontBodyL, 3);
    final label = _label(
      color: active ? T.chromeTabOn : (_hover ? T.chromeInk : T.chromeTabOff),
      letterSpacing: tracking,
      width: _labelWidth(_activeLayoutStyle(tracking)),
      animated: false,
    );
    // The 12 px side padding is measured from the outer edge,
    // so the text sits 9 px inside the face's innermost rim.
    final Widget box = active
        ? RaisedFace(
            radius: T.radius,
            pressed: _pressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Center(child: label),
            ),
          )
        // Inactive: the accent outline with its glow, inset 3 px.
        : AccentOutline(
            radius: T.radius - 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: Center(child: label),
            ),
          );
    return Center(child: SizedBox(height: 38, child: box));
  }
}
