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

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show Gradient;

import 'package:flutter/material.dart' hide Gradient;

import '../theme.dart';

/// Which strip of the window chrome a [ChromeSurface] draws.
enum ChromeSlice { titlebar, topbar, statusbar }

/// The ground of the window chrome, chosen by the theme's
/// [ChromeStyle], for one [slice] of it. The titlebar and the top bar
/// are different widgets in different `Column`s, so each draws its own
/// slice; where the theme makes them one surface, the top-bar slice
/// paints the same gradient offset by the titlebar's height and the
/// seam disappears.
///
/// - `beveled` (the Dark theme): one radial gradient across both strips,
///   `chromeHi` at its centre to `chromeBg` at its edge, with the centre at
///   (0.5, -0.087) of the painted width and radii of 0.4325 and 0.30375 of it;
///   a 1 px white at 20% along the top of the titlebar and a 1 px black at 58%
///   along the bottom of the top bar.
/// - `raised` (the Light theme). Titlebar: `chromeBg` under a 1 px
///   `chromeRimDark` top edge and a 2 px `chromeRimLight` highlight below it,
///   with no bottom line, so the strip and the top bar read as one surface. Top
///   bar: `chromeBg` with a 2 px `chromeRim` line above a 1 px `chromeRimDark`
///   bottom edge.
/// - `recessed`: Classic. One `chromeBg` plate for both strips with a
///   1 px `chromeRim` line under the top bar and no other line.
/// - `outlined`: High Contrast. `chromeBg` for both strips with a
///   `borderWidth` `chromeRim` rule under the top bar.
///
/// The status bar is the third slice, at `T.statusbar`:
///
/// - `beveled`: a vertical gradient, `statusbarBg` at the top to
///   `statusbarHi` at the bottom, with a 1 px white at 8% along the top
///   and a 1 px black at 58% along the bottom.
/// - `raised`: `chromeBg` under a 1 px `chromeRimDark` top edge and no other
///   rim; the other three sides are the window's own edges.
/// - `recessed` and `outlined`: `statusbarBg` under a 1 px
///   `chromeRim` top edge.
///
/// In every style the strip's content fills the strip, so a row of
/// text centres in it rather than sitting at the top.
///
/// Read by `TitlebarStrip`, `Topbar`, `StatusbarStrip` and the Theme
/// Gallery's strips.
class ChromeSurface extends StatelessWidget {
  const ChromeSurface({super.key, required this.slice, required this.child});

  final ChromeSlice slice;
  final Widget child;

  double get _height => switch (slice) {
    ChromeSlice.titlebar => T.titlebar,
    ChromeSlice.topbar => T.topbar,
    ChromeSlice.statusbar => T.statusbar,
  };

  @override
  Widget build(BuildContext context) {
    if (slice == ChromeSlice.statusbar) return _statusbar();
    final titlebar = slice == ChromeSlice.titlebar;
    switch (T.chromeStyle) {
      case ChromeStyle.beveled:
        return SizedBox(
          height: _height,
          child: CustomPaint(
            painter: _BeveledSurfacePainter(
              offset: titlebar ? 0 : T.titlebar,
              total: T.titlebar + T.topbar,
              hi: T.chromeHi,
              lo: T.chromeBg,
              topLine: titlebar,
              bottomLine: !titlebar,
            ),
            child: child,
          ),
        );
      case ChromeStyle.raised:
        // No line under the titlebar: a chromeRim bottom line would
        // split the strip from the top bar below, and the two form one
        // chrome surface in the other themes.
        final lines = titlebar
            ? [_line(top: 1, height: 2, color: T.chromeRimLight)]
            : [_line(bottom: 0, height: 2, color: T.chromeRim)];
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: T.chromeBg,
            border: titlebar
                ? Border(top: BorderSide(color: T.chromeRimDark, width: 1))
                : Border(bottom: BorderSide(color: T.chromeRimDark, width: 1)),
          ),
          // The lines are Positioned, so without `expand` the Stack
          // sizes to the row and pins it to the top of the strip
          // instead of filling the height the Container set.
          child: Stack(fit: StackFit.expand, children: [...lines, child]),
        );
      case ChromeStyle.recessed:
        // One matte plate for both strips; the only line is under the
        // top bar, where the plate meets the body.
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: T.chromeBg,
            border: titlebar
                ? null
                : Border(bottom: BorderSide(color: T.chromeRim, width: 1)),
          ),
          child: child,
        );
      case ChromeStyle.outlined:
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: T.chromeBg,
            border: titlebar
                ? null
                : Border(
                    bottom: BorderSide(
                      color: T.chromeRim,
                      width: T.borderWidth,
                    ),
                  ),
          ),
          child: child,
        );
    }
  }

  Widget _statusbar() {
    switch (T.chromeStyle) {
      case ChromeStyle.beveled:
        return Container(
          height: _height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [T.statusbarBg, T.statusbarHi],
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _line(top: 0, height: 1, color: const Color(0x14FFFFFF)),
              _line(bottom: 0, height: 1, color: const Color(0x94000000)),
              child,
            ],
          ),
        );
      case ChromeStyle.raised:
        // Only the top edge is rimmed. The bar is the window's bottom
        // strip, so its left, right and bottom edges are the window's
        // own and macOS's rounded corners cut a border drawn there: a
        // rim on those sides ran down the straight sides and stopped
        // where the curve began.
        // The top edge is the only one inside the window.
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: T.chromeBg,
            border: Border(top: BorderSide(color: T.chromeRimDark, width: 1)),
          ),
          child: child,
        );
      case ChromeStyle.recessed:
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: T.statusbarBg,
            border: Border(top: BorderSide(color: T.chromeRim, width: 1)),
          ),
          child: child,
        );
      case ChromeStyle.outlined:
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: T.statusbarBg,
            // 1 px, not `borderWidth`: the bar is 28 px and its row of
            // readouts fills 27 of them, so a 2 px edge overflows it.
            border: Border(top: BorderSide(color: T.chromeRim, width: 1)),
          ),
          child: child,
        );
    }
  }

  static Widget _line({
    double? top,
    double? bottom,
    required double height,
    required Color color,
  }) => Positioned(
    left: 0,
    right: 0,
    top: top,
    bottom: bottom,
    child: Container(height: height, color: color),
  );
}

