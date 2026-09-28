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
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../ffi/engine_bindings.dart';
import '../ffi_bridge.dart' show EclipsaStudioEngine;
import '../logging/log.dart';

// Dart binding for the FFmpeg-in-engine video decoder (issue ES-249, step 5).
//
// The C++ engine owns the FFmpeg demux/decode/scale core and exposes
// "frame at time T" over the `eclipsa_studio_video_*` C FFI (engine/video/
// video_ffi.h). Each call decodes synchronously, so it must not run on the
// UI isolate: this file drives the decoder from a dedicated long-lived
// isolate (mirroring the repo's other FFI-on-isolate work — peak_isolate,
// the export isolates), handing RGBA frames back to the UI isolate where
// [FfmpegEngineBackend] turns them into a `ui.Image`.

// The native ABI (struct mirror + typedefs for the `eclipsa_studio_video_*`
// symbols) lives in the shared binding module, lib/ffi/engine_bindings.dart.

// ---------------------------------------------------------------------------
// Public value types
// ---------------------------------------------------------------------------

/// Resolved stream info for an opened clip. [ok] is false when the file has
/// no decodable video stream.
class FfmpegVideoInfo {
  const FfmpegVideoInfo({
    required this.width,
    required this.height,
    required this.fps,
    required this.durationMs,
    required this.ok,
    required this.hw,
    required this.quarterTurns,
  });

  final int width;
  final int height;
  final double fps;
  final int durationMs;
  final bool ok;

  /// Whether the engine attached a hardware decoder (VideoToolbox) for this
  /// clip. False means software decode (no HW config / device-create failure /
  /// a HW-unsupported codec such as AV1).
  final bool hw;

  /// Clockwise quarter turns (0-3) the frame needs for display, from the
  /// container's rotation. [width] and [height] are the stored frame size.
  final int quarterTurns;
}

