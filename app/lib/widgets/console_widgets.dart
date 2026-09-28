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

/// Console-style widgets — inspired by Pro Tools / analog console hardware.
///
/// Design language:
/// - Recessed surfaces (dark fills + borders — no decorative drop shadows)
/// - Illuminated indicators (LED-like glow when active)
/// - Tight spacing, compact sizing
/// - Beveled edges, not rounded corners
/// - Monospace numerics
/// - Subdued chrome, vivid indicators
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'chrome_surface.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Console Toggle — replaces Material Switch
// LED-illuminated button: off = dark recessed, on = glowing indicator
// ─────────────────────────────────────────────────────────────────────────────

class ConsoleToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? activeColor;
  final String? label;

  const ConsoleToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.label,
  });

  @override
  State<ConsoleToggle> createState() => _ConsoleToggleState();
}

class _ConsoleToggleState extends State<ConsoleToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.activeColor ?? T.purple;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onChanged(!widget.value),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.label != null) ...[
              Text(
                widget.label!,
                style: TextStyle(fontSize: T.fontBody, color: T.textTertiary),
              ),
              const SizedBox(width: T.gapSm),
            ],
            _track(color),
          ],
        ),
      ),
    );
  }

  /// The switch itself. 36 x 18 in every theme -- a component's size
  /// does not vary by theme -- with two drawings.
  ///
  /// `raised`: a `bgControls` pill with no rim, and a round knob that
  /// carries the state in its colour, `chromeTabOn` on and
  /// `chromeTabOff` off. The knob is scaled to the 36 x 18 box.
  ///
  /// Everywhere else: the app's recessed well. Border-only chrome -- no
  /// decorative drop shadows; the recessed look comes from the bgDeep
  /// fill against the surrounding surface. (The active-knob glow stays:
  /// it is a functional LED indicator, not chrome.)
  Widget _track(Color color) {
    final raised = T.chromeStyle == ChromeStyle.raised;
    const w = 36.0;
    const h = 18.0;
    final knob = h - 4;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(raised ? h / 2 : 3),
        color: raised ? T.bgControls : T.bgDeep,
        border: raised
            ? null
            : Border.all(color: _hover ? T.borderStrong : T.border, width: 1),
      ),
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 80),
            left: raised
                ? (widget.value ? w - knob - 2 : 2)
                : (widget.value ? 18 : 0),
            top: 0,
            bottom: 0,
            child: Center(
              child: Container(
                width: raised ? knob : 16,
                height: raised ? knob : h - 2,
                margin: raised ? EdgeInsets.zero : const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  shape: raised ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: raised ? null : BorderRadius.circular(2),
                  // The caller's activeColor still carries the state
                  // where it names one -- the monitor DIM readout is
                  // amber in the status bar beside its switch --
                  // and chromeTabOn is the default, the accent
                  // reaching the body one piece at a time.
                  color: raised
                      ? (widget.value
                            ? (widget.activeColor ?? T.chromeTabOn)
                            : T.chromeTabOff)
                      : (widget.value ? color : T.bgControls),
                  // The raised knob reads its state from its own
                  // colour, so it takes no glow.
                  boxShadow: widget.value && !raised
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Console Selector — replaces DropdownButton
// Recessed selector with subtle border, no Material dropdown arrow
// ─────────────────────────────────────────────────────────────────────────────

/// The closed control of a dropdown, chosen by the theme's
/// [ControlStyle]. Read by [ConsoleSelector] and by the top bar's mix
/// presentation selector, so every dropdown in the app draws the same
/// control for a given theme.
///
/// - `filled`: a `controlBg` fill at `radiusSm` with a `controlFg` label and
///   caret, and a 1 px `border` rim at rest, because `controlBg` equals
///   `bgElevated` in Dark and Light and the control otherwise vanishes on a
///   dialog. Hover turns the rim `controlFg` at 25%.
/// - `well`: Classic, a [recessedWell] on `controlBg` at `radiusSm`,
///   `bgHover` under the pointer, `controlFg` label and caret.
/// - `outlined`: High Contrast, `controlBg` inside a `borderWidth`
///   `borderStrong` border at `radiusSm`, `controlFg` under the
///   pointer; `controlFg` label and caret.
///
/// Every style draws the control [height] 24 px tall with a `fontBody`
/// label and a [caretSize] 12 px caret.
///
/// [dim] is 1.0 for an enabled control and 0.4 for a disabled one; the
/// alpha is applied at the colour level so no composited layer is
/// introduced.
///
/// [focused] draws the keyboard focus ring: a 1.5 px rim in
/// [focusColor], the colour the transport buttons ring with in the
/// same theme, so a Tab through the window lands on one kind of ring.
abstract final class SelectorChrome {
  static const double height = 24;

  /// The focus ring colour, matched to `TransportButton`: the accent
  /// in the beveled and recessed chromes, `chromeTabOn` in the raised
  /// and outlined ones.
  static Color get focusColor => switch (T.chromeStyle) {
    ChromeStyle.raised || ChromeStyle.outlined => T.chromeTabOn,
    ChromeStyle.beveled || ChromeStyle.recessed => T.purple,
  };

  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 8);

  static BoxDecoration decoration({
    required bool hover,
    required double dim,
    bool focused = false,
  }) => switch (T.controlStyle) {
    // The rim is always present so hovering does not shift the
    // label.
    ControlStyle.filled => BoxDecoration(
      color: T.controlBg.withValues(alpha: dim),
      borderRadius: BorderRadius.circular(T.radiusSm),
      border: Border.all(
        color: focused
            ? focusColor
            : hover
            ? T.controlFg.withValues(alpha: 0.25)
            : T.border.withValues(alpha: dim),
        width: focused ? 1.5 : 1,
      ),
    ),
    // Classic's well; hover lifts the fill, focus rings the rim.
    ControlStyle.well => recessedWell(
      radius: T.radiusSm,
      fill: (hover ? T.bgHover : T.controlBg).withValues(alpha: dim),
      rim: focused ? focusColor : null,
    ),
    // High Contrast: a border at the theme's own width and radius, and no
    // other chrome.
    ControlStyle.outlined => BoxDecoration(
      color: T.controlBg.withValues(alpha: dim),
      borderRadius: BorderRadius.circular(T.radiusSm),
      border: Border.all(
        color: focused
            ? focusColor
            : (hover ? T.controlFg : T.borderStrong).withValues(alpha: dim),
        width: T.borderWidth,
      ),
    ),
  };

  static TextStyle labelStyle(double dim) => TextStyle(
    fontSize: T.fontBody,
    color: T.controlFg.withValues(alpha: dim),
  );

  static const double caretSize = T.iconXs;

  static Color caretColor(double dim) => T.controlFg.withValues(alpha: dim);

  /// Fill of the open menu.
  static Color get menuColor => T.controlBg;
}

/// The ground of a text field or a read-only path box in the raised style, null
/// in every other theme so a call site keeps its own drawing with `??`. The
/// field takes the dropdown's ground, `bgElevated` at [radius]. On Light's
/// dialog ground `bgElevated` is 1.07:1 against `bgSurface`, so the field takes
/// a 1 px `border` rim, the width the other themes' fields carry.
BoxDecoration? raisedField(double radius) => T.chromeStyle == ChromeStyle.raised
    ? BoxDecoration(
        color: T.bgElevated,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: T.border, width: 1),
      )
    : null;

