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

/// The macOS-native AVFoundation [VideoBackend] (issue ES-249, step 3) — the
/// macOS default.
///
/// This is the *pull-based* winner from the ES-248 evaluation: an
/// `AVPlayerItemVideoOutput` driven by zero-tolerance seek-then-pull. There
/// is no drift loop — [syncToAudio] renders the exact frame for the engine
/// time, so A/V stays locked by construction. Decode is VideoToolbox
/// (ProRes / HEVC / H.264). Opening only the video track avoids the IAMF
/// audio decoder (ES-219) structurally.
///
/// The Dart side talks to a native `FlutterTexture` controller over the
/// `eclipsa/avf_video` method channel and renders a [Texture]. The native
/// implementation lives in `macos/Runner/AvfVideoController.swift`, wired
/// into the Runner target and registered in `MainFlutterWindow`.
///
/// The macOS default (`resolveAuto`) and selectable in Settings → Video
/// backend; FFmpeg-in-engine remains available as the alternative.
class AvFoundationBackend extends VideoBackend {
  static const _channel = MethodChannel('eclipsa/avf_video');

  AvFoundationBackend() {
    // Native → Dart events: the controller reports async player failures
    // (AVPlayerItem transitioning to .failed mid-playback) as 'error' calls.
    // Only one backend instance is live per engine at a time, so a later
    // instance overwriting a shut-down one's handler is the desired outcome.
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'error' && !_shutDown) {
      final msg = call.arguments as String? ?? 'unknown decoder error';
      Log.w(LogCat.video, 'AVFoundation player error: $msg');
      onError?.call(msg);
    }
    return null;
  }

  int? _textureId;
  VideoMeta _meta = VideoMeta.empty;
  bool _shutDown = false;

  /// Guards the per-tick render so a slow seek-then-pull doesn't queue up
  /// dozens of channel round-trips (the same in-flight guard every backend
  /// keeps around its syncToAudio work). While busy, the latest requested
  /// time is stashed in [_pendingSeconds] (latest-wins) and rendered when
  /// the in-flight round-trip returns — dropping it instead would leave the
  /// final position of a paused scrub unrendered (nothing re-renders while
  /// paused, so the picture would sit on a stale frame).
  bool _renderBusy = false;
  double? _pendingSeconds;

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
      return null;
    } on PlatformException catch (e) {
      Log.e(LogCat.video, 'AVFoundation load failed', e);
      return 'Could not load video "${p.basename(path)}"';
    } on MissingPluginException catch (e) {
      // Native controller not wired into the Runner target yet.
      Log.e(LogCat.video, 'AVFoundation backend not available', e);
      return 'AVFoundation backend is not available in this build';
    }
  }

  @override
  Future<void> unload() async {
    _meta = VideoMeta.empty;
    _textureId = null;
    _pendingSeconds = null;
    await _invoke('unload');
  }

  @override
  Future<void> play() async => _invoke('setPlaying', {'playing': true});

  @override
  Future<void> pause() async => _invoke('setPlaying', {'playing': false});

  @override
  Future<void> seekTo(double seconds) async => _renderAt(seconds);

  @override
  Future<void> syncToAudio(double audioSeconds, {required bool playing}) async {
    // Pull-based: render the exact frame for the engine time. No drift loop.
    await _renderAt(audioSeconds);
  }

  Future<void> _renderAt(double seconds) async {
    if (_shutDown || _textureId == null) return;
    if (_renderBusy) {
      _pendingSeconds = seconds;
      return;
    }
    _renderBusy = true;
    try {
      var s = seconds;
      while (true) {
        try {
          await _channel.invokeMethod('renderAt', {'seconds': s});
        } on PlatformException catch (e) {
          Log.w(LogCat.video, 'AVFoundation renderAt failed', e);
        } on MissingPluginException catch (e) {
          Log.w(LogCat.video, 'AVFoundation renderAt unavailable', e);
        }
        if (_shutDown) return;
        final pending = _pendingSeconds;
        if (pending == null) break;
        _pendingSeconds = null;
        s = pending;
      }
    } finally {
      _renderBusy = false;
    }
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (_shutDown) return;
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      Log.w(LogCat.video, 'AVFoundation $method failed', e);
    } on MissingPluginException catch (e) {
      // Native controller not wired into the Runner target yet — degrade
      // quietly rather than throw on every transport call after loadFile.
      Log.w(LogCat.video, 'AVFoundation $method unavailable', e);
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
    Log.i(LogCat.video, 'shutdown: disposing AVFoundation player');
    await _invoke('dispose');
  }
}