/// One decoded frame as tightly-rowed RGBA8888. [stride] is the byte length
/// of a row (≥ width*4; equals width*4 when the decoder emits no row
/// padding), so [rgba] holds exactly `stride * height` bytes.
class FfmpegFrame {
  const FfmpegFrame({
    required this.rgba,
    required this.width,
    required this.height,
    required this.stride,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final int stride;
}

/// One hardware-decoded frame as an opaque, retained VideoToolbox
/// CVPixelBuffer (BGRA, IOSurface-backed). [address] is the native pointer to
/// hand the FfmpegVideo texture controller via `present`; it carries a +1
/// retain that the native side adopts, or that must be released via
/// [FfmpegDecoderClient.releasePixbuf] if never presented.
class FfmpegPixbuf {
  const FfmpegPixbuf({
    required this.address,
    required this.width,
    required this.height,
  });

  final int address;
  final int width;
  final int height;
}

// ---------------------------------------------------------------------------
// Client (UI-isolate side)
// ---------------------------------------------------------------------------

/// Drives the engine's video decoder from a dedicated isolate.
///
/// The decoder is not thread-safe and holds an opaque native handle, so a
/// single worker isolate owns it and serializes every call. Requests are
/// correlated by id over a single reply port; the worker copies each RGBA
/// frame off the decoder-owned buffer (valid only until the next call) and
/// moves it back as [TransferableTypedData], so no native memory is shared
/// across isolates.
///
/// One client per [FfmpegEngineBackend]; the pop-out window builds its own
/// backend in its own Flutter engine and so gets an independent decoder.
class FfmpegDecoderClient {
  Isolate? _isolate;
  SendPort? _toWorker;
  final ReceivePort _fromWorker = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool _started = false;
  bool _shutDown = false;

  /// Set when the worker isolate exits. Every later request fails at
  /// once with a null reply.
  bool _workerDead = false;
  bool _startFailureLogged = false;

  // The worker's exit and uncaught-error notifications, attached at spawn
  // so a worker that dies before its handshake is seen (ES-266).
  final RawReceivePort _exitPort = RawReceivePort();
  final RawReceivePort _errorPort = RawReceivePort();
  final Completer<void> _exited = Completer<void>();
  Timer? _handshakeTimer;

  /// How long the worker has after spawn to send its command port. Opening
  /// the engine library and binding its symbols takes milliseconds; a
  /// worker still silent after this is treated as dead.
  @visibleForTesting
  static Duration handshakeTimeout = const Duration(seconds: 10);

  /// Replaces the worker's entry point in tests, with one that exits,
  /// throws or stays silent instead of decoding.
  @visibleForTesting
  static void Function(Object init)? entryForTesting;

  // Lazily-bound release for CVPixelBuffer handles on THIS (UI) isolate. The
  // engine's eclipsa_studio_video_release_pixbuf is a thread-safe CFRelease, so
  // a never-presented buffer can be freed here without a round-trip through the
  // worker (which may already be tearing down). The dylib is opened once on
  // first use; the lookup inside EngineBindings is itself lazy and cached.
  static EngineBindings? _bindings;

  static void _releasePixbuf(int address) {
    if (address == 0) return;
    final bindings = _bindings ??= EngineBindings(
      DynamicLibrary.open(EclipsaStudioEngine.dylibPath),
    );
    bindings.videoReleasePixbuf(Pointer<Void>.fromAddress(address));
  }

  /// Spawns the worker on first use and waits for its command port.
  /// Throws when the worker cannot come up: it exited or threw before the
  /// handshake, its spawn failed, or [handshakeTimeout] passed. Every later
  /// call sees the same error, so nothing waits on a worker that is gone.
  Future<void> _ensureStarted() async {
    if (_started) {
      await _ready.future;
      return;
    }
    _started = true;
    _fromWorker.listen(_onWorkerMessage);
    // Without these, a worker that died before its handshake -- an engine
    // library that fails to open or bind, say -- left _ready pending for
    // good: loadFile hung with no error notice, and the pop-out's close
    // path blocked on the same future before its bounded waits were
    // reached, so the window could not be closed (ES-266). The error may
    // land before anyone awaits _ready, so the future is marked handled.
    _ready.future.ignore();
    _exitPort.handler = (Object? _) {
      if (!_exited.isCompleted) _exited.complete();
      _failHandshake(
        StateError('ffmpeg decoder worker exited before its handshake'),
      );
      // A worker that exits after the handshake leaves requests in flight
      // and a dead command port: fail them all now, and make every later
      // request fail at once instead of posting to the dead port.
      _workerDead = true;
      _failPending();
    };
    _errorPort.handler = (Object? msg) {
      // [error, stack trace] as strings, as Isolate.addErrorListener sends.
      final list = msg as List<Object?>;
      Log.e(LogCat.video, 'ffmpeg decoder worker error: ${list[0]}', list[1]);
      _failHandshake(
        StateError('ffmpeg decoder worker failed before its handshake'),
      );
    };
    _handshakeTimer = Timer(
      handshakeTimeout,
      () => _failHandshake(
        TimeoutException(
          'ffmpeg decoder worker sent no command port',
          handshakeTimeout,
        ),
      ),
    );
    final init = _IsolateInit(
      EclipsaStudioEngine.dylibPath,
      _fromWorker.sendPort,
    );
    try {
      final testEntry = entryForTesting;
      _isolate = testEntry != null
          ? await Isolate.spawn<Object>(
              testEntry,
              init,
              debugName: 'ffmpeg-video-decoder',
              onExit: _exitPort.sendPort,
              onError: _errorPort.sendPort,
            )
          : await Isolate.spawn(
              _decoderIsolate,
              init,
              debugName: 'ffmpeg-video-decoder',
              onExit: _exitPort.sendPort,
              onError: _errorPort.sendPort,
            );
    } on Object catch (e) {
      _failHandshake(e);
    }
    await _ready.future;
  }

  /// Completes every request in flight with null, the failed reply.
  void _failPending() {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.complete(null);
    }
  }

  void _failHandshake(Object error) {
    if (_ready.isCompleted) return;
    _handshakeTimer?.cancel();
    _ready.completeError(error);
  }

  void _onWorkerMessage(Object? msg) {
    // First message is the worker's command port (handshake); the rest are
    // [id, payload] replies.
    if (msg is SendPort) {
      // Assign _toWorker here — before completing _ready — so every awaiter of
      // _ensureStarted() sees a non-null port, not just the first caller. On
      // load, open() (from loadFile) and renderAt() (from the 60 Hz tick) call
      // _send concurrently; if a non-initiating caller resumed before the
      // initiator assigned _toWorker, it would deref null.
      _toWorker = msg;
      _handshakeTimer?.cancel();
      if (!_ready.isCompleted) _ready.complete(msg);
      return;
    }
    final list = msg as List<Object?>;
    final id = list[0] as int;
    final payload = list[1];
    final completer = _pending.remove(id);
    if (completer != null) {
      completer.complete(payload);
      return;
    }
    // The request was already failed by shutdown() (its completer is gone). If
    // the reply carried a retained CVPixelBuffer, release it here so the
    // teardown race doesn't leak the frame.
    if (payload is List && payload.isNotEmpty && payload[0] == 'pixbuf') {
      _releasePixbuf(payload[1] as int);
    }
  }

  Future<Object?> _send(String kind, [Object? arg]) async {
    if (_shutDown) return null;
    try {
      await _ensureStarted();
    } on Object catch (e) {
      // A null reply is a failed request to every caller: open() reports
      // the load as failed, and the render paths count a missing frame.
      if (!_startFailureLogged) {
        _startFailureLogged = true;
        Log.e(LogCat.video, 'ffmpeg decoder worker unavailable', e);
      }
      return null;
    }
    if (_shutDown || _workerDead) return null;
    final port = _toWorker;
    if (port == null) return null; // teardown race — worker never came up
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<Object?>[id, kind, arg]);
    return completer.future;
  }

