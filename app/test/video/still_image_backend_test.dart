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

import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:eclipsa_studio/video/still_image_backend.dart';
import 'package:eclipsa_studio/video/video_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A valid 1×1 transparent PNG.
final _onePxPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isStillImagePath', () {
    test('accepts the supported image extensions, case-insensitively', () {
      for (final path in [
        '/a/b.png',
        '/a/b.PNG',
        '/a/b.jpg',
        '/a/b.jpeg',
        '/a/b.webp',
        '/a/b.bmp',
        '/a/b.gif',
        r'C:\art\Cover.Jpg',
      ]) {
        expect(isStillImagePath(path), isTrue, reason: path);
      }
    });

    test('rejects videos and everything else', () {
      for (final path in [
        '/a/b.mp4',
        '/a/b.mov',
        '/a/b.webm',
        '/a/b.heic',
        '/a/b.tiff',
        '/a/b.png.mp4',
        '/a/b',
      ]) {
        expect(isStillImagePath(path), isFalse, reason: path);
      }
    });
  });

  group('StillImageBackend', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('still_image_test');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('loadFile decodes an image and reports dimension-only meta', () async {
      final path = p.join(tmp.path, 'pixel.png');
      await File(path).writeAsBytes(_onePxPng);

      final backend = StillImageBackend();
      VideoMeta? reported;
      backend.onMetaChanged = (m) => reported = m;

      final err = await backend.loadFile(path);
      expect(err, isNull);
      expect(reported, isNotNull);
      expect(reported!.width, 1);
      expect(reported!.height, 1);
      // No duration/fps: keeps the image out of the timeline reconcile and
      // hides the video track's duration bar.
      expect(reported!.duration, isNull);
      expect(reported!.fps, isNull);
      expect(backend.meta.width, 1);

      await backend.shutdown();
    });

    test('loadFile returns a user-facing error for a corrupt file', () async {
      final path = p.join(tmp.path, 'garbage.png');
      await File(path).writeAsBytes([1, 2, 3, 4, 5]);

      final backend = StillImageBackend();
      final err = await backend.loadFile(path);
      expect(err, isNotNull);
      expect(err, contains('garbage.png'));
      expect(backend.meta.width, isNull);

      await backend.shutdown();
    });

    test('loadFile returns a user-facing error for a missing file', () async {
      final backend = StillImageBackend();
      final err = await backend.loadFile(p.join(tmp.path, 'nope.png'));
      expect(err, isNotNull);
      expect(err, contains('nope.png'));

      await backend.shutdown();
    });

    test('transport methods are safe no-ops, also after shutdown', () async {
      final path = p.join(tmp.path, 'pixel.png');
      await File(path).writeAsBytes(_onePxPng);

      final backend = StillImageBackend();
      await backend.loadFile(path);
      await backend.play();
      await backend.pause();
      await backend.seekTo(12.5);
      await backend.syncToAudio(13.0, playing: true);

      await backend.shutdown();
      // The VideoBackend contract: transport calls may race a teardown and
      // must not throw afterwards.
      await backend.play();
      await backend.seekTo(0);
      await backend.shutdown(); // idempotent
    });

    test('loadFile after shutdown refuses without keeping the image', () async {
      final path = p.join(tmp.path, 'pixel.png');
      await File(path).writeAsBytes(_onePxPng);

      final backend = StillImageBackend();
      await backend.shutdown();
      final err = await backend.loadFile(path);
      expect(err, isNotNull);
      expect(backend.meta.width, isNull);
    });
  });
}
