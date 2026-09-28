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
import '../workspace/workspace_mode.dart';
import 'chrome_surface.dart';

/// Play, stop, skip and loop, bound to the transport providers. The
/// buttons themselves are [TransportButton] and [TransportPlayButton],
/// self-contained so the Theme Gallery can render them.
class TransportControls extends ConsumerWidget {
  const TransportControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final playing = ref.watch(playingProvider);
    final looping = ref.watch(loopingProvider);
    final mode = ref.watch(workspaceModeProvider);
    final loopVisible = mode == WorkspaceMode.creator;
    // While the IAMF duration scan runs the transport can't be
    // trusted (no duration, no scrubbing) — block starting playback
    // and seeking, and say why. Pausing/stopping stays available so
    // a transport that was already playing when the scan began can
    // always be silenced.
    final analyzing = ref.watch(transportAnalyzingProvider);
    // A Loudness Report pass or an ADM import blocks starting too: the
    // renderer is held offline and the output is silent until it ends.
    final blocked = ref.watch(transportBlockedProvider);
    final importing = ref.watch(admImportBusyProvider) > 0;
    final canStop = !analyzing || playing;

    final gap = SizedBox(width: TransportButton.gap);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TransportButton(
          icon: Icons.skip_previous,
          tooltip: analyzing ? 'Analyzing file…' : 'Return to start',
          onTap: analyzing
              ? null
              : () => ref.read(transportProvider.notifier).resetPosition(),
        ),
        gap,
        TransportPlayButton(
          playing: playing,
          disabledTooltip: analyzing
              ? 'Analyzing file…'
              : importing
              ? 'Importing ADM…'
              : 'Measuring loudness…',
          onTap: blocked && !playing
              ? null
              : () {
                  if (!playing) {
                    ref.read(transportProvider.notifier).markPlayStart();
                    ref.read(followOverrideProvider.notifier).set(false);
                  }
                  ref.read(playingProvider.notifier).toggle();
                },
        ),
        gap,
        TransportButton(
          icon: Icons.stop,
          tooltip: canStop ? 'Stop' : 'Analyzing file…',
          onTap: !canStop
              ? null
              : () {
                  ref.read(playingProvider.notifier).set(false);
                  if (ref.read(returnOnStopProvider)) {
                    ref.read(transportProvider.notifier).returnToPlayStart();
                  }
                },
        ),
        gap,
        TransportButton(
          icon: Icons.skip_next,
          tooltip: analyzing ? 'Analyzing file…' : 'Go to end',
          onTap: analyzing
              ? null
              : () {
                  final transport = ref.read(transportProvider);
                  ref
                      .read(transportProvider.notifier)
                      .seekSample(transport.durationSamples);
                },
        ),
        if (loopVisible) ...[
          gap,
          TransportButton(
            icon: Icons.loop,
            tooltip: looping ? 'Disable loop' : 'Enable loop',
            toggled: looping,
            onTap: () => ref.read(loopingProvider.notifier).toggle(),
          ),
        ],
        if (analyzing) ...[
          const SizedBox(width: T.gapMd),
          Tooltip(
            message:
                'Measuring the file duration. Playback is '
                'available when the analysis completes.',
            child: Text(
              'ANALYZING…',
              style: TextStyle(
                fontSize: T.fontCaption,
                letterSpacing: 1.2,
                color: T.textGhost,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One transport button: return to start, stop, go to end, loop.
///
/// Every style draws a [size] 30 px square, [gap] apart, with an
/// `iconSm` glyph. Four drawings, chosen by the theme's [ChromeStyle]:
///
/// - `beveled` (the Dark theme): no chrome, `textMuted` glyph, `textPrimary` on
///   hover.
/// - `raised` (the Light theme): a [RaisedFace] with a `chromeTabOn` glyph,
///   `chromeInk` on hover.
/// - `recessed`: Classic, a [recessedWell] at `radiusMd` with a
///   `textSecondary` glyph, `textPrimary` on hover.
/// - `outlined`: High Contrast, a `borderWidth` `chromeRimLight` square at
///   `radiusSm`, `chromeTabOff` glyph, `textPrimary` on hover.
///
/// A [toggled] button (loop) shows its state instead: `chromeTabOn` /
/// `textMuted` in beveled, `chromeTabOn` / `chromeTabOff` in raised
/// and outlined, `purpleLight` / `textInactive` in recessed. Disabled
/// (null [onTap]) draws the glyph in `textGhost`.
class TransportButton extends StatefulWidget {
  final IconData icon;

  /// Null renders the button disabled (ghost icon, no cursor).
  final VoidCallback? onTap;

  /// Non-null for a toggle (loop): the on/off state it shows.
  final bool? toggled;
  final String tooltip;

  const TransportButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.toggled,
  });

  /// Space between buttons, the same in every theme; a component's size
  /// does not vary by theme, only how it is drawn and coloured.
  static const double gap = T.gapSm;

  /// Side of the square hit box.
  static const double size = 30;

  @override
  State<TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<TransportButton> {
  Color _glyphColor(bool enabled, bool hovered) {
    if (!enabled) return T.textGhost;
    final toggled = widget.toggled;
    switch (T.chromeStyle) {
      case ChromeStyle.beveled:
        if (toggled == true) return T.chromeTabOn;
        return hovered ? T.textPrimary : T.textMuted;
      case ChromeStyle.raised:
        if (toggled != null && !toggled) {
          return hovered ? T.chromeInk : T.chromeTabOff;
        }
        return hovered ? T.chromeInk : T.chromeTabOn;
      case ChromeStyle.recessed:
        if (toggled != null) return toggled ? T.purpleLight : T.textInactive;
        return hovered ? T.textPrimary : T.textSecondary;
      case ChromeStyle.outlined:
        if (toggled != null) return toggled ? T.chromeTabOn : T.chromeTabOff;
        return hovered ? T.textPrimary : T.chromeTabOff;
    }
  }

  @override
  Widget build(BuildContext context) => ChromePressable(
    onTap: widget.onTap,
    tooltip: widget.tooltip,
    builder: _draw,
  );

  Widget _draw(BuildContext context, PressableState state) {
    final enabled = state.enabled;
    final glyph = Icon(
      widget.icon,
      size: T.iconSm,
      color: _glyphColor(enabled, state.hovered),
    );
    final size = TransportButton.size;
    final Widget box = switch (T.chromeStyle) {
      ChromeStyle.beveled => SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(T.radiusSm),
            border: Border.all(
              color: T.purple.withValues(alpha: state.focused ? 1 : 0),
              width: 1.5,
            ),
          ),
          child: glyph,
        ),
      ),
      ChromeStyle.raised => SizedBox(
        width: size,
        height: size,
        child: RaisedFace(
          radius: T.radius,
          pressed: state.pressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(T.radius - 2),
              border: Border.all(
                color: T.chromeTabOn.withValues(alpha: state.focused ? 1 : 0),
                width: 1.5,
              ),
            ),
            child: glyph,
          ),
        ),
      ),
      // A well sunk into the plate; focus rings it in the accent.
      ChromeStyle.recessed => AnimatedContainer(
        duration: T.motionFast,
        width: size,
        height: size,
        decoration: recessedWell(
          radius: T.radiusMd,
          fill: state.hovered ? T.bgHover : null,
          rim: state.focused ? T.purple : null,
        ),
        child: glyph,
      ),
      // A `borderWidth` square in `chromeRimLight`; focus takes the
      // accent, hover fills.
      ChromeStyle.outlined => AnimatedContainer(
        duration: T.motionFast,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: state.hovered ? T.bgHover : T.bgHover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(
            color: state.focused ? T.chromeTabOn : T.chromeRimLight,
            width: T.borderWidth,
          ),
        ),
        child: glyph,
      ),
    };

    return box;
  }
}

