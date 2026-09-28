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

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import 'video_backend.dart';

/// The native Windows Media Foundation [VideoBackend] — the Windows default,
/// the counterpart of [AvFoundationBackend] on macOS.
///
/// Pull-based, like AVFoundation: an `IMFSourceReader` decoding with a D3D11
/// device (hardware where available) driven by seek-then-read. There is no
/// drift loop — [syncToAudio] renders the exact frame for the engine time, so
/// A/V stays locked by construction. The decoded D3D11 surface is converted to
/// a shareable BGRA texture and handed to Flutter as a zero-copy DXGI
/// GpuSurfaceTexture. Opening only the video stream avoids the IAMF audio
/// decoder (ES-219) structurally.
///
/// The Dart side talks to a native controller over the `eclipsa/mf_video`
/// method channel and renders a [Texture]. The native implementation lives in
/// `windows/runner/mf_video_controller.{h,cpp}`, registered in
/// `flutter_window.cpp` (main + pop-out windows). The Windows default
/// (`resolveAuto`) and selectable in Settings → Video backend;
/// FFmpeg-in-engine remains available as the alternative.
class MfVideoBackend extends VideoBackend {
  static const _channel = MethodChannel('eclipsa/mf_video');

  int? _textureId;
  VideoMeta _meta = VideoMeta.empty;
  bool _shutDown = false;

  /// Guards the per-tick render so a slow seek-then-read doesn't queue up
  /// dozens of channel round-trips (mirrors AVFoundation's in-flight guard).
  /// While busy, the latest requested time is stashed in [_pendingSeconds]
  /// (latest-wins) and rendered when the in-flight round-trip returns —
  /// dropping it instead would leave the final position of a paused scrub
  /// unrendered. [_pendingForce] is sticky across overwrites so a pending
  /// explicit seek's repaint can't be lost to a later same-frame sync.
  bool _renderBusy = false;
  double? _pendingSeconds;
  bool _pendingForce = false;

  /// Native render-diagnostics state (see `MfVideoPlayer::DiagMap`): the last
  /// native error already logged (log each distinct error once, not per
  /// tick), a render-call counter, and whether the one-shot health line has
  /// been emitted.
  String _lastDiagError = '';
  int _renderCalls = 0;
  bool _healthLogged = false;

  /// Index of the frame last requested from the native side — successive
  /// 60 Hz sync ticks that fall on the same video frame are skipped (a
  /// 30 fps clip maps two ticks to one frame). Null forces the next render.
  int? _lastFrameIndex;

  @override
  VideoMeta get meta => _meta;

  @override
  Future<String?> loadFile(String path) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('load', {
        'path': path,
      });
      if (res == null) return 'Could not load video "${p.basename(path)}"';
      _textureId = (res['textureId'] as num?)?.toInt();
      _meta = VideoMeta.fromChannelMap(res);
      onMetaChanged?.call(_meta);
      // Fresh clip → fresh native player: restart the diag reporting, the
      // same-frame dedup, and any pending render aimed at the old clip.
      _lastDiagError = '';
      _renderCalls = 0;
      _healthLogged = false;
      _lastFrameIndex = null;
      _pendingSeconds = null;
      _pendingForce = false;
      return null;
    } on PlatformException catch (e) {
      Log.e(LogCat.video, 'Media Foundation load failed', e);
      return 'Could not load video "${p.basename(path)}"';
    } on MissingPluginException catch (e) {
      // Native controller not wired into the runner (e.g. pop-out) yet.
      Log.e(LogCat.video, 'Media Foundation backend not available', e);
      return 'Media Foundation backend is not available in this build';
    }
  }

  @override
  Future<void> unload() async {
    _meta = VideoMeta.empty;
    _textureId = null;
    _pendingSeconds = null;
    _pendingForce = false;
    await _invoke('unload');
  }

  @override
  Future<void> play() async => _invoke('setPlaying', {'playing': true});

  @override
  Future<void> pause() async => _invoke('setPlaying', {'playing': false});

  @override
  Future<void> seekTo(double seconds) async => _renderAt(seconds, force: true);

  @override
  Future<void> syncToAudio(double audioSeconds, {required bool playing}) async {
    // Pull-based: render the exact frame for the engine time. No drift loop.
    await _renderAt(audioSeconds);
  }

  /// The video-frame index [seconds] falls on, or null when fps is unknown —
  /// in which case dedup is disabled and every request goes through (the
  /// native side paces itself too; this just avoids needless channel trips).
  /// Mirrors [FfmpegEngineBackend]'s same-frame dedup.
  int? _frameIndex(double seconds) {
    final fps = _meta.fps;
    if (fps == null || fps <= 0) return null;
    return (seconds * fps).floor();
  }

  Future<void> _renderAt(double seconds, {bool force = false}) async {
    if (_shutDown || _textureId == null) return;
    if (_renderBusy) {
      _pendingForce = force || (_pendingSeconds != null && _pendingForce);
      _pendingSeconds = seconds;
      return;
    }
    _renderBusy = true;
    try {
      var s = seconds;
      var f = force;
      while (true) {
        final idx = _frameIndex(s);
        if (f || idx == null || idx != _lastFrameIndex) {
          try {
            final diag = await _channel.invokeMapMethod<String, dynamic>(
              'renderAt',
              {'seconds': s},
            );
            _lastFrameIndex = idx;
            _reportDiag(diag);
          } on PlatformException catch (e) {
            Log.w(LogCat.video, 'Media Foundation renderAt failed', e);
          } on MissingPluginException catch (e) {
            Log.w(LogCat.video, 'Media Foundation renderAt unavailable', e);
          }
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

  /// Surface the native render diagnostics into the app log — the worker
  /// thread's failures are otherwise invisible (`RenderOnce` returns void
  /// and only Dart reaches the JSONL log). Each distinct native error is
  /// logged once, and a one-shot health line lands after ~10 render calls
  /// so a silent black picture leaves a trace either way.
  void _reportDiag(Map<String, dynamic>? diag) {
    if (diag == null) return;
    final error = diag['error'] as String? ?? '';
    if (error.isNotEmpty && error != _lastDiagError) {
      _lastDiagError = error;
      Log.w(
        LogCat.video,
        'MF native render error: $error '
        '(presented=${diag['presented']}, reads=${diag['reads']})',
      );
      // Surface it to the user too (each distinct error once): the worker's
      // failures are otherwise a silently frozen or black picture.
      onError?.call(error);
    }
    _renderCalls++;
    if (!_healthLogged && _renderCalls >= 10) {
      _healthLogged = true;
      Log.i(
        LogCat.video,
        'MF render health: presented=${diag['presented']} '
        'reads=${diag['reads']}'
        '${error.isEmpty ? '' : ' first_error=$error'}',
      );
    }
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (_shutDown) return;
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      Log.w(LogCat.video, 'Media Foundation $method failed', e);
    } on MissingPluginException catch (e) {
      // Degrade quietly rather than throw on every transport call after load.
      Log.w(LogCat.video, 'Media Foundation $method unavailable', e);
    }
  }

  @override
  Widget buildSurface(
    BuildContext context, {
    Color fill = const Color(0xFF000000),
  }) {
    final id = _textureId;
    final Widget child = id == null
        ? const SizedBox.expand()
        : fittedVideoTexture(_meta, Texture(textureId: id));
    return ColoredBox(color: fill, child: child);
  }

  @override
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    Log.i(LogCat.video, 'shutdown: disposing Media Foundation player');
    await _invoke('dispose');
  }
}