  /// Open [path] and resolve its stream info, or null on failure.
  Future<FfmpegVideoInfo?> open(String path) async {
    final reply = await _send('open', path);
    if (reply == null) return null;
    final l = reply as List<Object?>;
    return FfmpegVideoInfo(
      width: l[0] as int,
      height: l[1] as int,
      fps: l[2] as double,
      durationMs: l[3] as int,
      ok: (l[4] as int) != 0,
      hw: (l[5] as int) != 0,
      quarterTurns: l[6] as int,
    );
  }

  /// Decode the frame nearest [seconds], or null on failure / no clip open.
  Future<FfmpegFrame?> renderAt(double seconds) async {
    final reply = await _send('render', seconds);
    if (reply == null) return null;
    final l = reply as List<Object?>;
    final bytes = (l[0] as TransferableTypedData).materialize().asUint8List();
    return FfmpegFrame(
      rgba: bytes,
      width: l[1] as int,
      height: l[2] as int,
      stride: l[3] as int,
    );
  }

  /// Decode the frame nearest [seconds] as a hardware CVPixelBuffer, or null
  /// when the frame is software-decoded (caller falls back to [renderAt]) or on
  /// failure. The returned [FfmpegPixbuf.address] must be handed to the native
  /// texture (`present`) or released via [releasePixbuf].
  Future<FfmpegPixbuf?> renderPixbufAt(double seconds) async {
    final reply = await _send('renderPixbuf', seconds);
    if (reply == null) return null;
    final l = reply as List<Object?>; // ['pixbuf', address, w, h]
    return FfmpegPixbuf(
      address: l[1] as int,
      width: l[2] as int,
      height: l[3] as int,
    );
  }

  /// Release a CVPixelBuffer handle obtained from [renderPixbufAt] but never
  /// presented (e.g. a shutdown race). Safe to call from this (UI) isolate:
  /// the underlying release is a thread-safe CFRelease independent of the
  /// decoder.
  void releasePixbuf(int address) => _releasePixbuf(address);

  /// Release the current clip; the worker stays alive for the next [open].
  Future<void> close() async {
    await _send('close');
  }

  /// Permanently stop the worker and free its native resources. Idempotent.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    // Resolve the worker's command port first — this also guarantees
    // Isolate.spawn has completed, so [_isolate] below is the live worker.
    SendPort? worker;
    if (_started) {
      try {
        worker = await _ready.future;
      } on Object catch (e) {
        Log.w(LogCat.video, 'ffmpeg decoder worker unavailable at shutdown', e);
      }
    }
    // The exit notification was attached at spawn (onExit), so a worker
    // that is already dead has completed [_exited] and the bounded await
    // below returns at once; attaching after the send could miss it.
    final isolate = _isolate;
    if (worker != null) {
      // Graceful: the worker closes its decoder + scratch and exits, so
      // native memory is freed rather than leaked on an isolate kill.
      worker.send(<Object?>[null, 'shutdown', null]);
    } else {
      isolate?.kill(priority: Isolate.immediate);
    }
    // Fail any in-flight requests so awaiters don't hang.
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
    // Don't close _fromWorker yet: a reply already sent by the worker (e.g.
    // a renderPixbuf carrying a retained CVPixelBuffer) must still reach
    // _onWorkerMessage's orphan-release path — a closed port would drop it
    // and leak the frame.
    if (isolate == null) {
      _fromWorker.close();
      _closePorts();
      return;
    }
    // AWAIT the worker's exit (bounded in case the notification never arrives)
    // rather than fire-and-forget. The pop-out window destroys its Flutter
    // engine as soon as this shutdown chain returns; a worker still inside
    // eclipsa_studio_video_close (deleting a 4K HW decoder takes real time)
    // counts as "at safepoint" while in the FFI call, so the engine teardown
    // proceeds and frees the isolate group's JIT code pages — and the worker
    // then returns from native code onto a freed page (0xC0000005 DEP crash in
    // eclipsa_studio_video_close's caller; first seen closing the Windows
    // pop-out on the FFmpeg backend).
    try {
      await _exited.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      Log.w(LogCat.video, 'ffmpeg decoder worker did not exit within 5s');
    }
    _fromWorker.close();
    _closePorts();
  }

  void _closePorts() {
    _handshakeTimer?.cancel();
    _exitPort.close();
    _errorPort.close();
  }
}

