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

import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../state.dart';
import '../theme.dart';
import '../util/time_format.dart';
import '../widgets/track_lanes.dart';
import 'video_provider.dart';

/// Video track row — always visible. Shows video controls in the
/// left panel and the duration bar in the timeline area when a
/// video is loaded.
class VideoTrack extends ConsumerWidget {
  final double panelWidth;
  const VideoTrack({super.key, required this.panelWidth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    final video = ref.watch(videoProvider);
    if (!video.hasVideo) return const SizedBox.shrink();

    final duration = video.duration;
    if (duration == null || duration == Duration.zero) {
      return const SizedBox.shrink();
    }

    final raised = T.chromeStyle == ChromeStyle.raised;
    return SizedBox(
      height: 52,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TrackPanel(
            width: panelWidth,
            basePadding: const EdgeInsets.only(left: 8, top: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: Icon(
                      Icons.videocam_outlined,
                      size: T.iconSm,
                      // `raised` heads the panel with the chrome's
                      // blue glyph over a bright label; the other styles
                      // keep the video row's own cyan.
                      color: raised
                          ? T.chromeTabOn
                          : T.objCyan.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // One role and one size in every theme; only the ink
                // moves: `raised` heads the panel with `#E3E1F2`. The
                // audio rows below keep an element-coloured glyph over
                // a textSecondary name, so the column carries two
                // header treatments.
                Text(
                  'Video',
                  style: T.styleBodySecondary.copyWith(
                    color: raised ? T.textPrimary : T.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _DurationBar(video: video, duration: duration),
          ),
        ],
      ),
    );
  }
}

/// Binds the transport and viewport to a [VideoLane].
class _DurationBar extends ConsumerWidget {
  final VideoState video;
  final Duration duration;

  const _DurationBar({required this.video, required this.duration});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalSecs = ref.watch(
      transportProvider.select((t) => t.durationSeconds),
    );
    final viewport = ref.watch(timelineViewportProvider);
    final videoDurationSecs = duration.inMilliseconds / 1000.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (totalSecs <= 0) {
          return const SizedBox.shrink();
        }

        final visibleDuration = totalSecs / viewport.zoomLevel;
        final startTime = viewport.scrollOffset * (totalSecs - visibleDuration);
        final pxPerSec = width / visibleDuration;

        return VideoLane(
          barLeft: -startTime * pxPerSec,
          barWidth: videoDurationSecs * pxPerSec,
          label: _videoInfoLabel(video, duration),
        );
      },
    );
  }
}

/// The video's block on the timeline: the bar from [barLeft] for
/// [barWidth] px, the scrim past its end, and the metadata [label] chip
/// clamped into view. In every style the lane is 40 px tall, inset 6 px
/// from the top and bottom of its 52 px row by [padding]. Four drawings
/// by [ChromeStyle]:
///
/// - `recessed` (Classic): the bar is `videoInk` at 12% inside a 0.5 px
///   `videoInk` at 25% border at `radiusSm`; the chip at the top right,
///   `fontMeter` in `videoInk` at 70% on `bgDeep` at 70%, radius 2.
/// - `outlined` (High Contrast): the bar is `videoInk` at 15% inside a
///   `borderWidth` `videoInk` border at `radiusSm`; the chip at the top
///   right, `fontMeter` in `videoInk` on `bgBase`.
/// - `beveled` (Dark): `purpleDim` inside a 1 px `borderStrong`
///   border, 15 white lines at 5% every 3 px across it; the chip at the
///   bottom right, 6 px up and 11 px in, `videoInk` on `bgSurface` at
///   radius 2, tracking -0.3.
/// - `raised` (Light): `chromeBg` inside a 1 px `chromeRimDark` border
///   at radius 4, under a black gradient from 7% at the top to 19% at
///   the bottom; the chip at the bottom right, 4 px up and in,
///   `videoInk` inside a 1 px `videoInk` border at radius 4 with a soft
///   shadow.
///
/// The chip's text is `fontMeter` in both styles.
class VideoLane extends StatelessWidget {
  const VideoLane({
    super.key,
    required this.barLeft,
    required this.barWidth,
    required this.label,
  });

  final double barLeft;
  final double barWidth;
  final String label;

  /// The lane's inset in its 52 px row, leaving a 40 px lane in every
  /// style. A component's size does not vary by theme, only how it is
  /// drawn and coloured.
  static const EdgeInsets padding = EdgeInsets.symmetric(vertical: 6);