/// The `beveled` chrome: a radial gradient painted for one slice of the
/// titlebar + top bar surface. At a 1600 px width the gradient is centred at
/// (800, -139) with radii 692 x 486; all four scale with the painted width, so
/// the surface reads the same at any window width.
class _BeveledSurfacePainter extends CustomPainter {
  const _BeveledSurfacePainter({
    required this.offset,
    required this.total,
    required this.hi,
    required this.lo,
    required this.topLine,
    required this.bottomLine,
  });

  /// Where this slice starts in the whole surface.
  final double offset;

  /// Height of the whole surface (titlebar + top bar).
  final double total;
  final Color hi;
  final Color lo;
  final bool topLine;
  final bool bottomLine;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final cx = w / 2;
    final cy = -139 / 1600 * w - offset;
    final rx = 692 / 1600 * w;
    final ry = 486 / 1600 * w;
    // A circular gradient of radius rx, squashed to ry vertically about
    // its centre, gives the ellipse.
    final matrix = Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..scaleByDouble(1, ry / rx, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
    final paint = Paint()
      ..shader = Gradient.radial(
        Offset(cx, cy),
        rx,
        [hi, lo],
        const [0.0, 0.9881],
        TileMode.clamp,
        matrix.storage,
      );
    canvas.drawRect(Offset.zero & size, paint);
    if (topLine) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, 1),
        Paint()..color = const Color(0x33FFFFFF),
      );
    }
    if (bottomLine) {
      canvas.drawRect(
        Rect.fromLTWH(0, size.height - 1, w, 1),
        Paint()..color = const Color(0x94000000),
      );
    }
  }

  @override
  bool shouldRepaint(_BeveledSurfacePainter old) =>
      old.offset != offset ||
      old.total != total ||
      old.hi != hi ||
      old.lo != lo ||
      old.topLine != topLine ||
      old.bottomLine != bottomLine;
}

/// The titlebar's title, the same in every theme: the macOS window
/// title, which is the system face at 13 px, semibold, with no
/// tracking. The strip stands in for the native titlebar the window
/// hides, so the title is not scaled by the font-size setting and is
/// not set in the app's UI face. Only the colour is the theme's,
/// `chromeInk`. On Windows the family is Segoe UI, the window title
/// face there, at the same size and weight; the app theme's family
/// would otherwise be inherited, since a null family is not the
/// platform default.
///
/// The Dark and Light themes once set it at 16 px, regular weight,
/// tracked -0.64 and 0.48, and the 2026-09 remake gave Classic and High Contrast
/// weights of their own; all of that was dropped for the one native
/// style.
TextStyle titlebarTitleStyle() => TextStyle(
  fontFamily: Platform.isMacOS
      ? '.AppleSystemUIFont'
      : Platform.isWindows
      ? 'Segoe UI'
      : null,
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: T.chromeInk,
);

