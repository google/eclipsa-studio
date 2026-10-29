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

/// Compact seekable transport progress bar.
///
/// Built by the Topbar on every tab of a Creator or Playback
/// workspace. Reads the playhead from [transportProvider] and seeks by
/// writing a fraction back via `TransportNotifier.seek`; the tick loop
/// syncs the engine. A loop region set on the Elements timeline
/// ([loopRegionProvider]) is drawn as a band on the track, in the same
/// purple and alphas as the timeline's own overlay.
///
/// While the IAMF duration scan runs ([transportAnalyzingProvider])
/// the duration is unknown, so the bar ignores gestures, consistent
/// with the transport buttons, and draws an `ANALYZING…` caption
/// against its right edge in place of the track. The caption takes the
/// bar's place in the top bar, so the transport controls beside it do
/// not move when the scan starts or ends. Outside the scan, a duration
/// of zero (a Creator session with no audio) draws the empty track and
/// ignores gestures.
class TransportScrubBar extends ConsumerStatefulWidget {
  /// Height of the visible track. The gesture target spans the
  /// widget's full [hitHeight].
  final double trackHeight;

  /// Height of the hit target (and of the widget itself).
  final double hitHeight;

  /// Track background. Defaults to `T.bgDeep`.
  final Color? trackColor;

  /// Played-portion fill, drawn as a left-to-right gradient. A
  /// single-color list paints a solid fill. Defaults to
  /// `[T.purple, T.pink]`.
  final List<Color>? fillColors;

  /// Playhead knob color. Defaults to `T.white`.
  final Color? knobColor;

  /// The loop-region band, for tests.
  static const loopBandKey = Key('transport-scrub-bar-loop-band');

  const TransportScrubBar({
    super.key,
    this.trackHeight = 5,
    this.hitHeight = 22,
    this.trackColor,
    this.fillColors,
    this.knobColor,
  });

  @override
  ConsumerState<TransportScrubBar> createState() => _TransportScrubBarState();
}

class _TransportScrubBarState extends ConsumerState<TransportScrubBar> {
  bool _hover = false;

  void _seekTo(double dx, double width) {
    if (width <= 0) return;
    // seek() clamps the fraction and arms the tick-loop sync.
    ref.read(transportProvider.notifier).seek(dx / width);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final transport = ref.watch(transportProvider);
    final analyzing = ref.watch(transportAnalyzingProvider);
    final loop = ref.watch(loopRegionProvider);
    if (analyzing) {
      return _frame(
        message:
            'Measuring the file duration. Playback is '
            'available when the analysis completes.',
        seekable: false,
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            'ANALYZING…',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: T.fontCaption,
              letterSpacing: 1.2,
              color: T.textGhost,
            ),
          ),
        ),
      );
    }
    final seekable = transport.durationSamples > 0;
    final frac = transport.fraction.clamp(0.0, 1.0).toDouble();
    final loopStart =
        loop?.startFraction(transport.durationSamples).clamp(0.0, 1.0) ?? 0.0;
    final loopEnd =
        loop?.endFraction(transport.durationSamples).clamp(0.0, 1.0) ?? 0.0;

    final trackColor = widget.trackColor ?? T.bgDeep;
    // High Contrast draws its controls as outlines on a black ground,
    // and bgDeep is that ground, so the track takes the theme's border
    // there. The played fill draws over it and keeps its own edge.
    final trackBorder = T.chromeStyle == ChromeStyle.outlined
        ? Border.all(color: T.border, width: 1)
        : null;
    final fillColors = widget.fillColors ?? [T.purple, T.pink];
    final knobColor = widget.knobColor ?? T.white;
    final radius = BorderRadius.circular(widget.trackHeight / 2);
    final knobRadius = (_hover ? 5.0 : 4.0).clamp(0.0, widget.hitHeight / 2);

    return _frame(
      message: seekable ? 'Click or drag to seek' : 'Nothing to seek',
      seekable: seekable,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: seekable
                ? (d) => _seekTo(d.localPosition.dx, width)
                : null,
            onHorizontalDragStart: seekable
                ? (d) => _seekTo(d.localPosition.dx, width)
                : null,
            onHorizontalDragUpdate: seekable
                ? (d) => _seekTo(d.localPosition.dx, width)
                : null,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Track.
                Container(
                  height: widget.trackHeight,
                  decoration: BoxDecoration(
                    color: trackColor,
                    borderRadius: radius,
                    border: trackBorder,
                  ),
                ),
                // Played fill.
                if (seekable && frac > 0)
                  Container(
                    height: widget.trackHeight,
                    width: width * frac,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: fillColors.length > 1
                            ? fillColors
                            : [fillColors.first, fillColors.first],
                      ),
                      borderRadius: radius,
                    ),
                  ),
                // Loop region, over the played fill so its start
                // stays visible while the playhead is inside it,
                // under the knob. The Elements overlay's drawing:
                // a 0.15 fill with 1 px edges at 0.5. Bands under
                // 1 px are skipped as there.
                if (seekable &&
                    loop != null &&
                    width * (loopEnd - loopStart) >= 1)
                  Positioned(
                    key: TransportScrubBar.loopBandKey,
                    left: width * loopStart,
                    child: Container(
                      height: widget.trackHeight,
                      width: width * (loopEnd - loopStart),
                      decoration: BoxDecoration(
                        color: T.purple.withValues(alpha: 0.15),
                        border: Border.symmetric(
                          vertical: BorderSide(
                            color: T.purple.withValues(alpha: 0.5),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Playhead knob. A bar squeezed under the knob's
                // width (a narrow window) draws no knob: the clamp
                // below would reject its negative maximum.
                if (seekable && width >= knobRadius * 2)
                  Positioned(
                    left: (width * frac - knobRadius).clamp(
                      0.0,
                      width - knobRadius * 2,
                    ),
                    child: Container(
                      width: knobRadius * 2,
                      height: knobRadius * 2,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: knobColor,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The tooltip, hover tracking and hit box of both drawings. The one
  /// [MouseRegion] stays at the same place in the tree when the scan
  /// ends, so a hover that began over the caption ends on exit.
  Widget _frame({
    required String message,
    required bool seekable,
    required Widget child,
  }) => Tooltip(
    message: message,
    preferBelow: false,
    child: MouseRegion(
      cursor: seekable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        height: widget.hitHeight,
        width: double.infinity,
        child: child,
      ),
    ),
  );
}
