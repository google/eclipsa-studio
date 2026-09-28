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

/// Visual variant of a [DropZone].
///
/// The three variants share the same color and typography language but
/// differ in shape and size to fit different host surfaces:
///
/// * [compact] — per-track empty slot inside an existing audio track.
/// * [area]    — full empty-state block (add-new audio slot, empty
///               video panel).
/// * [overlay] — translucent scrim painted on top of existing content
///               to signal "drop to replace".
enum DropZoneVariant { compact, area, overlay }

/// Shared drop-target chrome for audio and video imports.
///
/// This widget is pure presentation — it does not own a [DropTarget]
/// or a file picker. Parents wrap it in a [DropTarget] (from the
/// `desktop_drop` package) and feed the current drag-over state via
/// [isDragOver]. Tapping is handled here only when [onTap] is
/// non-null, matching the click-to-browse affordance used by the empty
/// video panel and the "add new audio" slot.
class DropZone extends StatelessWidget {
  /// Visual variant to render.
  final DropZoneVariant variant;

  /// Leading icon (e.g. [Icons.audio_file_outlined]). Optional — the
  /// compact variant ignores this, and area/overlay variants render
  /// only when non-null.
  final IconData? icon;

  /// Main label. The caller is responsible for switching text on hover
  /// if desired (e.g. "No WAV file" → "Drop WAV file").
  final String primaryLabel;

  /// Optional secondary line (format hint). Ignored by [compact].
  final String? secondaryLabel;

  /// Whether a drag is currently hovering over this zone.
  final bool isDragOver;

  /// Per-track slots may override the accent with the element's color so
  /// the hover tint matches the track. Other variants default to
  /// [T.purple].
  final Color? accentColor;

  /// If non-null, the zone becomes tappable (opens a file picker in the
  /// caller). Adds a [GestureDetector] with an opaque hit test.
  final VoidCallback? onTap;

  /// Size of [icon] in the area and overlay variants. [T.iconXl] is the
  /// drop-target size; the video placeholder draws its glyph larger.
  final double iconSize;

  /// Whether the area variant draws its frame (the per-style fill,
  /// border and bevel lines). Without it the glyph and labels sit on
  /// the host's ground and only the drag-over tint is drawn; the video
  /// placeholder draws this way (ES-780).
  final bool frame;

  /// Height of the [DropZoneVariant.area] slot below the tracks, 124 px
  /// in every theme; a component's size does not vary by theme, only
  /// how it is drawn and coloured.
  static const double areaHeight = 80;

  const DropZone({
    required this.variant,
    required this.primaryLabel,
    required this.isDragOver,
    this.icon,
    this.secondaryLabel,
    this.accentColor,
    this.onTap,
    this.iconSize = T.iconXl,
    this.frame = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final Widget visual = switch (variant) {
      DropZoneVariant.compact => _buildCompact(),
      DropZoneVariant.area => _buildArea(),
      DropZoneVariant.overlay => _buildOverlay(),
    };
    if (onTap == null) return visual;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: visual,
    );
  }

