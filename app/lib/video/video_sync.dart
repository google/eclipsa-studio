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

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import 'video_provider.dart';

/// Should a transport delta be treated as a discontinuous jump (user
/// seek, loop wrap, backward scrub) that the video must chase, rather
/// than natural playback progress it already follows?
///
/// While playing, the tick loop writes the audio thread's position back
/// into transportProvider every frame, so the transport listener fires
/// at ~60 Hz with small positive deltas. A single tick at 48 kHz /
/// 60 Hz is ~800 samples; real user seeks jump by seconds. The 100 ms
/// threshold comfortably separates the two even with a few dropped
/// Flutter frames. Top-level (not a private closure) so the threshold
/// is unit-testable.
bool isDiscontinuousJump({required int deltaSamples, required int sampleRate}) {
  final maxNaturalDelta = (sampleRate * 0.1).round(); // 100 ms
  // Negative delta → loop wrap or backward scrub.
  // Delta larger than the natural tick stride → forward user seek.
  return deltaSamples < 0 || deltaSamples > maxNaturalDelta;
}

/// Invisible widget that syncs the video player to the master transport.
///
/// Place this once in the widget tree (e.g., in [AppShell]).
/// It listens to transport and playing state and drives the video
/// player accordingly — all side effects run outside the build phase.
class VideoTransportSync extends ConsumerStatefulWidget {
  const VideoTransportSync({super.key});

  @override
  ConsumerState<VideoTransportSync> createState() => _VideoTransportSyncState();
}

class _VideoTransportSyncState extends ConsumerState<VideoTransportSync> {
  @override
  Widget build(BuildContext context) {
    // Play/pause sync — fires only on transitions
    ref.listen<bool>(playingProvider, (prev, next) {
      final video = ref.read(videoProvider);
      if (!video.hasVideo) return;
      final notifier = ref.read(videoProvider.notifier);
      if (next) {
        notifier.play();
      } else {
        notifier.pause();
        notifier.seekTo(ref.read(transportProvider).seconds);
      }
    });

    // Seek sync — follow transport when not playing, or on
    // discontinuous jumps while playing (loop wraps, timeline clicks
    // ahead of the current playhead, etc.). The natural-progress vs
    // user-seek decision lives in [isDiscontinuousJump].
    ref.listen<TransportState>(transportProvider, (prev, next) {
      final video = ref.read(videoProvider);
      if (!video.hasVideo) return;
      final notifier = ref.read(videoProvider.notifier);
      if (!ref.read(playingProvider)) {
        // Paused: always follow the transport.
        notifier.seekTo(next.seconds);
        return;
      }
      if (prev == null) return;
      if (isDiscontinuousJump(
        deltaSamples: next.samplePosition - prev.samplePosition,
        sampleRate: next.sampleRate,
      )) {
        notifier.seekTo(next.seconds);
      }
    });

    return const SizedBox.shrink();
  }
}