class ConsoleSelector<V> extends StatefulWidget {
  final V value;
  final List<(V, String)> items;
  final ValueChanged<V> onChanged;
  final double? width;

  /// When false, the selector renders dimmed and ignores taps. Prefer
  /// this over wrapping in Opacity/IgnorePointer — it applies the alpha
  /// at the colour level instead of introducing a composited layer.
  final bool enabled;

  /// Per-item enable predicate. When supplied and it returns false for an
  /// item, that menu entry renders greyed and is not selectable. Defaults to
  /// all-enabled. The currently-selected value should be kept enabled by the
  /// caller so it can never become un-selectable.
  final bool Function(V value)? itemEnabled;

  /// Optional short annotation shown after an item's label (e.g. a fit chip
  /// like "−2 AE · no 9.1.6"). Return an empty string for no annotation.
  final String Function(V value)? itemNote;

  /// Optional tooltip for an item (e.g. the full explanation behind its
  /// [itemNote] / disabled state). Return an empty string for no tooltip.
  final String Function(V value)? itemTooltip;

  /// Optional badge widget shown after an item's label (e.g. a "Supported by
  /// YouTube" pill) — a standalone widget, distinct from the [itemNote] text
  /// chip. Rendered on both the menu option rows and the closed control (for
  /// the selected value). Return null for no badge.
  final Widget? Function(V value)? itemBadge;