  Widget _buildCompact() {
    final accent = accentColor ?? T.purple;
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDragOver ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(T.radiusMd),
      ),
      child: Center(
        child: Text(
          primaryLabel,
          style: TextStyle(
            fontSize: T.fontBody,
            color: accent.withValues(alpha: isDragOver ? 0.6 : 0.3),
          ),
        ),
      ),
    );
  }

  /// The full empty-state block, per [ChromeStyle]:
  ///
  /// - `beveled` (the Dark theme): `bgElevated` (`#1B1A1C`) under a 1 px white
  ///   at 20% along the top and a 1 px black at 58% along the bottom, no
  ///   radius; a 24 px `purple` glyph; `textGhost` (`#677283`) text tracked at
  ///   3% of its size.
  /// - `raised` (the Light theme): `bgSurface` at radius 8, no
  ///   border; a 24 px `chromeTabOn` glyph; `textTertiary` (`#697B9B`) text.
  /// - `recessed` (Classic): `bgControls` inside a 1.5 px `border` at
  ///   `radiusSm`; glyph, label and hint `textTertiary`.
  /// - `outlined` (High Contrast): `bgBase` inside a `borderWidth`
  ///   `borderStrong` outline at `radiusSm`; a `chromeTabOn` glyph,
  ///   `textSecondary` label and `textTertiary` hint.
  ///
  /// Every style draws the label at `fontBodyL` and the hint at
  /// `fontSmall`. A drag over the zone tints it with
  /// the accent in every style.
  Widget _buildArea() {
    final accent = accentColor ?? T.purple;
    final style = T.chromeStyle;
    final (Color glyph, Color label, Color hint) = switch (style) {
      ChromeStyle.beveled => (T.purple, T.textGhost, T.textGhost),
      ChromeStyle.raised => (T.chromeTabOn, T.textTertiary, T.textTertiary),
      ChromeStyle.recessed => (T.textTertiary, T.textTertiary, T.textTertiary),
      ChromeStyle.outlined => (T.chromeTabOn, T.textSecondary, T.textTertiary),
    };
    final decoration = switch (style) {
      _ when !frame => BoxDecoration(
        color: isDragOver ? T.purpleDim : const Color(0x00000000),
        borderRadius: BorderRadius.circular(T.radiusSm),
      ),
      // The bevel lines are overlays below rather than a two-sided
      // border: a theme switch lerps this decoration from the other
      // styles' rounded ones, and a border radius cannot be lerped
      // against non-uniform sides.
      ChromeStyle.beveled => BoxDecoration(
        color: isDragOver ? T.purpleDim : T.bgElevated,
        border: isDragOver ? Border.all(color: accent, width: 1) : null,
      ),
      ChromeStyle.raised => BoxDecoration(
        color: isDragOver ? T.purpleDim : T.bgSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      // Classic: a well on `bgControls`. The border width is constant
      // so a drag in or out animates only the colour and causes no
      // sub-pixel layout shift in the child column.
      ChromeStyle.recessed => BoxDecoration(
        color: isDragOver ? T.purpleDim : T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: isDragOver ? accent : T.border, width: 1.5),
      ),
      // High Contrast: a `borderWidth` `borderStrong` outline; the accent
      // while a drag is over it.
      ChromeStyle.outlined => BoxDecoration(
        color: isDragOver ? T.purpleDim : T.bgBase,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: isDragOver ? accent : T.borderStrong,
          width: T.borderWidth,
        ),
      ),
    };
    // At the large font the column can be taller than the box: High
    // Contrast's 2 px border leaves 76 of the 80 px area (ES-765).
    // scaleDown shrinks it only then; the ConstrainedBox keeps the
    // box's width on the labels, so they wrap as before rather than
    // shrink.
    final content = LayoutBuilder(
      builder: (context, constraints) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Icon(
                    icon,
                    size: iconSize,
                    color: isDragOver ? accent : glyph,
                  ),
                if (icon != null) const SizedBox(height: T.gapPair),
                Text(
                  primaryLabel,
                  style: TextStyle(
                    color: isDragOver ? accent : label,
                    fontSize: T.fontBodyL,
                    letterSpacing: style == ChromeStyle.beveled
                        ? T.tracking(T.fontBodyL, 3)
                        : null,
                  ),
                ),
                if (secondaryLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    secondaryLabel!,
                    style: TextStyle(
                      color: hint,
                      fontSize: T.fontSmall,
                      letterSpacing: style == ChromeStyle.beveled
                          ? T.tracking(T.fontSmall, 3)
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: decoration,
      child: frame && style == ChromeStyle.beveled && !isDragOver
          ? Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Container(height: 1, color: const Color(0x33FFFFFF)),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(height: 1, color: const Color(0x94000000)),
                ),
                content,
              ],
            )
          : content,
    );
  }

  Widget _buildOverlay() {
    final accent = accentColor ?? T.purple;
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.25),
        border: Border.all(color: accent, width: 2),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: iconSize, color: accent),
            if (icon != null) const SizedBox(height: T.gapPair),
            Text(
              primaryLabel,
              style: TextStyle(
                color: accent,
                fontSize: T.fontBodyL,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