  @override
  Widget build(BuildContext context) {
    final style = T.chromeStyle;
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final barRight = barLeft + barWidth;
          final labelRight = width - min(barRight, width) + 4;
          final labelLeft = max(barLeft, 0.0) + 4;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: barLeft,
                  width: barWidth,
                  top: 0,
                  bottom: 0,
                  child: _bar(style),
                ),
                // Dim the region past the video's end — same
                // end-of-media treatment as the audio tracks (UX
                // review 05.2), so a video shorter than the timeline
                // reads as ended, not as continuing off-view.
                if (barRight < width)
                  Positioned(
                    // Clamped + non-hit-testing, matching the audio
                    // tracks' scrim (see _PastEndScrim over there).
                    left: max(barRight, 0.0),
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: ColoredBox(color: T.pastEndScrim),
                    ),
                  ),
                // Info label: anchored to the block's top right in
                // `recessed` and `outlined`, clamped into view. Top on purpose:
                // bottom-anchored it sat flush against the first audio
                // track below, styled like the audio clip badges, and
                // read as that track's header — an audio element
                // apparently labelled with a video format. `beveled` and
                // `raised` draw it at the bottom right in a chip of its
                // own, unlike their audio chips.
                switch (style) {
                  ChromeStyle.recessed || ChromeStyle.outlined => Positioned(
                    left: labelLeft,
                    right: labelRight,
                    top: 4,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _chip(style),
                    ),
                  ),
                  ChromeStyle.beveled => Positioned(
                    left: labelLeft,
                    right: labelRight + 7,
                    bottom: 6,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _chip(style),
                    ),
                  ),
                  ChromeStyle.raised => Positioned(
                    left: labelLeft,
                    right: labelRight,
                    bottom: 4,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _chip(style),
                    ),
                  ),
                },
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _bar(ChromeStyle style) => switch (style) {
    // High Contrast: `videoInk` at full strength, `borderWidth` wide.
    ChromeStyle.outlined => Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: T.videoInk.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(color: T.videoInk, width: T.borderWidth),
      ),
    ),
    ChromeStyle.recessed => Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: T.videoInk.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: T.videoInk.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
    ),
    ChromeStyle.beveled => Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: T.purpleDim,
        border: Border.all(color: T.borderStrong, width: 1),
      ),
      child: const CustomPaint(painter: _GuideLinesPainter()),
    ),
    ChromeStyle.raised => Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: T.chromeBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: T.chromeRimDark, width: 1),
      ),
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x13000000), Color(0x31000000)],
          ),
        ),
      ),
    ),
  };

  Widget _chip(ChromeStyle style) {
    final text = Text(
      label,
      style: switch (style) {
        ChromeStyle.recessed => TextStyle(
          fontSize: T.fontMeter,
          color: T.videoInk.withValues(alpha: 0.7),
        ),
        ChromeStyle.outlined => TextStyle(
          fontSize: T.fontMeter,
          color: T.videoInk,
        ),
        ChromeStyle.beveled => TextStyle(
          fontSize: T.fontMeter,
          color: T.videoInk,
          letterSpacing: T.tracking(T.fontMeter, -3),
        ),
        ChromeStyle.raised => TextStyle(
          fontSize: T.fontMeter,
          color: T.videoInk,
        ),
      },
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
    );
    return switch (style) {
      ChromeStyle.recessed => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: T.bgDeep.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(2),
        ),
        child: text,
      ),
      ChromeStyle.outlined => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: T.bgBase,
        child: text,
      ),
      ChromeStyle.beveled => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: T.bgSurface,
          borderRadius: BorderRadius.circular(2),
        ),
        child: text,
      ),
      ChromeStyle.raised => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: T.videoInk, width: 1),
          boxShadow: [
            BoxShadow(
              color: T.chromeRimDark.withValues(alpha: 0.06),
              offset: const Offset(0, 2),
              blurRadius: 2,
            ),
            BoxShadow(
              color: T.chromeRimDark.withValues(alpha: 0.04),
              offset: const Offset(0, 7),
              blurRadius: 3.5,
            ),
          ],
        ),
        child: text,
      ),
    };
  }
}

/// The `beveled` guide lines: 15 white lines at 5%, 1 px, 3 px apart
/// from 2.5 px down the lane.
class _GuideLinesPainter extends CustomPainter {
  const _GuideLinesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0DFFFFFF)
      ..strokeWidth = 1;
    for (var k = 0; k < 15; k++) {
      final y = 2.5 + 3 * k;
      if (y > size.height) break;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GuideLinesPainter old) => false;
}

String _videoInfoLabel(VideoState state, Duration? duration) {
  final parts = <String>[];
  if (state.filePath != null) {
    parts.add(p.basename(state.filePath!));
  }
  if (duration != null && duration != Duration.zero) {
    parts.add(formatDuration(duration.inMilliseconds / 1000.0));
  }
  if (state.videoWidth != null && state.videoHeight != null) {
    var res = '${state.videoWidth}\u00D7${state.videoHeight}';
    if (state.fps != null) {
      final fpsVal = state.fps!;
      final fpsStr = fpsVal == fpsVal.roundToDouble()
          ? fpsVal.toInt().toString()
          : fpsVal.toStringAsFixed(2);
      res += '@$fpsStr';
    }
    parts.add(res);
  }
  return parts.join(' \u00B7 ');
}