/// The face of a titlebar control under the pointer ([pressed] while
/// held): `chromeInk` at 10%, or 16% pressed, laid over whatever ground
/// the strip has. The menu titles and the Windows minimize and maximize
/// buttons draw it. A translucent wash of the strip's own ink keeps the
/// ground visible under it: Dark's gradient, the other themes' flat
/// chrome and the landing page's ground behind the strip.
Color titlebarHoverFace({bool pressed = false}) =>
    T.chromeInk.withValues(alpha: pressed ? 0.16 : 0.10);

/// Classic's well: a hole cut in the plate. [fill] (`bgControls`, which
/// sits below the plate) inside a 1 px `chromeRimDark` rim, the wall
/// of the hole, over a 1 px `chromeRimLight` edge drawn on the plate
/// just below the shape, where the plate's edge catches light. Both
/// follow the outline, so a [round] well gets a true rim and a lit
/// edge under its curve rather than a band clipped by the circle. The
/// transport buttons, the play button, the clock and the dropdown draw
/// it, and the ring knob draws the same disc by hand; [rim] replaces
/// the wall with a 1.5 px ring of that colour for the focus state.
BoxDecoration recessedWell({
  required double radius,
  bool round = false,
  Color? fill,
  Color? rim,
}) => BoxDecoration(
  color: fill ?? T.bgControls,
  // A round well is a rectangle with a full-radius corner, not
  // BoxShape.circle: an AnimatedContainer tweens this decoration into
  // another style's on a theme switch, and BoxDecoration.lerp between
  // a circle and a rounded rectangle makes a decoration with both,
  // which BoxDecoration rejects.
  borderRadius: BorderRadius.circular(radius),
  border: rim == null
      ? Border.all(color: T.chromeRimDark)
      : Border.all(color: rim, width: 1.5),
  boxShadow: [BoxShadow(color: T.chromeRimLight, offset: const Offset(0, 1))],
);

/// The drawn part of the window titlebar: the surface, its lines and a
/// centred title between [leading] and [trailing]. `WindowTitlebar`
/// wraps it in the drag region and supplies the window controls; the
/// Theme Gallery renders it as it is.
class TitlebarStrip extends StatelessWidget {
  const TitlebarStrip({
    super.key,
    required this.title,
    required this.leading,
    required this.trailing,
    this.ground,
    this.dragRegion,
  });

  final String title;
  final Widget leading;
  final Widget trailing;

  /// Drawn instead of the theme's [ChromeSurface], with no lines, where
  /// the strip belongs to the page under it rather than to the chrome:
  /// the landing page, whose ground runs up to the window's top edge.
  final Widget? ground;

  /// Fills the strip under [leading], the title and [trailing]: the
  /// window's drag region. It is a sibling of the row rather than its
  /// parent, so a click on a control in [leading] or [trailing] reaches
  /// only that control and does not wait for the drag region's
  /// double-click recognizer to give up. The title ignores the pointer,
  /// so the region takes drags over it.
  final Widget? dragRegion;

  @override
  Widget build(BuildContext context) {
    final row = _row();
    final layers = [?dragRegion, row];
    final g = ground;
    if (g == null) {
      return ChromeSurface(
        slice: ChromeSlice.titlebar,
        child: Stack(fit: StackFit.expand, children: layers),
      );
    }
    return SizedBox(
      height: T.titlebar,
      child: Stack(fit: StackFit.expand, children: [g, ...layers]),
    );
  }

  Widget _row() => CustomMultiChildLayout(
    delegate: _TitlebarLayout(),
    children: [
      LayoutId(id: _TitlebarSlot.leading, child: leading),
      LayoutId(
        id: _TitlebarSlot.title,
        child: IgnorePointer(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titlebarTitleStyle(),
          ),
        ),
      ),
      LayoutId(id: _TitlebarSlot.trailing, child: trailing),
    ],
  );
}

enum _TitlebarSlot { leading, title, trailing }

