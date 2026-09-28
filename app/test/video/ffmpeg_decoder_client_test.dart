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

import 'dart:isolate';

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/logging/log.dart';
import 'package:eclipsa_studio/video/ffmpeg_video_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// A worker that returns without sending its command port: its isolate
/// exits as soon as its event loop is empty.
void _exitsAtOnce(Object init) {}

/// A worker that throws before the handshake, as one whose engine
/// library fails to open would.
void _throwsAtOnce(Object init) {
  throw StateError('no engine library');
}

/// A worker that never answers. The open port keeps its isolate alive.
void _staysSilent(Object init) {
  ReceivePort();
}

/// A worker that completes its handshake, then exits on its first
/// request without replying, as one that crashes mid-decode would.
void _exitsOnFirstRequest(Object init) {
  final reply = (init as dynamic).replyPort as SendPort;
  final commands = ReceivePort();
  reply.send(commands.sendPort);
  commands.listen((_) => Isolate.exit());
}

/// The decoder client must not wait forever on a worker that never
/// completes its handshake: a dead worker used to hang loadFile and make
/// the pop-out unclosable (ES-266). Each case must fail the request and let
/// shutdown finish, well inside the 5 s the shutdown path allows.
void main() {
  setUp(() {
    EclipsaStudioEngine.dylibPathOverride =
        '/nonexistent/libeclipsa_studio_engine.dylib';
    Log.instance.clear();
  });

  tearDown(() {
    FfmpegDecoderClient.entryForTesting = null;
    FfmpegDecoderClient.handshakeTimeout = const Duration(seconds: 10);
    EclipsaStudioEngine.dylibPathOverride = null;
  });

  Future<void> expectFailsFast(FfmpegDecoderClient client) async {
    final info = await client
        .open('/nonexistent.mp4')
        .timeout(const Duration(seconds: 5));
    expect(info, isNull);
    await client.shutdown().timeout(const Duration(seconds: 5));
    expect(
      Log.instance.entries.any(
        (e) =>
            e.level == LogLevel.error &&
            e.message == 'ffmpeg decoder worker unavailable',
      ),
      isTrue,
      reason: 'the failure is logged once',
    );
  }

  test('a worker that exits before its handshake fails the open', () async {
    FfmpegDecoderClient.entryForTesting = _exitsAtOnce;
    await expectFailsFast(FfmpegDecoderClient());
  });

  test('a worker that throws before its handshake fails the open', () async {
    FfmpegDecoderClient.entryForTesting = _throwsAtOnce;
    await expectFailsFast(FfmpegDecoderClient());
    expect(
      Log.instance.entries.any(
        (e) => e.message.startsWith('ffmpeg decoder worker error:'),
      ),
      isTrue,
      reason: "the worker's own error is logged",
    );
  });

  test('a worker that stays silent fails the open at the timeout', () async {
    FfmpegDecoderClient.entryForTesting = _staysSilent;
    FfmpegDecoderClient.handshakeTimeout = const Duration(milliseconds: 200);
    await expectFailsFast(FfmpegDecoderClient());
  });

  test('every request after the failure fails at once', () async {
    FfmpegDecoderClient.entryForTesting = _exitsAtOnce;
    final client = FfmpegDecoderClient();
    expect(await client.open('/a.mp4'), isNull);
    expect(await client.renderAt(1.0), isNull);
    expect(await client.renderPixbufAt(1.0), isNull);
    await client.shutdown();
  });

  test('a worker that exits after its handshake fails the requests', () async {
    FfmpegDecoderClient.entryForTesting = _exitsOnFirstRequest;
    final client = FfmpegDecoderClient();
    final info = await client
        .open('/a.mp4')
        .timeout(const Duration(seconds: 5));
    expect(info, isNull, reason: 'the request in flight fails on exit');
    expect(
      await client.renderAt(1.0).timeout(const Duration(seconds: 5)),
      isNull,
      reason: 'a later request fails at once',
    );
    await client.shutdown().timeout(const Duration(seconds: 5));
  });
}
