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

// Pins the video provider's ordering of loads and unloads (ES-841): they
// run one at a time, and a load overtaken by a newer call leaves the
// state to that call. Uses still images, whose backend needs no
// platform channel.

import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _onePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// 3 px wide, so the frame width tells which file the backend opened.
final _threePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAABCAYAAAAb4BS0AAAAD0lEQVR4nGP8z8DwnwEKABUFAgC03+jjAAAAAElFTkSuQmCC',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String a;
  late String b;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('video_order_test');
    a = p.join(tmp.path, 'a.png');
    b = p.join(tmp.path, 'b.png');
    await File(a).writeAsBytes(_onePxPng);
    await File(b).writeAsBytes(_threePxPng);
  });

  tearDown(() => tmp.delete(recursive: true));

  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('an unload called during a load wins', () async {
    final c = makeContainer();
    final n = c.read(videoProvider.notifier);
    final loading = n.loadFile(a);
    final unloading = n.unload();
    expect(await loading, isNull);
    await unloading;
    expect(c.read(videoProvider).filePath, isNull);
  });

  test('the later of two loads wins', () async {
    final c = makeContainer();
    final n = c.read(videoProvider.notifier);
    final first = n.loadFile(a);
    final second = n.loadFile(b);
    expect(await first, isNull);
    expect(await second, isNull);
    expect(c.read(videoProvider).filePath, b);
  });

  test('a load after an unload opens the file', () async {
    final c = makeContainer();
    final n = c.read(videoProvider.notifier);
    await n.unload();
    expect(await n.loadFile(a), isNull);
    expect(c.read(videoProvider).filePath, a);
  });

  test('an unload fired during a load survives disposal', () async {
    // newSession() and returnToLanding() fire unload() without awaiting
    // it; the container can be disposed before it runs (ES-825).
    final c = ProviderContainer();
    final n = c.read(videoProvider.notifier);
    final loading = n.loadFile(a);
    final unloading = n.unload();
    c.dispose();
    expect(await loading, isNull);
    await unloading;
  });

  test('a pop-in after an unload does not reopen the file', () async {
    final c = makeContainer();
    final n = c.read(videoProvider.notifier);
    expect(await n.loadFile(a), isNull);
    // New Session's unload is queued ahead of the pop-in's reload.
    final unloading = n.unload();
    final poppingIn = n.exitPopOut();
    await unloading;
    await poppingIn;
    final s = c.read(videoProvider);
    expect(s.filePath, isNull);
    expect(s.videoWidth, isNull, reason: 'no metadata from a reopened file');
  });

  test('a pop-in after a newer load keeps the newer file', () async {
    final c = makeContainer();
    final n = c.read(videoProvider.notifier);
    expect(await n.loadFile(a), isNull);
    final loadingB = n.loadFile(b);
    final poppingIn = n.exitPopOut();
    expect(await loadingB, isNull);
    await poppingIn;
    expect(c.read(videoProvider).filePath, b);
    expect(
      c.read(videoProvider).videoWidth,
      3,
      reason: 'the backend still holds b, not a reopened a',
    );
  });
}