/// The play / pause button.
///
/// Every style draws it in a [size] 34 px box.
///
/// - `beveled` (the Dark theme): no chrome and a triangle in `purple`, the
///   accent; `textPrimary` on hover. Pause is two bars of the same height and
///   colour.
/// - `raised` (the Light theme): a round [RaisedFace] with a `chromeTabOn`
///   glyph, `chromeInk` on hover.
/// - `recessed`: Classic, a round [recessedWell] with the glyph in
///   `purple`.
/// - `outlined`: High Contrast, a solid `chromeTabOn` square at `radiusSm`
///   with the glyph in `accentFg`.
///
/// Disabled (null [onTap]) draws the glyph in `textGhost`.
class TransportPlayButton extends StatefulWidget {
  final bool playing;

  /// Null renders the button disabled (desaturated, no cursor).
  final VoidCallback? onTap;

  /// Why the button is disabled; the tooltip while [onTap] is null.
  final String disabledTooltip;

  const TransportPlayButton({
    super.key,
    required this.playing,
    required this.onTap,
    required this.disabledTooltip,
  });

  /// Diameter of the round hit box.
  static const double size = 34;

  @override
  State<TransportPlayButton> createState() => _TransportPlayButtonState();
}

class _TransportPlayButtonState extends State<TransportPlayButton> {
  @override
  Widget build(BuildContext context) => ChromePressable(
    onTap: widget.onTap,
    tooltip: widget.onTap == null
        ? widget.disabledTooltip
        : (widget.playing ? 'Pause (Space)' : 'Play (Space)'),
    builder: _draw,
  );

