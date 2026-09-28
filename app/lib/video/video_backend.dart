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

/// Resolved media metadata for the loaded video.
///
/// Backends fill these in as the decoder reports them; they may arrive
/// asynchronously, so any field may be null until the decoder resolves it.
@immutable
class VideoMeta {
  /// Duration of the video stream (the picture's real end, not the
  /// container's — see ES-459).
  final Duration? duration;

  /// Display resolution in pixels, after [quarterTurns] is applied: a
  /// portrait phone recording stored as 1920x1080 reports 1080x1920.
  final int? width;
  final int? height;

  /// Clockwise quarter turns (0-3) the decoded frame needs for display,
  /// from the container's rotation (ES-796). The backend's texture or image
  /// carries the unrotated frame; [fittedVideoTexture] turns it.
  final int quarterTurns;

  /// Frame rate, frames per second.
  final double? fps;

  /// Container (presentation) duration — the longest track. Differs from
  /// [duration] on a muxed master whose audio outlasts the picture; the
  /// inspector surfaces the mismatch (ES-462).
  final Duration? containerDuration;

  /// Codec display name with the raw fourcc, e.g. `HEVC (hvc1)`.
  final String? codec;

  /// Average bit rate of the video track, bits per second.
  final int? bitRateBps;

  /// Color transfer/primaries display string, e.g. `PQ (HDR10) · BT.2020`.
  final String? colorInfo;

  const VideoMeta({
    this.duration,
    this.width,
    this.height,
    this.fps,
    this.containerDuration,
    this.codec,
    this.bitRateBps,
    this.colorInfo,
    this.quarterTurns = 0,
  });

  /// No media loaded / nothing resolved yet.
  static const empty = VideoMeta();

  /// Parse the metadata map the AVFoundation / Media Foundation method
  /// channels reply to `load` with. Both native sides share this contract:
  /// optional fields are omitted (or non-positive) when unresolved. The
  /// color transfer and primaries arrive as separate ASCII strings and are
  /// composed here (`PQ (HDR10) · BT.2020`) so neither native side needs
  /// non-ASCII literals.
  factory VideoMeta.fromChannelMap(Map<String, dynamic> res) {
    Duration? ms(String key) {
      final v = (res[key] as num?)?.toInt();
      return (v != null && v > 0) ? Duration(milliseconds: v) : null;
    }

    final bitRate = (res['bitRate'] as num?)?.toInt();
    final color = [
      res['colorTransfer'],
      res['colorPrimaries'],
    ].whereType<String>().join(' · ');
    return VideoMeta(
      duration: ms('durationMs'),
      width: (res['width'] as num?)?.toInt(),
      height: (res['height'] as num?)?.toInt(),
      fps: (res['fps'] as num?)?.toDouble(),
      containerDuration: ms('containerDurationMs'),
      codec: res['codec'] as String?,
      bitRateBps: (bitRate != null && bitRate > 0) ? bitRate : null,
      colorInfo: color.isEmpty ? null : color,
      quarterTurns: ((res['quarterTurns'] as num?)?.toInt() ?? 0) % 4,
    );
  }
}

/// The picture for a texture-based backend: [texture] letterboxed to the
/// display aspect ratio in [meta] (BoxFit.contain) and turned clockwise by
/// [VideoMeta.quarterTurns]. A bare Texture fills, and so stretches to, the
/// whole panel. Until the resolution resolves, [texture] is returned as is.
Widget fittedVideoTexture(VideoMeta meta, Widget texture) {
  final w = meta.width, h = meta.height;
  if (w == null || h == null || w <= 0 || h <= 0) return texture;
  return Center(
    child: AspectRatio(
      aspectRatio: w / h,
      child: RotatedBox(quarterTurns: meta.quarterTurns, child: texture),
    ),
  );
}

/// One pluggable video playback engine.
///
/// Every shipped backend is **pull-based** (see issue ES-249): AVFoundation on
/// macOS, Media Foundation on Windows, FFmpeg-in-engine on both render the
/// exact frame for the requested time, so [syncToAudio] seeks/renders
/// frame-at-T with no residual drift loop. (The seam also accommodated
/// **free-running players** that own their clock and get drift-corrected
/// against the audio thread every tick; the media_kit and fvp backends of
/// that kind were retired.)
///
/// `VideoNotifier` owns the *selected* backend, forwards transport to it,
/// and exposes the public `VideoState`; nothing downstream of the notifier
/// knows which backend is active.
///
/// Backends are UI- and Riverpod-agnostic: async metadata and decoder
/// errors are surfaced to the coordinator through [onMetaChanged] and
/// [onError] rather than by touching app state directly.
abstract class VideoBackend {
  /// Invoked whenever [meta] changes (duration / resolution / fps resolve
  /// asynchronously). Set by the coordinator.
  void Function(VideoMeta meta)? onMetaChanged;

  /// Invoked when the decoder reports a playback error. Set by the
  /// coordinator, which surfaces it to the user.
  void Function(String message)? onError;

  /// Load a video file from a local path. Returns null on success or a
  /// short, user-facing error message on failure.
  Future<String?> loadFile(String path);

  /// Stop and release the current file. The backend instance stays alive
  /// and ready for the next [loadFile].
  Future<void> unload();

  /// Resume playback (the transport drives this).
  Future<void> play();

  /// Pause playback (the transport drives this).
  Future<void> pause();

  /// Seek to [seconds] from the start of the file.
  Future<void> seekTo(double seconds);

  /// Reconcile the video to the audio-thread playhead. Called ~60 Hz from
  /// the app_shell tick loop during playback. [audioSeconds] is the master
  /// clock; [playing] is the transport's play state at the call site.
  ///
  /// Pull-based backends render/seek the exact frame for [audioSeconds].
  Future<void> syncToAudio(double audioSeconds, {required bool playing});

  /// The render surface — a `Texture(id:)` for the texture-based backends.
  /// [fill] is the letterbox / background colour painted behind the picture.
  ///
  /// Implementations default [fill] to pure black — deliberately NOT a
  /// theme token: black letterboxing is the video-playback convention
  /// in every theme (a light-theme surround would halo the picture),
  /// and it matches fullscreen/pop-out. Themed call sites (e.g. the
  /// inline panel's `T.bgDeep`) override it explicitly.
  Widget buildSurface(BuildContext context, {Color fill});

  /// Latest resolved media metadata (fields may be null until the decoder
  /// reports them).
  VideoMeta get meta;

  /// Permanently dispose the backend (player + native resources).
  /// Idempotent and awaitable.
  ///
  /// Transport methods may still be invoked during a teardown race (an
  /// already-suspended tick resuming across an `await`); implementations
  /// must tolerate calls after [shutdown] without throwing.
  Future<void> shutdown();
}
