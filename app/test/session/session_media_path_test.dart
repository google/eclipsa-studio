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

// A session whose media fails to load keeps its media path on save, and
// the previous session's media is not carried into it (ES-843).

import 'dart:convert';
import 'dart:io';

import 'package:eclipsa_studio/session/dirty_tracker.dart';
import 'package:eclipsa_studio/session/session_model.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/session_env.dart';

/// A video notifier that loads the paths in [loadable] and fails on any
/// other, keeping the loaded file on failure as [VideoNotifier.loadFile]
/// does.
class _FakeVideo extends VideoNotifier {
  static Set<String> loadable = {};

  @override
  Future<String?> loadFile(String path) async {
    if (!loadable.contains(path)) {
      return 'Could not load video "${p.basename(path)}"';
    }
    state = state.copyWith(filePath: path, visible: true);
    return null;
  }

  @override
  Future<void> unload() async {
    state = state.copyWith(clearFile: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory support;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_media');
    support = await Directory.systemTemp.createTemp('session_media_support');
    PathProviderPlatform.instance = FakePathProvider(support.path);
    _FakeVideo.loadable = {};
  });

  tearDown(() async {
    for (final d in [dir, support]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [
        recentSessionsProvider.overrideWith(StubRecentSessions.new),
        videoProvider.overrideWith(_FakeVideo.new),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  String media(String name) => p.join(dir.path, name);

  Future<String> writeSession(String name, {String? mediaPath}) async {
    final path = p.join(dir.path, name);
    await File(path).writeAsString(
      SessionModel(mediaPath: mediaPath).encode(relativeTo: dir.path),
    );
    return path;
  }

  /// The media path saved in the session file at [path].
  Future<String?> savedMediaPath(String path) async => SessionModel.decode(
    await File(path).readAsString(),
    resolveFrom: dir.path,
  ).mediaPath;

  test("the previous session's media is unloaded and not saved", () async {
    _FakeVideo.loadable = {media('a.mp4')};
    final a = await writeSession('a.esp', mediaPath: media('a.mp4'));
    final b = await writeSession('b.esp', mediaPath: media('b.mp4'));
    final c = makeContainer();
    final n = c.read(sessionProvider.notifier);

    expect(await n.loadFile(a), isTrue);
    expect(c.read(videoProvider).filePath, media('a.mp4'));
    expect(await n.loadFile(b), isTrue);
    expect(c.read(videoProvider).filePath, isNull);

    expect(await n.saveToPath(b), isTrue);
    expect(await savedMediaPath(b), media('b.mp4'));
  });

  test('a session with no media loaded before keeps its media', () async {
    final b = await writeSession('b.esp', mediaPath: media('b.mp4'));
    final c = makeContainer();
    final n = c.read(sessionProvider.notifier);

    expect(await n.loadFile(b), isTrue);
    expect(await n.saveToPath(b), isTrue);
    expect(await savedMediaPath(b), media('b.mp4'));
  });

  test('Save As to another folder writes the path relative to it', () async {
    final b = await writeSession('b.esp', mediaPath: media('b.mp4'));
    final c = makeContainer();
    final n = c.read(sessionProvider.notifier);
    expect(await n.loadFile(b), isTrue);

    final sub = await Directory(p.join(dir.path, 'sub')).create();
    final copy = p.join(sub.path, 'b.esp');
    expect(await n.saveToPath(copy), isTrue);
    final json = jsonDecode(await File(copy).readAsString()) as Map;
    expect(json['mediaPath'], '../b.mp4');
  });

  // DirtyTracker marks the session dirty when the video's file changes
  // outside a load; the missing path follows the same signal.
  testWidgets('the dirty flag and the missing path change together', (
    tester,
  ) async {
    final c = makeContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const DirtyTracker()),
    );
    final n = c.read(sessionProvider.notifier);
    final video = c.read(videoProvider.notifier);
    final b = await tester.runAsync(
      () => writeSession('b.esp', mediaPath: media('b.mp4')),
    );
    _FakeVideo.loadable = {media('c.mp4')};

    // A missing path found during the load leaves the session clean.
    expect(await tester.runAsync(() => n.loadFile(b!)), isTrue);
    await tester.pump();
    expect(c.read(sessionProvider).dirty, isFalse);
    expect(c.read(sessionProvider).missingMediaPath, media('b.mp4'));

    // A replacement that fails changes nothing.
    expect(
      await tester.runAsync(() => video.loadFile(media('d.mp4'))),
      isNotNull,
    );
    await tester.pump();
    expect(c.read(sessionProvider).dirty, isFalse);
    expect(c.read(sessionProvider).missingMediaPath, media('b.mp4'));

    // A replacement that loads dirties the session and drops the path.
    expect(await tester.runAsync(() => video.loadFile(media('c.mp4'))), isNull);
    await tester.pump();
    expect(c.read(sessionProvider).dirty, isTrue);
    expect(c.read(sessionProvider).missingMediaPath, isNull);
  });

  test('media loaded or removed later replaces the missing path', () async {
    _FakeVideo.loadable = {media('c.mp4')};
    final b = await writeSession('b.esp', mediaPath: media('b.mp4'));
    final c = makeContainer();
    final n = c.read(sessionProvider.notifier);
    expect(await n.loadFile(b), isTrue);

    // A replacement that also fails keeps the session's reference.
    expect(
      await c.read(videoProvider.notifier).loadFile(media('d.mp4')),
      isNotNull,
    );
    expect(await n.saveToPath(b), isTrue);
    expect(await savedMediaPath(b), media('b.mp4'));

    expect(
      await c.read(videoProvider.notifier).loadFile(media('c.mp4')),
      isNull,
    );
    expect(await n.saveToPath(b), isTrue);
    expect(await savedMediaPath(b), media('c.mp4'));

    await c.read(videoProvider.notifier).unload();
    expect(await n.saveToPath(b), isTrue);
    expect(await savedMediaPath(b), isNull);
  });

  test('removing the missing path dirties the session and drops it', () async {
    final b = await writeSession('b.esp', mediaPath: media('b.mp4'));
    final c = makeContainer();
    final n = c.read(sessionProvider.notifier);
    expect(await n.loadFile(b), isTrue);
    expect(c.read(sessionProvider).missingMediaPath, media('b.mp4'));
    expect(c.read(sessionProvider).dirty, isFalse);

    n.clearMissingMedia();
    expect(c.read(sessionProvider).missingMediaPath, isNull);
    expect(c.read(sessionProvider).dirty, isTrue);
    expect(await n.saveToPath(b), isTrue);
    expect(await savedMediaPath(b), isNull);
  });

  test('New Session drops the missing path', () async {
    final b = await writeSession('b.esp', mediaPath: media('b.mp4'));
    final c = makeContainer();
    final n = c.read(sessionProvider.notifier);
    expect(await n.loadFile(b), isTrue);

    n.newSession();
    final fresh = p.join(dir.path, 'fresh.esp');
    expect(await n.saveToPath(fresh), isTrue);
    expect(await savedMediaPath(fresh), isNull);
  });
}
