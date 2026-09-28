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
import 'console_widgets.dart';

/// The label beside the mix presentation selector. The beveled and
/// raised styles set it uppercase at `fontSmall` in `chromeInk`, with
/// -0.42 tracking in beveled and +0.42 in raised. The recessed and
/// outlined styles draw the app's form label, `T.styleLabel`, in
/// `chromeInk`. The weight is regular in every style so a text role has
/// one weight across the themes.
///
/// A ConsumerWidget that watches theme and font mode: it is constructed
/// `const` in the top bar and the gallery, so without the watch a theme
/// switch would leave it on the old chrome (pinned by
/// test/theme_font_staleness_test.dart).
class MixPresentationLabel extends ConsumerWidget {
  const MixPresentationLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return switch (T.chromeStyle) {
      // The label is fontSmall in every style, the size `T.styleLabel`
      // sets.
      ChromeStyle.beveled => Text(
        'MIX PRESENTATION',
        style: TextStyle(
          fontSize: T.fontSmall,
          color: T.chromeInk,
          letterSpacing: -0.42,
        ),
      ),
      ChromeStyle.raised => Text(
        'MIX PRESENTATION',
        style: TextStyle(
          fontSize: T.fontSmall,
          color: T.chromeInk,
          letterSpacing: 0.42,
        ),
      ),
      // The form label in the chrome's own ink.
      ChromeStyle.recessed || ChromeStyle.outlined => Text(
        'Mix Presentation',
        style: T.styleLabel.copyWith(color: T.chromeInk),
      ),
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mix presentation switcher — reachable from any tab, in both modes.
//
// Intentionally switcher-only: creating new mix presentations lives in the
// Mix view (`_addMixButton` / `_MixTabBar`'s `+` glyph), and Playback's
// Inspector tab keeps the full read-only mix detail. The Topbar just flips
// between presentations that already exist. `TopbarSelector` is the shared
// chrome; `_MixSelector` (Creator) and `_PlaybackMixSelector` (Playback)
// bind it to their respective providers.
//
// Not a `ConsoleSelector` because we need a leading check-mark on the
// active item and a menu that drops below the button (anchored to its
// render box, not the tap position). The closed control's chrome is
// shared with it through `SelectorChrome`, so the two cannot drift.
// ─────────────────────────────────────────────────────────────────────────────

class TopbarSelector extends ConsumerStatefulWidget {
  /// Display label per selectable item, in selection-index order.
  final List<String> items;

  /// Index of the active item, or -1 when [items] is empty.
  final int activeIndex;

  /// Ghost label shown when [items] is empty (selector renders inert).
  final String emptyLabel;

  final ValueChanged<int> onSelect;

  const TopbarSelector({
    super.key,
    required this.items,
    required this.activeIndex,
    required this.emptyLabel,
    required this.onSelect,
  });

  @override
  ConsumerState<TopbarSelector> createState() => _TopbarSelectorState();
}

class _TopbarSelectorState extends ConsumerState<TopbarSelector> {
  bool _hover = false;

  /// The same in every theme; a component's size does not vary by
  /// theme, only how it is drawn and coloured.
  static const double _width = 180;

  @override
  Widget build(BuildContext context) {
    // Rebuild when the theme changes so hover borders / label colors
    // repaint immediately (matches `TopbarTab`).
    // Font size too: the hosts (_MixSelector / _PlaybackMixSelector) are
    // const-constructed, so the label's T.fontBody read below would stay
    // frozen on font-mode change without a watch here.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final items = widget.items;

    final hasItems = items.isNotEmpty;
    final idx = hasItems ? widget.activeIndex.clamp(0, items.length - 1) : -1;
    final label = hasItems ? items[idx] : widget.emptyLabel;
    final labelStyle = SelectorChrome.labelStyle(1.0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: hasItems ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        // No-op when there are no items — an empty menu would be
        // confusing; how items come to exist is the caller's story.
        onTapUp: hasItems ? (_) => _showMenu() : null,
        child: Container(
          width: _width,
          height: SelectorChrome.height,
          padding: SelectorChrome.padding,
          // Same chrome as ConsoleSelector, so every dropdown in the app
          // draws the same control for a given theme.
          decoration: SelectorChrome.decoration(
            hover: _hover && hasItems,
            dim: 1.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: hasItems
                      ? labelStyle
                      : labelStyle.copyWith(color: T.textGhost),
                ),
              ),
              if (hasItems)
                Icon(
                  Icons.keyboard_arrow_down,
                  size: SelectorChrome.caretSize,
                  color: SelectorChrome.caretColor(1.0),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMenu() {
    // Snapshot at tap time: items/activeIndex could advance while the
    // menu is open if the backing provider updates mid-gesture; the
    // open menu intentionally keeps the tapped-state view.
    final items = widget.items;
    if (items.isEmpty) return;
    final activeIdx = widget.activeIndex;

    // Anchor the menu to the button's actual render box so it drops
    // cleanly below the selector regardless of where the Topbar sits
    // in the window. Tap-position-based positioning (the `ConsoleSelector`
    // pattern) works for Mix-view-local selectors but looked cramped on
    // the Topbar during prototyping.
    final button = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + button.size.height + 4,
      overlay.size.width - bottomRight.dx,
      overlay.size.height - bottomRight.dy,
    );

    final menuItems = <PopupMenuItem<int>>[
      for (var i = 0; i < items.length; i++)
        PopupMenuItem<int>(
          value: i,
          height: 32,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  child: i == activeIdx
                      ? Icon(Icons.check, size: T.iconSm, color: T.purpleLight)
                      : const SizedBox.shrink(),
                ),
                Flexible(
                  child: Text(
                    items[i],
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: T.fontBody,
                      color: i == activeIdx ? T.purpleLight : T.textPrimary,
                      fontWeight: i == activeIdx
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];

    showMenu<int>(
      context: context,
      position: position,
      constraints: BoxConstraints(minWidth: _width),
      color: SelectorChrome.menuColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.radiusSm),
        side: BorderSide(color: T.border),
      ),
      items: menuItems,
    ).then((v) {
      if (v == null || !mounted) return;
      widget.onSelect(v);
    });
  }
}
