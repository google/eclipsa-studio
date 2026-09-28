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

import 'dart:convert';
import 'dart:io';

import 'package:eclipsa_studio/debug/control_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The channel is reachable by any local process, so the token is what
/// stands between the app and one driving it. These pin the gate; the
/// /tab and /loop commands are driven against a mounted app in
/// control_channel_commands_test.dart.
void main() {
  // GlobalKey.currentContext and ProviderScope.containerOf both reach
  // for the binding; without this the channel answers 500 rather than
  // the 503 that says the token was accepted.
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding installs an HttpOverrides that answers every
  // request 400 without a socket, so a real loopback client has to opt
  // out of it or it never reaches the channel.
  HttpOverrides.global = null;

  late Directory dir;
  late DebugControlChannel channel;
  late int port;
  late String token;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('eclipsa_studio_control_test');
    final started = await DebugControlChannel.start(
      // No app is mounted, so the key resolves no context and every
      // command answers "not ready" — which is what makes the token
      // check observable on its own.
      navigatorKey: GlobalKey<NavigatorState>(),
      stateDir: dir.path,
    );
    channel = started!;
    final json =
        jsonDecode(
              File(
                '${dir.path}/eclipsa_studio_control.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    port = json['port']! as int;
    token = json['token']! as String;
  });

  tearDown(() async {
    await channel.close();
    dir.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> get(String path, {String? withToken}) async {
    final client = HttpClient();
    final request = await client.get('127.0.0.1', port, path);
    if (withToken != null) request.headers.set('x-debug-token', withToken);
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response;
  }

  test('the channel is built only in debug', () {
    expect(kDebugControlChannelEnabled, kDebugMode);
  });

  test('it writes a port and a token to the state directory', () {
    expect(port, greaterThan(0));
    // 16 random bytes, hex.
    expect(token, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('a request with no token is refused', () async {
    final response = await get('/health');
    expect(response.statusCode, HttpStatus.forbidden);
  });

  test('a request with the wrong token is refused', () async {
    final response = await get('/health', withToken: 'f' * 32);
    expect(response.statusCode, HttpStatus.forbidden);
  });

  test(
    'the token gets past the gate, and the app is what is missing',
    () async {
      // 503 rather than 403: the token was accepted and the command then
      // found no mounted app. Anything else would mean the gate leaked.
      final response = await get('/health', withToken: token);
      expect(response.statusCode, HttpStatus.serviceUnavailable);
    },
  );

  test('an unknown path is still gated', () async {
    expect((await get('/wat')).statusCode, HttpStatus.forbidden);
  });

  test('odd credentials are refused like any other bad token', () async {
    // A repeated header folds to "one, two" and a malformed escape
    // comes back raw as "%ZZ" on this SDK — neither throws — so both
    // land on the same 403 as any other wrong token.
    final client = HttpClient();

    final repeated = await client.get('127.0.0.1', port, '/health');
    repeated.headers.add('x-debug-token', 'one');
    repeated.headers.add('x-debug-token', 'two');
    final first = await repeated.close();
    await first.drain<void>();
    expect(first.statusCode, HttpStatus.forbidden);

    final malformed = await client.get('127.0.0.1', port, '/health?token=%ZZ');
    final second = await malformed.close();
    await second.drain<void>();
    expect(second.statusCode, HttpStatus.forbidden);

    client.close();
  });

  test('one wedged request does not stop the next being answered', () async {
    // The accept loop used to await each request in turn, so a command
    // that never finished blocked every later one.
    //
    // /screenshot is the one command that does not need a mounted app,
    // so here it reaches _capture and blocks for the full 2 s frame
    // timeout — no frame is ever produced under the test binding. The
    // point is the order the two finish in: with the old loop the fast
    // request could not be answered until the slow one had given up.
    final order = <String>[];
    final slow = get('/screenshot', withToken: token).then((r) {
      order.add('slow');
      return r;
    });
    final fast = await get('/health', withToken: token).then((r) {
      order.add('fast');
      return r;
    });
    expect(fast.statusCode, HttpStatus.serviceUnavailable);
    expect(order, ['fast'], reason: 'the slow request must not gate it');
    final slowResponse = await slow;
    expect(slowResponse.statusCode, HttpStatus.serviceUnavailable);
    expect(order, ['fast', 'slow']);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