  Widget _draw(BuildContext context, PressableState state) {
    final enabled = state.enabled;
    final size = TransportPlayButton.size;
    final Widget box = switch (T.chromeStyle) {
      ChromeStyle.beveled => SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(T.radiusSm),
            border: Border.all(
              color: T.purple.withValues(alpha: state.focused ? 1 : 0),
              width: 1.5,
            ),
          ),
          child: CustomPaint(
            painter: _PlayGlyphPainter(
              playing: widget.playing,
              color: !enabled
                  ? T.textGhost
                  : state.hovered
                  ? T.textPrimary
                  : T.purple,
            ),
          ),
        ),
      ),
      ChromeStyle.raised => SizedBox(
        width: size,
        height: size,
        child: RaisedFace(
          radius: size / 2,
          pressed: state.pressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: T.chromeTabOn.withValues(alpha: state.focused ? 1 : 0),
                width: 1.5,
              ),
            ),
            child: Icon(
              widget.playing ? Icons.pause : Icons.play_arrow,
              size: T.iconLg,
              color: !enabled
                  ? T.textGhost
                  : state.hovered
                  ? T.chromeInk
                  : T.chromeTabOn,
            ),
          ),
        ),
      ),
      // A round well with the accent glyph in it. No accent fill: the
      // theme shows state by light, and the glyph carries it.
      ChromeStyle.recessed => AnimatedContainer(
        duration: T.motionFast,
        width: size,
        height: size,
        decoration: recessedWell(
          radius: size / 2,
          round: true,
          fill: state.hovered ? T.bgHover : null,
          rim: state.focused ? T.purple : null,
        ),
        child: Icon(
          widget.playing ? Icons.pause : Icons.play_arrow,
          size: T.iconMd,
          color: !enabled
              ? T.textGhost
              : state.hovered
              ? T.purpleLight
              : T.purple,
        ),
      ),
      // A solid `chromeTabOn` square with an `accentFg` glyph. Focus
      // rings it in `chromeRimLight`; disabled is an outline only.
      ChromeStyle.outlined => AnimatedContainer(
        duration: T.motionFast,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: !enabled
              ? T.chromeTabOn.withValues(alpha: 0)
              : state.hovered
              ? T.purpleLight
              : T.chromeTabOn,
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(
            color: !enabled
                ? T.chromeRimDark
                : state.focused
                ? T.chromeRimLight
                : T.chromeTabOn,
            width: T.borderWidth,
          ),
        ),
        child: Icon(
          widget.playing ? Icons.pause : Icons.play_arrow,
          size: T.iconMd,
          color: enabled ? T.accentFg : T.textGhost,
        ),
      ),
    };

    return box;
  }
}

/// The beveled style's play triangle: points (12, 6.14), (36, 20), (12, 33.86)
/// in a 40 px box, scaled to the painted size. Pause is two bars of the same
/// height, 6 wide with a 4 px gap, centred.
class _PlayGlyphPainter extends CustomPainter {
  const _PlayGlyphPainter({required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 40;
    final paint = Paint()..color = color;
    if (playing) {
      final top = 6.14 * k;
      final h = (33.86 - 6.14) * k;
      final w = 6 * k;
      final gap = 4 * k;
      final left = (size.width - (2 * w + gap)) / 2;
      canvas.drawRect(Rect.fromLTWH(left, top, w, h), paint);
      canvas.drawRect(Rect.fromLTWH(left + w + gap, top, w, h), paint);
      return;
    }
    final path = Path()
      ..moveTo(12 * k, 6.14 * k)
      ..lineTo(36 * k, 20 * k)
      ..lineTo(12 * k, 33.86 * k)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PlayGlyphPainter old) =>
      old.playing != playing || old.color != color;
}