  /// Optional leading widget shown before an item's label (e.g. a type
  /// icon). Rendered on both the menu option rows and the closed control
  /// (for the selected value). Return null for none.
  final Widget? Function(V value)? itemLeading;

  /// Optional per-item emphasis predicate. Items reporting false stay
  /// fully selectable but render their label in textSecondary — a
  /// middle tier between the obvious choices (textPrimary) and
  /// disabled ones (textTertiary, not selectable). Defaults to
  /// all-prominent.
  final bool Function(V value)? itemProminent;

  /// What assistive technology calls the control, e.g. "Output device".
  /// The selected item's label is announced as its value. Without it
  /// the control is announced by its value alone.
  final String? semanticLabel;

  const ConsoleSelector({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
    this.enabled = true,
    this.itemEnabled,
    this.itemNote,
    this.itemTooltip,
    this.itemBadge,
    this.itemLeading,
    this.itemProminent,
    this.semanticLabel,
  });

  @override
  State<ConsoleSelector<V>> createState() => _ConsoleSelectorState<V>();
}

/// Opens the menu from the trigger with focus on the selected row: the
/// arrow keys' way in, beside Enter and Space ([ActivateIntent]).
class _OpenRowsIntent extends Intent {
  const _OpenRowsIntent();
}

class _ConsoleSelectorState<V> extends State<ConsoleSelector<V>> {
  bool _hover = false;

  // Whether the trigger holds focus, for the semantics; [_focused] is
  // whether to draw the ring, which the focus highlight mode gates.
  bool _hasFocus = false;
  bool _focused = false;
  final MenuController _menu = MenuController();
  final GlobalKey _triggerKey = GlobalKey();
  final FocusNode _focusNode = FocusNode(debugLabel: 'ConsoleSelector');

  // One node per menu row, so a keyboard open can land focus on the
  // selected row and the arrow keys walk the list from there.
  final List<FocusNode> _rowNodes = [];

  // The menu's minimum row width: the trigger's rendered width, measured when
  // the menu opens. `widget.width` alone is not enough — a width-less selector
  // stretches to its parent's constraints (e.g. the ADM import dialog's
  // full-width column), and the open menu should never be narrower than the
  // closed control. Rows may still grow wider for notes/badges.
  double _menuMinWidth = 0;

  String get _label =>
      widget.items.where((e) => e.$1 == widget.value).firstOrNull?.$2 ?? '—';

  @override
  void initState() {
    super.initState();
    _syncRowNodes();
  }

  @override
  void didUpdateWidget(covariant ConsoleSelector<V> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRowNodes();
    // Disabling unmounts the detector without its callbacks firing, so
    // the states would otherwise come back stale on re-enable.
    if (!widget.enabled) {
      _hover = false;
      _hasFocus = false;
      _focused = false;
    }
  }

  void _setHover(bool v) {
    if (v != _hover) setState(() => _hover = v);
  }

  void _setHasFocus(bool v) {
    if (v != _hasFocus) setState(() => _hasFocus = v);
  }

