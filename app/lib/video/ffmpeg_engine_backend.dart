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

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import 'ffmpeg_video_ffi.dart';
import 'video_backend.dart';

/// [VideoMeta] for a clip the engine opened. The engine reports the stored
/// frame size; the meta carries the display size, swapped for a quarter or
/// three-quarter turn (ES-796).
///
/// The engine's C ABI carries only the basics; the inspector metadata fields
/// (codec / container duration / bit rate / color, ES-462) stay null here and
/// their inspector rows do not render on this hard-fallback backend.
@visibleForTesting
VideoMeta ffmpegVideoMeta(FfmpegVideoInfo info) {
  final sideways = info.quarterTurns.isOdd;
  final w = sideways ? info.height : info.width;
  final h = sideways ? info.width : info.height;
  return VideoMeta(
    duration: info.durationMs > 0
        ? Duration(milliseconds: info.durationMs)
        : null,
    width: w > 0 ? w : null,
    height: h > 0 ? h : null,
    fps: info.fps > 0 ? info.fps : null,
    quarterTurns: info.quarterTurns,
  );
}

/// The software-decoded frame [image], letterboxed in the available space
/// (BoxFit.contain) and turned clockwise by [quarterTurns]. RotatedBox hands
/// RawImage the swapped constraints, so the unrotated frame is contained,
/// then turned.
@visibleForTesting
Widget fittedVideoImage(ui.Image image, int quarterTurns) {
  return SizedBox.expand(
    child: RotatedBox(
      quarterTurns: quarterTurns,
      child: RawImage(
        image: image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    ),
  );
}

/// The FFmpeg-in-engine [VideoBackend] (issue ES-249, step 5).
///
/// This is the architectural endgame of the pluggable-backend seam: the C++
/// engine decodes video (LGPL FFmpeg + a per-platform HW decoder — VideoToolbox
/// on macOS, D3D11VA on Windows) and exposes "frame at time T" over a C FFI,
/// and this backend renders that frame on the engine clock. Like AVFoundation
/// it is *pull-based* — [syncToAudio] renders the exact frame for the
/// audio-thread time, so A/V is locked by construction with no drift loop.
///
/// It renders in one of two modes, chosen per clip from the engine's decode
/// path:
///
/// - **Texture (zero-copy)** — a hardware-decoded clip. The engine hands back a
///   native GPU surface per frame (a BGRA `CVPixelBuffer` on macOS, a DXGI
///   shared handle to a BGRA D3D11 texture on Windows); we forward its address
///   to the native `FfmpegVideoPlugin` (`eclipsa/ffmpeg_video`), which vends it
///   as a `FlutterTexture` / `GpuSurfaceTexture`. The picture is sampled on the
///   GPU with no readback — the same native-texture path AVFoundation uses,
///   registered in the main and pop-out windows alike.
/// - **Image (fallback)** — a software clip (AV1/dav1d, or a codec the HW
///   decoder declined), or any platform where the native texture is
///   unavailable. The engine returns a CPU RGBA buffer, uploaded to a
///   `ui.Image` and painted with [RawImage]. Pure Dart + FFI, so it always
///   works.
///
/// Decode runs on a dedicated isolate ([FfmpegDecoderClient]) so the blocking
/// FFI call never stalls the UI. Selectable in Settings → Video backend on any
/// platform; not the per-platform default.
class FfmpegEngineBackend extends VideoBackend {
  static const _texChannel = MethodChannel('eclipsa/ffmpeg_video');

  final FfmpegDecoderClient _client = FfmpegDecoderClient();

  /// The frame currently on screen in *image* mode. `buildSurface` rebuilds
  /// off this, so a new frame repaints without going through Riverpod.
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  /// The native texture id in *texture* mode, or null in image mode.
  /// `buildSurface` rebuilds off this so a mode switch (or backend swap)
  /// repaints onto the right surface.
  final ValueNotifier<int?> _texture = ValueNotifier<int?>(null);

  VideoMeta _meta = VideoMeta.empty;
  double? _fps;
  bool _shutDown = false;

  /// Whether the current clip renders through the native texture (HW). False
  /// is the software image path.
  bool _textureMode = false;
  int? _textureId;

  /// Guards the per-tick render so a slow decode doesn't queue up dozens of
  /// isolate round-trips (mirrors AVFoundation's `_renderBusy`). While busy,
  /// the latest requested time is stashed in [_pendingSeconds] (latest-wins).
  bool _renderBusy = false;
  double? _pendingSeconds;
  bool _pendingForce = false;

  /// Index of the last decoded video frame, used to skip re-decoding when
  /// successive 60 Hz sync ticks fall on the same frame (a 24 fps clip maps
  /// many ticks to one frame). Null forces the next render.
  int? _lastFrameIndex;

  /// Consecutive render requests for which the decoder produced no frame.
  /// The engine FFI has no error-string channel (failures go to the engine
  /// log), so a run of no-frame renders is the observable signal that decode
  /// broke mid-clip; [onError] fires once per clip at the threshold instead
  /// of letting the picture freeze silently.
  int _noFrameStreak = 0;
  bool _decodeFailureReported = false;
  static const _kNoFrameStreakLimit = 5;

  @override
  VideoMeta get meta => _meta;

  @override
  Future<String?> loadFile(String path) async {
    if (_shutDown) return null;
    final info = await _client.open(path);
    if (_shutDown) return null;
    if (info == null || !info.ok) {
      Log.e(LogCat.video, 'FFmpeg engine could not open ${p.basename(path)}');
      return 'Could not load video "${p.basename(path)}"';
    }
    Log.i(
      LogCat.video,
      'FFmpeg engine opened ${p.basename(path)} '
      '(${info.width}x${info.height} @${info.fps.toStringAsFixed(3)}fps, '
      'quarter turns ${info.quarterTurns}, '
      'decode: ${info.hw ? 'HW (VideoToolbox/D3D11VA)' : 'software'})',
    );
    _fps = info.fps > 0 ? info.fps : null;
    _lastFrameIndex = null; // Force a render at the current playhead.
    _noFrameStreak = 0;
    _decodeFailureReported = false;
    _meta = ffmpegVideoMeta(info);
    onMetaChanged?.call(_meta);
    // A HW clip goes through the native zero-copy texture; a software clip (or
    // a build without the native plugin) stays on the image path.
    await _configureSurface(
      hw: info.hw,
      width: info.width,
      height: info.height,
    );
    return null;
  }

  /// Pick the render path for the just-opened clip. Registers a native texture
  /// for a HW clip (falling back to the image path if the plugin is absent);
  /// a software clip uses the image path directly.
  Future<void> _configureSurface({
    required bool hw,
    required int width,
    required int height,
  }) async {
    await _disposeTexture(); // clear any texture from a previous clip
    if (!hw || _shutDown) return;
    try {
      // Pass the stored (unrotated) frame size: the Windows GPU-surface
      // texture needs it for its descriptor (`present` carries only the frame
      // handle). The macOS controller ignores these — its CVPixelBuffer
      // carries its own size.
      final res = await _texChannel.invokeMapMethod<String, dynamic>('create', {
        'width': width,
        'height': height,
      });
      final id = (res?['textureId'] as num?)?.toInt();
      if (id != null && id >= 0) {
        _textureId = id;
        _textureMode = true;
        _setImage(null); // release any image from a prior image-mode clip
        _texture.value = id;
        Log.i(LogCat.video, 'FFmpeg: zero-copy texture path (id=$id)');
        return;
      }
    } on PlatformException catch (e) {
      Log.w(LogCat.video, 'FFmpeg texture create failed; using image path', e);
    } on MissingPluginException catch (e) {
      Log.w(LogCat.video, 'FFmpeg texture unavailable; using image path', e);
    }
    _textureMode = false; // Fall back to the software image path.
  }

  /// Tear down the native texture (if any) and return to the image path.
  Future<void> _disposeTexture() async {
    final id = _textureId;
    _textureId = null;
    _textureMode = false;
    _texture.value = null;
    if (id == null) return;
    try {
      await _texChannel.invokeMethod('dispose');
    } on PlatformException catch (e) {
      Log.w(LogCat.video, 'FFmpeg texture dispose failed', e);
    } on MissingPluginException {
      // Plugin gone (teardown) — nothing to release.
    }
  }

  @override
  Future<void> unload() async {
    _meta = VideoMeta.empty;
    _fps = null;
    _lastFrameIndex = null;
    _pendingSeconds = null;
    await _disposeTexture();
    await _client.close();
    _setImage(null);
  }

  // Pull-based: there is no internal clock to start or stop. Frames are
  // driven entirely by seekTo / syncToAudio, so play/pause are no-ops.
  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(double seconds) async => _render(seconds, force: true);

  @override
  Future<void> syncToAudio(double audioSeconds, {required bool playing}) async {
    // Pull-based: render the exact frame for the engine time. No drift loop.
    await _render(audioSeconds);
  }

  /// Decode and present the frame for [seconds]. When [force] is false a
  /// request that maps to the already-shown frame is skipped; an explicit
  /// seek forces a render (the surface may have just been rebuilt). Renders
  /// serialize through [_renderBusy], coalescing to the latest request.
  Future<void> _render(double seconds, {bool force = false}) async {
    if (_shutDown) return;
    if (!force && _isSameFrame(seconds)) return;
    if (_renderBusy) {
      // Latest-wins for the time; force is sticky across overwrites so a
      // pending explicit seek's repaint can't be lost to a later same-frame
      // sync stashing force=false on top of it.
      _pendingForce = force || (_pendingSeconds != null && _pendingForce);
      _pendingSeconds = seconds;
      return;
    }
    _renderBusy = true;
    try {
      var s = seconds;
      var f = force;
      while (true) {
        if (f || !_isSameFrame(s)) {
          await _renderOnce(s);
          if (_shutDown) return;
        }
        if (_pendingSeconds == null) break;
        s = _pendingSeconds!;
        f = _pendingForce;
        _pendingSeconds = null;
        _pendingForce = false;
      }
    } finally {
      _renderBusy = false;
    }
  }

  /// Render exactly one frame for [s] on the active path.
  Future<void> _renderOnce(double s) async {
    if (_textureMode) {
      final pb = await _client.renderPixbufAt(s);
      if (_shutDown) {
        // Lost the race with teardown — release the buffer we won't present.
        if (pb != null) _client.releasePixbuf(pb.address);
        return;
      }
      if (pb != null) {
        _noFrameStreak = 0;
        _lastFrameIndex = _frameIndex(s);
        try {
          await _texChannel.invokeMethod('present', {'buffer': pb.address});
        } on PlatformException catch (e) {
          // The native side never adopted the buffer — release it so the frame
          // isn't leaked.
          _client.releasePixbuf(pb.address);
          Log.w(LogCat.video, 'FFmpeg present failed', e);
        } on MissingPluginException {
          _client.releasePixbuf(pb.address);
          await _switchToImageMode();
        }
        return;
      }
      // The device was attached but this frame decoded in software — downgrade
      // to the image path for the rest of the clip. The next tick renders it.
      await _switchToImageMode();
      return;
    }
    final frame = await _client.renderAt(s);
    if (_shutDown) return;
    if (frame != null) {
      _noFrameStreak = 0;
      _lastFrameIndex = _frameIndex(s);
      await _present(frame);
    } else {
      _noteNoFrame();
    }
  }

  /// Track a render that produced no frame and surface a persistent decode
  /// failure to the user (once per clip). A lone miss stays quiet — EOF
  /// boundaries and teardown races produce benign one-offs.
  void _noteNoFrame() {
    _noFrameStreak++;
    if (_decodeFailureReported || _noFrameStreak < _kNoFrameStreakLimit) {
      return;
    }
    _decodeFailureReported = true;
    Log.w(
      LogCat.video,
      'FFmpeg: $_noFrameStreak consecutive renders returned no frame',
    );
    onError?.call('the decoder stopped producing frames (see log)');
  }

  Future<void> _switchToImageMode() async {
    if (!_textureMode) return;
    Log.i(LogCat.video, 'FFmpeg: downgraded to the software image path');
    await _disposeTexture();
    _lastFrameIndex = null; // force the next tick to render the image
  }

  bool _isSameFrame(double seconds) {
    final idx = _frameIndex(seconds);
    return idx != null && idx == _lastFrameIndex;
  }

  /// The video-frame index [seconds] falls on, or null when fps is unknown
  /// (before the first clip resolves) — in which case dedup is disabled and
  /// every request renders.
  int? _frameIndex(double seconds) {
    final fps = _fps;
    if (fps == null || fps <= 0) return null;
    return (seconds * fps).floor();
  }

  Future<void> _present(FfmpegFrame frame) async {
    final image = await _decodeImage(frame);
    if (_shutDown) {
      image?.dispose();
      return;
    }
    _setImage(image);
  }

  Future<ui.Image?> _decodeImage(FfmpegFrame frame) {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: frame.stride,
    );
    return completer.future;
  }

  /// Swap the on-screen frame, disposing the one it replaces to free its GPU
  /// memory. Safe because the replaced image was only ever painted in an
  /// earlier frame: setting the notifier here (outside the paint phase)
  /// schedules a rebuild that swaps [RawImage] to the new image before the
  /// next paint, so nothing repaints the old one after disposal.
  void _setImage(ui.Image? image) {
    final previous = _frame.value;
    if (identical(previous, image)) return;
    _frame.value = image;
    previous?.dispose();
  }

  @override
  Widget buildSurface(
    BuildContext context, {
    Color fill = const Color(0xFF000000),
  }) {
    return ValueListenableBuilder<int?>(
      valueListenable: _texture,
      builder: (context, textureId, _) {
        if (textureId != null) {
          return _buildTexture(textureId, fill);
        }
        return ValueListenableBuilder<ui.Image?>(
          valueListenable: _frame,
          builder: (context, image, _) {
            return ColoredBox(
              color: fill,
              // BoxFit.contain letterboxes the picture within the panel; the
              // margins show the `fill` behind, matching the other backends.
              child: image == null
                  ? const SizedBox.expand()
                  : fittedVideoImage(image, _meta.quarterTurns),
            );
          },
        );
      },
    );
  }

  Widget _buildTexture(int textureId, Color fill) {
    return ColoredBox(
      color: fill,
      child: fittedVideoTexture(_meta, Texture(textureId: textureId)),
    );
  }

  @override
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    Log.i(LogCat.video, 'shutdown: disposing FFmpeg engine decoder');
    await _disposeTexture();
    await _client.shutdown();
    _setImage(null);
  }
}