// ---------------------------------------------------------------------------
// Worker (decoder-isolate side)
// ---------------------------------------------------------------------------

/// Handshake payload for the decoder isolate: where to find the engine dylib
/// and the port to send replies back on.
class _IsolateInit {
  const _IsolateInit(this.dylibPath, this.replyPort);

  final String dylibPath;
  final SendPort replyPort;
}

/// Entry point of the decoder isolate. Owns the native decoder handle and
/// serves open/render/close/shutdown commands until told to stop.
void _decoderIsolate(_IsolateInit init) {
  final bindings = EngineBindings(DynamicLibrary.open(init.dylibPath));
  final open = bindings.videoOpen;
  final infoOf = bindings.videoInfo;
  final frameAt = bindings.videoFrameAtSeconds;
  final frameAtPixbuf = bindings.videoFrameAtSecondsPixbuf;
  final close = bindings.videoClose;

  // Out-param scratch for frameAt, reused across calls.
  final wPtr = ffi_pkg.malloc<Int32>();
  final hPtr = ffi_pkg.malloc<Int32>();
  final stridePtr = ffi_pkg.malloc<Int32>();

  var decoder = Pointer<Void>.fromAddress(0);

  void releaseDecoder() {
    if (decoder.address != 0) {
      close(decoder);
      decoder = Pointer<Void>.fromAddress(0);
    }
  }

  final commands = ReceivePort();
  init.replyPort.send(commands.sendPort);

  commands.listen((Object? message) {
    final list = message as List<Object?>;
    final id = list[0] as int?;
    final kind = list[1] as String;

    switch (kind) {
      case 'shutdown':
        releaseDecoder();
        ffi_pkg.malloc
          ..free(wPtr)
          ..free(hPtr)
          ..free(stridePtr);
        commands.close(); // Isolate ends once the port is closed.
        return;

      case 'open':
        releaseDecoder();
        final path = list[2] as String;
        final pathPtr = path.toNativeUtf8(allocator: ffi_pkg.malloc);
        try {
          decoder = open(pathPtr);
        } finally {
          ffi_pkg.malloc.free(pathPtr);
        }
        if (decoder.address == 0) {
          init.replyPort.send(<Object?>[id, null]);
          return;
        }
        final info = infoOf(decoder);
        init.replyPort.send(<Object?>[
          id,
          <Object?>[
            info.width,
            info.height,
            info.fps,
            info.durationMs,
            info.ok,
            info.hw,
            info.quarterTurns,
          ],
        ]);
        return;

      case 'render':
        if (decoder.address == 0) {
          init.replyPort.send(<Object?>[id, null]);
          return;
        }
        final seconds = list[2] as double;
        final ptr = frameAt(decoder, seconds, wPtr, hPtr, stridePtr);
        if (ptr.address == 0) {
          init.replyPort.send(<Object?>[id, null]);
          return;
        }
        final h = hPtr.value;
        final stride = stridePtr.value;
        // Copy off the decoder-owned buffer (only valid until the next call)
        // before moving it across the port.
        final bytes = Uint8List.fromList(ptr.asTypedList(stride * h));
        init.replyPort.send(<Object?>[
          id,
          <Object?>[
            TransferableTypedData.fromList(<Uint8List>[bytes]),
            wPtr.value,
            h,
            stride,
          ],
        ]);
        return;

      case 'renderPixbuf':
        if (decoder.address == 0) {
          init.replyPort.send(<Object?>[id, null]);
          return;
        }
        final seconds = list[2] as double;
        final buf = frameAtPixbuf(decoder, seconds, wPtr, hPtr);
        if (buf.address == 0) {
          // Software frame (or failure) — caller falls back to the RGBA path.
          init.replyPort.send(<Object?>[id, null]);
          return;
        }
        // Tag so a reply dropped by a shutdown race is recognised and the
        // retained CVPixelBuffer released rather than leaked.
        init.replyPort.send(<Object?>[
          id,
          <Object?>['pixbuf', buf.address, wPtr.value, hPtr.value],
        ]);
        return;

      case 'close':
        releaseDecoder();
        init.replyPort.send(<Object?>[id, null]);
        return;
    }
  });
}