/// Lays out [TitlebarStrip]'s row: the leading and trailing widgets at
/// their own widths against the strip's two ends, and the title centred
/// on the window when it fits between them there. A title too wide for
/// that is centred in the space between the two instead, and ellipsized
/// if it is wider than that space. With a Windows menu bar on the left
/// and the caption buttons on the right the two sides differ in width,
/// and centring in the gap alone would put the title off the window's
/// centre.
class _TitlebarLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    // Trailing first: the window controls keep their width, and leading
    // gets what is left, so the two never overlap on a narrow strip.
    final trail = layoutChild(
      _TitlebarSlot.trailing,
      BoxConstraints(maxWidth: size.width, maxHeight: size.height),
    );
    final lead = layoutChild(
      _TitlebarSlot.leading,
      BoxConstraints(
        maxWidth: math.max(0.0, size.width - trail.width),
        maxHeight: size.height,
      ),
    );
    positionChild(
      _TitlebarSlot.leading,
      Offset(0, (size.height - lead.height) / 2),
    );
    positionChild(
      _TitlebarSlot.trailing,
      Offset(size.width - trail.width, (size.height - trail.height) / 2),
    );

    final gap = math.max(0.0, size.width - lead.width - trail.width);
    final title = layoutChild(
      _TitlebarSlot.title,
      BoxConstraints(maxWidth: gap, maxHeight: size.height),
    );
    final centred = (size.width - title.width) / 2;
    final fitsCentred =
        centred >= lead.width &&
        centred + title.width <= size.width - trail.width;
    final x = fitsCentred ? centred : lead.width + (gap - title.width) / 2;
    positionChild(
      _TitlebarSlot.title,
      Offset(x, (size.height - title.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_TitlebarLayout oldDelegate) => false;
}

/// The inactive tab outline: a 2 px `chromeTabOn` outline at [radius], inset
/// [inset] px, with two glow layers -- a pale #D3F3FF at 40% blur 2 inside a
/// cyan #2FC7FF at 32% blur 6. Neither is the outline's own colour; collapsed
/// into one `chromeTabOn` at 32% they read as a muddy halo rather than a glow.
/// The inactive workspace tab draws it, and so does the selected tab of the
/// Settings dialog, which inverts the pair.
///
/// A `DecoratedBox` does not inset its child by the border it draws,
/// so the outline covers the outer 2 px of whatever padding [child]
/// carries.
class AccentOutline extends StatelessWidget {
  const AccentOutline({
    super.key,
    required this.radius,
    required this.child,
    this.inset = 3,
  });

  final double radius;
  final double inset;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(inset),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: T.chromeTabOn, width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x522FC7FF), blurRadius: 6),
          BoxShadow(color: Color(0x66D3F3FF), blurRadius: 2),
        ],
      ),
      child: child,
    ),
  );
}

/// The `raised` style's button face: three 1 px rims at insets 0, 1
/// and 2 — `chromeRim` outside at [radius], `chromeRimDark` over
/// `chromeBg` at [radius] − 1 under a five-layer drop shadow,
/// `chromeRimLight` at [radius] − 2. [pressed] draws the pressed face
/// instead. The active workspace tab and the transport
/// buttons draw it; a [radius] of half the size makes it round, as the
/// play button is.
class RaisedFace extends StatelessWidget {
  const RaisedFace({
    super.key,
    required this.radius,
    required this.child,
    this.pressed = false,
    this.lifted = true,
    this.face,
  });

  final double radius;
  final Widget child;

  /// The face colour, `chromeBg` when null. A caller tinting the face —
  /// a hover state, say — must pass it here rather than painting over
  /// the child: this layer sits under both inner rims and under the
  /// pressed drawing, so a fill on the child hides them.
  final Color? face;

  /// Draws the pressed face: the same three rims with
  /// the shadow stack turned inward, the face border at 80% and the
  /// inner rim in `chromeRim` rather than `chromeRimLight`.
  final bool pressed;

  /// Whether to draw the lift shadow. False for a disabled control, so
  /// it sits flat on the bar and stops reading as pressable.
  final bool lifted;

  /// The drop shadow, all five layers in pure black. An earlier version
  /// kept the first two and tinted them `chromeRimDark`, and the button
  /// read flat against the light bar: the three
  /// long layers are what lift it, and a warm grey at 6% over `#E7E4DF`
  /// is weaker than black at the same alpha.
  static const List<BoxShadow> _lift = [
    BoxShadow(color: Color(0x0F000000), offset: Offset(0, 2), blurRadius: 4),
    BoxShadow(color: Color(0x0A000000), offset: Offset(0, 7), blurRadius: 7),
    BoxShadow(color: Color(0x0A000000), offset: Offset(0, 16), blurRadius: 9),
    BoxShadow(color: Color(0x03000000), offset: Offset(0, 28), blurRadius: 11),
    BoxShadow(color: Color(0x05000000), offset: Offset(0, 32), blurRadius: 12),
  ];

