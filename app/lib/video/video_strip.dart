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

import 'dart:ui' show Gradient;

import 'package:flutter/material.dart' hide Gradient;

import '../theme.dart';
import '../widgets/drop_zone.dart';

/// One action in the video strip's header: pop out, remove, open,
/// collapse.
class VideoStripAction {
  const VideoStripAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.gapBefore = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Space before this action in the header. `VideoPanel` sets 2
  /// between pop out and remove, 4 before collapse when a picture is
  /// loaded, and 0 otherwise.
  final double gapBefore;
}

/// The video strip between the top bar and the timeline: its ground,
/// the header naming the file with the actions at the right, and the
/// [body] (the picture, or the empty state) under it.
/// Presentational: `VideoPanel` owns the drop target, the file picker,
/// the resize handle and the video state and hands this widget its
/// parts; the Theme Gallery renders it with fixed ones.
///
/// In every layout the header lies over the body rather than above it,
/// so the picture gets the whole [height] (ES-683). The header draws only
/// its name at the left and its actions at the right, so the body takes
/// the pointer everywhere else. Collapsed, the header is the strip
/// itself, 24 px tall.
///
/// Two groundings, chosen by the theme's [ChromeStyle]:
///
/// - `recessed` and `outlined` ([ChromeStyleGround.flatGround]): the
///   body sits on `videoBg` (`bgBase`) with no surface of its own. Laid
///   over the picture the header has no fill and no border;
///   collapsed it is a `bgSurface` bar with a 1 px `border` line along
///   its bottom, as thick as the panel borders below it.
/// - `beveled` (Dark): one [height] surface, a radial `videoHi` to
///   `videoBg` gradient with a 1 px white at 17% along its top; the
///   header in `textMuted`. There is no drag pill: the strip's bottom
///   border is the resize handle and lights up on hover (ES-748).
/// - `raised` (Light): the same surface without the top line, the
///   header in `chromeTabOff`.
///
/// The gradient's centre and radii, (810, 0) and 648 x 254 on a
/// 1600 px frame in both styles, scale with the painted width.
///
/// Both styles draw the header over the picture: the well reaches 1 px
/// (`beveled`) and 11 px (`raised`) into the header's band.
class VideoStrip extends StatelessWidget {
  const VideoStrip({
    super.key,
    required this.height,
    required this.fileName,
    required this.hasMedia,
    required this.isStillImage,
    required this.visible,
    required this.actions,
    required this.body,
  });

  /// Height of the whole strip, the overlaid header included.
  final double height;

  /// Shown in the header; null reads "Video".
  final String? fileName;
  final bool hasMedia;
  final bool isStillImage;

  /// Expanded, or collapsed to the header alone.
  final bool visible;
  final List<VideoStripAction> actions;

  /// The picture or the empty state; ignored while collapsed.
  final Widget body;

  /// The header's height, the same in every layout.
  static const double headerHeight = 24;