  void _setFocused(bool v) {
    if (v != _focused) setState(() => _focused = v);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    for (final node in _rowNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncRowNodes() {
    while (_rowNodes.length > widget.items.length) {
      _rowNodes.removeLast().dispose();
    }
    while (_rowNodes.length < widget.items.length) {
      _rowNodes.add(FocusNode(debugLabel: 'ConsoleSelector row'));
    }
  }

  bool _rowEnabled(V value) => widget.itemEnabled?.call(value) ?? true;

  /// Opens the menu. The laid-out trigger is measured first so the rows
  /// are at least as wide as the closed control (see [_menuMinWidth]).
  /// [focusRow] is the keyboard path: once the menu has built, focus
  /// lands on the selected row (or the first enabled one), so the arrow
  /// keys walk the list from there and Enter picks a row. The pointer
  /// path leaves focus on the trigger, where the anchor puts it.
  void _open({required bool focusRow}) {
    final w = _triggerKey.currentContext?.size?.width;
    if (w != null && w != _menuMinWidth) {
      setState(() => _menuMinWidth = w);
    }
    _menu.open();
    if (focusRow) _focusSelectedRow();
  }

  void _focusSelectedRow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_menu.isOpen) return;
      var i = widget.items.indexWhere((e) => e.$1 == widget.value);
      if (i < 0 || !_rowEnabled(widget.items[i].$1)) {
        i = widget.items.indexWhere((e) => _rowEnabled(e.$1));
      }
      if (i >= 0 && i < _rowNodes.length) _rowNodes[i].requestFocus();
    });
  }

  void _toggle({required bool focusRow}) {
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _open(focusRow: focusRow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = widget.enabled ? 1.0 : 0.4;
    // Badge/leading for the current value, surfaced on the closed control
    // too (not just the menu rows) so the selected item's visual identity
    // stays visible.
    final selectedBadge = widget.itemBadge?.call(widget.value);
    final selectedLeading = widget.itemLeading?.call(widget.value);
    final content = Container(
      key: _triggerKey,
      width: widget.width,
      height: SelectorChrome.height,
      padding: SelectorChrome.padding,
      decoration: SelectorChrome.decoration(
        hover: _hover && widget.enabled,
        dim: dim,
        focused: _focused && widget.enabled,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selectedLeading != null) ...[
            Opacity(opacity: dim, child: selectedLeading),
            const SizedBox(width: T.gapSm),
          ],
          Expanded(
            child: Text(
              _label,
              overflow: TextOverflow.ellipsis,
              style: SelectorChrome.labelStyle(dim),
            ),
          ),
          if (selectedBadge != null) ...[
            Opacity(opacity: dim, child: selectedBadge),
            const SizedBox(width: T.gapSm),
          ],
          Icon(
            Icons.keyboard_arrow_down,
            size: SelectorChrome.caretSize,
            color: SelectorChrome.caretColor(dim),
          ),
        ],
      ),
    );
    // The trigger's own text and badge are excluded so the control is
    // announced once: as a button named [ConsoleSelector.semanticLabel]
    // whose value is the selected label.
    Widget semantics(Widget child, {VoidCallback? onTap}) => Semantics(
      button: true,
      enabled: widget.enabled,
      focusable: widget.enabled,
      focused: _hasFocus,
      label: widget.semanticLabel,
      value: _label,
      onTap: onTap,
      excludeSemantics: true,
      child: child,
    );
    if (!widget.enabled) {
      return semantics(IgnorePointer(child: content));
    }
    final activate = CallbackAction<Intent>(
      onInvoke: (_) {
        _toggle(focusRow: true);
        return null;
      },
    );
    // MenuAnchor instead of showMenu: the open menu rebuilds with this
    // widget, so items that change while it is showing — e.g. the
    // output-device list refreshing on hot-plug — appear live instead
    // of being frozen at open time.
    return semantics(
      onTap: () => _toggle(focusRow: false),
      MenuAnchor(
        controller: _menu,
        childFocusNode: _focusNode,
        consumeOutsideTap: true,
        alignmentOffset: const Offset(0, 4),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(SelectorChrome.menuColor),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.radiusSm),
              side: BorderSide(color: T.border),
            ),
          ),
        ),
        menuChildren: [
          for (final (i, item) in widget.items.indexed) _menuItem(i, item),
        ],
        // Focus and hover on one detector, as ChromePressable does.
        // Enter and Space reach it as ActivateIntent from the app's
        // default shortcuts; the arrow keys are bound here, since the
        // anchor binds them only inside the open menu. Escape is the
        // anchor's own DismissIntent while the menu is open. Inside the
        // app shell, Space stays the transport key: the shell's focus
        // scope handles it before it reaches any focused control, so
        // there Enter or the arrow keys open the menu. Dialogs sit
        // outside that scope, so Space opens the menu in them.
        builder: (context, controller, _) => FocusableActionDetector(
          focusNode: _focusNode,
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: _setHover,
          onFocusChange: _setHasFocus,
          onShowFocusHighlight: _setFocused,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowDown): _OpenRowsIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): _OpenRowsIntent(),
          },
          actions: {
            ActivateIntent: activate,
            ButtonActivateIntent: activate,
            _OpenRowsIntent: CallbackAction<_OpenRowsIntent>(
              onInvoke: (_) {
                if (controller.isOpen) {
                  _focusSelectedRow();
                } else {
                  _open(focusRow: true);
                }
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTapUp: (_) => _toggle(focusRow: false),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _menuItem(int index, (V, String) item) {
    final active = item.$1 == widget.value;
    final enabled = _rowEnabled(item.$1);
    final note = widget.itemNote?.call(item.$1) ?? '';
    final tip = widget.itemTooltip?.call(item.$1) ?? '';
    final badge = widget.itemBadge?.call(item.$1);
    final leading = widget.itemLeading?.call(item.$1);
    final prominent = widget.itemProminent?.call(item.$1) ?? true;
    // active wins over disabled so a (hypothetical) disabled current value
    // still reads as selected rather than ghosted. Disabled items use
    // textTertiary (the documented disabled token), not textGhost — a
    // greyed row's label and note must stay legible, since the note
    // explains *why* the item is unavailable. De-emphasized (but
    // selectable) items sit between the two on textSecondary.
    final labelColor = active
        ? T.purpleLight
        : !enabled
        ? T.textTertiary
        : prominent
        ? T.textPrimary
        : T.textSecondary;
    // MenuItemButton merges its subtree's semantics into one node, so
    // the row announces as a button with its label, note and, for the
    // current value, the selected state.
    final button = MenuItemButton(
      focusNode: _rowNodes[index],
      onPressed: enabled ? () => widget.onChanged(item.$1) : null,
      style: MenuItemButton.styleFrom(
        minimumSize: Size(math.max(widget.width ?? 0, _menuMinWidth), 28),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        overlayColor: T.bgHover,
      ),
      child: Semantics(
        selected: active,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              Opacity(opacity: enabled ? 1.0 : 0.4, child: leading),
              const SizedBox(width: T.gapSm),
            ],
            Text(
              item.$2,
              style: TextStyle(
                fontSize: T.fontBody,
                color: labelColor,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (badge != null) ...[const SizedBox(width: 10), badge],
            if (note.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                note,
                style: TextStyle(
                  fontSize: T.fontCaption,
                  color: T.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return tip.isEmpty ? button : Tooltip(message: tip, child: button);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Console Segment — replaces SegmentedButton / toggle
// Recessed multi-option bar with illuminated active segment
// ─────────────────────────────────────────────────────────────────────────────

class ConsoleSegment<V> extends StatelessWidget {
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V> onChanged;

  /// Fixed total control width. When set, segments become equal-width
  /// cells splitting it; when null, each segment hugs its own label.
  /// Size a shared column with [uniformWidth] — never a hardcoded px
  /// value, which breaks under the font-size modes.
  final double? width;

  /// Disabled segments dim, drop hover/tap affordances, and ignore
  /// input (matches [ConsoleSelector] and `AppButton`).
  final bool enabled;

  const ConsoleSegment({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width,
    this.enabled = true,
  });

  /// Horizontal padding inside each segment cell.
  static const double _cellHPad = 10;

  /// Cell label metrics, shared by rendering and [uniformWidth]'s
  /// measurement so the two cannot drift (colour is applied at the
  /// render site).
  static TextStyle _cellStyle({required bool active}) => TextStyle(
    fontSize: T.fontBody,
    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
  );

  /// The shared control width for a column of segmented controls: every
  /// cell of every control fits the widest label in [optionSets], at
  /// the *current* font scale. Measured with [TextPainter] rather than
  /// hardcoded so the result tracks font-size modes, label edits, and
  /// per-platform font metrics; callers must recompute on rebuild (a
  /// font-mode switch rebuilds watchers in the same frame).
  /// [context] matters: the rendered [Text] merges the ambient
  /// [DefaultTextStyle] (which can add letterSpacing/fontFamily) and
  /// applies the [MediaQuery] text scaler — measuring with a bare style
  /// under-reports the rendered width.
  static double uniformWidth(
    BuildContext context,
    List<List<String>> optionSets,
  ) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    var width = 0.0;
    for (final labels in optionSets) {
      var widest = 0.0;
      for (final label in labels) {
        final painter = TextPainter(
          // Measure at the active weight (w600) — the widest a label
          // ever renders.
          text: TextSpan(
            text: label,
            style: base.merge(_cellStyle(active: true)),
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        final w = painter.width;
        painter.dispose();
        if (w > widest) widest = w;
      }
      final need = labels.length * (widest + 2 * _cellHPad);
      if (need > width) width = need;
    }
    return (width + 2).ceilToDouble(); // +2: the control's 1 px borders
  }

  @override
  Widget build(BuildContext context) {
    // Dim by *multiplying* alpha — several tokens (purpleDim, border)
    // are intrinsically translucent, so replacing alpha would brighten
    // rather than fade them.
    Color dimmed(Color c) => enabled ? c : c.withValues(alpha: c.a * 0.4);
    // The raised style draws each option as its own chip rather than
    // as cells of one well: `bgControls` with a `chromeTabOn` label idle,
    // and selected the same rim-over-fill face the S / M toggle draws --
    // a `border` rim over `bgElevated` with `chromeTabOn` filling it one
    // border inside, under a dark `bgBase` label.
    //
    // The ink is `bgBase` (8.09:1 on `chromeTabOn`), matching
    // `SoloMuteButton`, rather than `borderLight` (6.04:1);
    // both clear the floor and the theme keeps one ink for a dark label
    // on an accent fill. `textPrimary` there is 1.83:1.
    //
    // The chips separate by a 1 px margin a side rather than 4 px
    // gaps, so the control measures the same in every
    // theme: a raised cell spends 2 px on that margin and 2 px on its
    // rim and pays for both out of its own padding, which is
    // [_cellHPad] less 2, and the outer rim stays in the layout as a
    // transparent border. Both drawings come to
    // 2 + n x (label + 2 x [_cellHPad]), which is what [uniformWidth]
    // measures.
    final raised = T.chromeStyle == ChromeStyle.raised;
    final transparent = T.border.withValues(alpha: 0);
    return Container(
      height: 24,
      width: width,
      decoration: BoxDecoration(
        color: raised ? null : T.bgDeep,
        borderRadius: BorderRadius.circular(raised ? T.radiusSm : 3),
        // The rim is transparent rather than absent in `raised`: a
        // border insets its child, so dropping it would give the row
        // 2 px more interior than the other themes' control has.
        border: Border.all(color: raised ? transparent : dimmed(T.border)),
      ),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: options.map((opt) {
          final active = opt.$1 == value;
          final label = Text(
            opt.$2,
            style: _cellStyle(active: active).copyWith(
              color: dimmed(
                raised
                    ? (active ? T.bgBase : T.chromeTabOn)
                    : (active ? T.purpleLight : T.textTertiary),
              ),
            ),
          );
          // The label in its own box, so the accent fill below wraps
          // the whole face rather than the glyphs: a Container that
          // aligns or pads its child hands it loose constraints, and a
          // DecoratedBox under those shrink-wraps.
          final labelBox = Container(
            padding: EdgeInsets.symmetric(
              horizontal: raised ? _cellHPad - 2 : _cellHPad,
            ),
            alignment: Alignment.center,
            child: label,
          );
          final cell = GestureDetector(
            onTap: enabled ? () => onChanged(opt.$1) : null,
            child: MouseRegion(
              cursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: Container(
                margin: raised ? const EdgeInsets.all(1) : EdgeInsets.zero,
                decoration: BoxDecoration(
                  color: raised
                      ? dimmed(active ? T.bgElevated : T.bgControls)
                      : (active ? dimmed(T.purpleDim) : Colors.transparent),
                  borderRadius: BorderRadius.circular(raised ? T.radiusSm : 2),
                  // Every raised chip carries the rim, so a selection
                  // does not resize the control: the idle one is
                  // transparent.
                  border: raised
                      ? Border.all(
                          color: active ? dimmed(T.border) : transparent,
                          width: T.borderWidth,
                        )
                      : null,
                ),
                child: raised && active
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                          color: dimmed(T.chromeTabOn),
                          borderRadius: BorderRadius.circular(
                            T.radiusSm - T.borderWidth,
                          ),
                        ),
                        child: labelBox,
                      )
                    : labelBox,
              ),
            ),
          );
          return width == null ? cell : Expanded(child: cell);
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Console LED — small indicator light
// ─────────────────────────────────────────────────────────────────────────────

class ConsoleLed extends StatelessWidget {
  final bool on;
  final Color? color;
  final double size;

  const ConsoleLed({
    super.key,
    required this.on,
    this.color,
    this.size = T.dotSm,
  });

  @override
  Widget build(BuildContext context) {
    // Default to the theme's dedicated indicator green, NOT typeObject
    // — keep element-taxonomy colors decoupled from status indicators
    // so a future change to typeObject doesn't recolor every LED.
    final c = color ?? T.indicatorGreen;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? c : T.bgDeep,
        border: Border.all(
          color: on ? c.withValues(alpha: 0.6) : T.border,
          width: 0.5,
        ),
        boxShadow: on
            ? [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 4)]
            : null,
      ),
    );
  }
}