  /// The pressed state's inset shadows, as one gradient down the face.
  ///
  /// Flutter has no inset `BoxShadow`. The pressed face insets four — (0, 2) r4
  /// at 10%, (0, 7) r7 at 9%, (0, 16) r9 at 5%, (0, 28) r11 at 1% — and a fifth
  /// at 0% alpha that draws nothing. Every offset is downward, so an inset
  /// shadow casts from the top edge: stacked they darken the top inner edge by
  /// about 22% and fade out below it, which is what these stops draw. An
  /// approximation, not the four blurs composited.
  static const LinearGradient _sink = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x38000000), Color(0x0F000000), Color(0x00000000)],
    stops: [0.0, 0.35, 0.85],
  );

  @override
  Widget build(BuildContext context) => Container(
    // Container, not DecoratedBox: only Container insets its child by
    // the border it draws (BoxDecoration.padding). Nested
    // DecoratedBoxes painted all three rims on the same rect, so the
    // last drawn — chromeRimLight — covered the other two and the
    // button read as one pale outline rather than a bevel.
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: T.chromeRim),
    ),
    child: Container(
      decoration: BoxDecoration(
        color: face ?? T.chromeBg,
        borderRadius: BorderRadius.circular(radius - 1),
        border: Border.all(
          color: pressed
              ? T.chromeRimDark.withValues(alpha: 0.8)
              : T.chromeRimDark,
        ),
        boxShadow: (pressed || !lifted) ? null : _lift,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius - 2),
          border: Border.all(color: pressed ? T.chromeRim : T.chromeRimLight),
          gradient: pressed ? _sink : null,
        ),
        child: child,
      ),
    ),
  );
}

/// The hover, press and focus state of a [ChromePressable], handed to
/// its builder so the drawing can ink itself for the current state.
class PressableState {
  const PressableState({
    required this.enabled,
    required this.hovered,
    required this.pressed,
    required this.focused,
  });

  final bool enabled;
  final bool hovered;
  final bool pressed;
  final bool focused;
}

/// The interaction state machine the chrome's pressable controls share:
/// hover, press and focus tracking, the semantics that name the control
/// and carry its tap action, and keyboard activation.
///
/// [builder] draws the control, so one implementation serves every
/// theme: `TransportButton` and `TransportPlayButton` draw every chrome
/// style from it and `AppButton` draws the app's text button.
/// `TopbarTab` keeps its own, because it takes no focus and hit-tests
/// opaque.
///
/// Written once because the second copy diverged from the first on all
/// three of the things that are easy to get wrong: it announced its
/// label twice, it dropped the tap action assistive technology needs,
/// and it drew its hover over the pressed face instead of under it.
class ChromePressable extends StatefulWidget {
  const ChromePressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.tooltip,
    this.semanticLabel,
    this.autofocus = false,
  });

  /// Null renders the control disabled: no cursor, no states, and the
  /// semantics report it as a disabled button.
  final VoidCallback? onTap;

  final Widget Function(BuildContext context, PressableState state) builder;

  final String? tooltip;

  /// Names the control for assistive technology. The drawing's own text
  /// is excluded when this is set, so the label is announced once.
  final String? semanticLabel;

  /// Takes focus when built, so Enter activates the control: the
  /// default action of a dialog.
  final bool autofocus;

  @override
  State<ChromePressable> createState() => _ChromePressableState();
}

class _ChromePressableState extends State<ChromePressable> {
  bool _hover = false;
  bool _pressed = false;
  bool _focused = false;

  void _setPressed(bool v) {
    if (!mounted || _pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  void didUpdateWidget(ChromePressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A control disabled mid-press loses its tap recognizer. The
    // recognizer's cancel arrives while the GestureDetector below
    // rebuilds, where setState is not allowed, so the press is cleared
    // here instead and [_setPressed] ignores the cancel. Without the
    // reset the control would draw pressed when enabled again.
    if (widget.onTap == null) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget result = FocusableActionDetector(
      enabled: enabled,
      autofocus: widget.autofocus,
      mouseCursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) {
        if (!mounted) return;
        setState(() => _hover = v);
      },
      onShowFocusHighlight: (v) {
        if (!mounted) return;
        setState(() => _focused = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        child: widget.builder(
          context,
          PressableState(
            enabled: enabled,
            hovered: _hover && enabled,
            pressed: _pressed,
            focused: _focused,
          ),
        ),
      ),
    );

    if (widget.semanticLabel != null) {
      result = Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel,
        // Carries the tap and the focus state itself: excludeSemantics
        // drops the subtree's own node, so without these the control
        // announces as a button that cannot be activated and a
        // keyboard user is never told which one holds focus.
        onTap: widget.onTap,
        focusable: enabled,
        focused: _focused,
        excludeSemantics: true,
        child: result,
      );
    }
    if (widget.tooltip != null) {
      result = Tooltip(
        message: widget.tooltip!,
        preferBelow: false,
        child: result,
      );
    }
    return result;
  }
}