  @override
  Widget build(BuildContext context) {
    final flat = T.chromeStyle.flatGround;
    if (!visible) {
      // Collapsed, the header is the strip. The flat-ground styles draw
      // their own bar; beveled and raised put theirs over the surface,
      // which is the ground there.
      return flat
          ? _header(overlay: false)
          : _Surface(height: headerHeight, child: _header(overlay: true));
    }
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        body,
        Positioned(top: 0, left: 0, right: 0, child: _header(overlay: true)),
      ],
    );
    return flat
        ? SizedBox(height: height, child: stack)
        : _Surface(height: height, child: stack);
  }

  /// Glyph and action ink. Each theme draws the header in its own
  /// colour; the sizes below are the app's.
  Color get _ink => switch (T.chromeStyle) {
    ChromeStyle.recessed => T.textTertiary,
    ChromeStyle.outlined => T.textSecondary,
    ChromeStyle.beveled => T.textMuted,
    ChromeStyle.raised => T.chromeTabOff,
  };

  /// The file name reads brighter than the glyph in the recessed and
  /// outlined styles once media is loaded; beveled and raised head the
  /// strip in one ink.
  Color get _nameInk => switch (T.chromeStyle) {
    ChromeStyle.recessed => hasMedia ? T.textSecondary : T.textTertiary,
    ChromeStyle.outlined => hasMedia ? T.textPrimary : T.textSecondary,
    ChromeStyle.beveled || ChromeStyle.raised => _ink,
  };

  IconData get _glyph =>
      isStillImage ? Icons.image_outlined : Icons.videocam_outlined;

  /// One header for every layout: 24 px tall, an [T.iconXs] glyph, the
  /// name at [T.fontCaption] and [T.iconSm] actions. A component's
  /// size does not vary by theme. Drawing this row at `iconMd`/`iconLg`
  /// glyphs and `fontBody`/`fontHeading` names would make the header
  /// taller in Dark and Light and take the difference out of the
  /// picture.
  ///
  /// [overlay] is the header laid over the body: it drops the fill and
  /// the border so the picture reads through. Only the flat-ground
  /// styles' collapsed bar keeps them; beveled and raised collapse onto
  /// their own surface, which is the ground there.
  ///
  /// The glyph and the name ignore the pointer, so a tap or double-click
  /// on the top of the picture reaches the body; only the actions take
  /// hits.
  Widget _header({required bool overlay}) => Container(
    height: headerHeight,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: overlay
        ? null
        : BoxDecoration(
            color: T.bgSurface,
            border: Border(bottom: BorderSide(color: T.border)),
          ),
    child: Row(
      children: [
        IgnorePointer(
          child: Icon(_glyph, size: T.iconXs, color: _ink),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: IgnorePointer(
            child: Text(
              fileName ?? 'Video',
              style: TextStyle(fontSize: T.fontCaption, color: _nameInk),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        for (final a in actions) ...[
          if (a.gapBefore > 0) SizedBox(width: a.gapBefore),
          _Action(action: a, color: _ink, size: T.iconSm),
        ],
      ],
    ),
  );
}

/// The empty state of the strip: one framed area for every theme, an
/// image glyph over the label and the format line, centred in the band
/// under the header. [dragOver] tints it with the accent as every drop
/// zone does. The frame is [DropZone]'s area drawing, so each theme
/// colours it as it colours the audio drop target (ES-780).
///
/// The area is [width] by [height] when the strip has room. In a
/// shorter strip it takes what is left under the header and [margin],
/// drops the format line under [hintHeight], and the drop zone scales
/// its glyph and label down under that. The same sizes in every theme,
/// because a component's size does not vary by theme. A tap anywhere in the
/// body, not only on the area, calls [onTap]; the header lies over the
/// body and takes the pointer first.
class VideoEmptyBody extends StatelessWidget {
  const VideoEmptyBody({
    super.key,
    required this.dragOver,
    required this.onTap,
    required this.primaryLabel,
    required this.secondaryLabel,
  });

  final bool dragOver;
  final VoidCallback? onTap;
  final String primaryLabel;
  final String? secondaryLabel;

  /// The area's size when the strip has room for it.
  static const double width = 320;
  static const double height = 160;

  /// Space kept between the area and the strip's edges, and between the
  /// area and the header's band.
  static const double margin = 8;

  /// Below this height the format line goes, and the glyph and label
  /// have the area to themselves.
  static const double hintHeight = 112;

  /// The band the area is centred in starts under the header.
  static const double _top = VideoStrip.headerHeight + margin;

  @override
  Widget build(BuildContext context) {
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final w = (constraints.maxWidth - 2 * margin).clamp(0.0, width);
        final h = (constraints.maxHeight - _top - margin).clamp(0.0, height);
        return Padding(
          padding: const EdgeInsets.only(
            top: _top,
            left: margin,
            right: margin,
            bottom: margin,
          ),
          child: Center(
            child: SizedBox(
              width: w,
              height: h,
              child: DropZone(
                variant: DropZoneVariant.area,
                icon: Icons.image_outlined,
                iconSize: T.iconHero,
                frame: false,
                primaryLabel: primaryLabel,
                secondaryLabel: h < hintHeight ? null : secondaryLabel,
                isDragOver: dragOver,
              ),
            ),
          ),
        );
      },
    );
    if (onTap == null) return body;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: body,
    );
  }
}

/// The strip's ground per [ChromeStyle]: a `videoBg` fill, or the
/// beveled and raised radial lift with Dark's top line.
class _Surface extends StatelessWidget {
  const _Surface({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: CustomPaint(
      painter: _SurfacePainter(
        hi: T.videoHi,
        lo: T.videoBg,
        topLine: T.chromeStyle == ChromeStyle.beveled,
      ),
      child: child,
    ),
  );
}

class _SurfacePainter extends CustomPainter {
  const _SurfacePainter({
    required this.hi,
    required this.lo,
    required this.topLine,
  });

  final Color hi;
  final Color lo;
  final bool topLine;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final cx = 810 / 1600 * w;
    final rx = 648 / 1600 * w;
    final ry = 254 / 1600 * w;
    final matrix = Matrix4.identity()
      ..translateByDouble(cx, 0, 0, 1)
      ..scaleByDouble(1, ry / rx, 1, 1)
      ..translateByDouble(-cx, 0, 0, 1);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = Gradient.radial(
          Offset(cx, 0),
          rx,
          [hi, lo],
          const [0.0, 1.0],
          TileMode.clamp,
          matrix.storage,
        ),
    );
    if (topLine) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, 1),
        Paint()..color = const Color(0x2BFFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(_SurfacePainter old) =>
      old.hi != hi || old.lo != lo || old.topLine != topLine;
}

class _Action extends StatelessWidget {
  const _Action({
    required this.action,
    required this.color,
    required this.size,
  });

  final VideoStripAction action;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: action.tooltip,
    child: InkWell(
      onTap: action.onTap,
      borderRadius: BorderRadius.circular(T.radiusSm),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(action.icon, size: size, color: color),
      ),
    ),
  );
}
