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

// Pins the session save and load races found by the 2026-09 review:
// a save replaces the .esp atomically and a failed write leaves the
// previous file intact (ES-840), a load overtaken by New Session or a
// second load writes nothing (ES-841), and a save keeps the session dirty
// for an edit made while it was writing (ES-842).

import 'dart:async';
import 'dart:io';

import 'package:eclipsa_studio/session/atomic_write.dart';
import 'package:eclipsa_studio/session/session_model.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/session_env.dart';

AudioElement _element(int id) => AudioElement(
  id: id,
  name: 'El $id',
  type: 'Channel',
  layout: 'Stereo',
  codec: 'LPCM',
  color: 0xFF000000,
);

/// A video notifier whose loads wait for [gate], so a test can hold a
/// session load at its video step, after it has written the providers.
class _HeldVideo extends VideoNotifier {
  static Completer<void> gate = Completer<void>();
  static int loadsStarted = 0;

  @override
  Future<String?> loadFile(String path) async {
    loadsStarted++;
    await gate.future;
    return null;
  }

  @override
  Future<void> unload() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory support;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_races');
    support = await Directory.systemTemp.createTemp('session_races_support');
    PathProviderPlatform.instance = FakePathProvider(support.path);
  });

  tearDown(() async {
    for (final d in [dir, support]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [recentSessionsProvider.overrideWith(StubRecentSessions.new)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<String> writeSession(
    String name,
    List<AudioElement> elements, {
    String? mediaPath,
  }) async {
    final path = p.join(dir.path, name);
    await File(path).writeAsString(
      SessionModel(
        elements: elements,
        mediaPath: mediaPath,
      ).encode(relativeTo: dir.path),
    );
    return path;
  }

  /// A container whose video loads wait for [_HeldVideo.gate].
  ProviderContainer makeHeldContainer() {
    _HeldVideo.gate = Completer<void>();
    _HeldVideo.loadsStarted = 0;
    final c = ProviderContainer(
      overrides: [
        recentSessionsProvider.overrideWith(StubRecentSessions.new),
        videoProvider.overrideWith(_HeldVideo.new),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Runs microtasks and timers until the held load reaches its video
  /// step.
  Future<void> untilVideoHeld() async {
    for (var i = 0; i < 100 && _HeldVideo.loadsStarted == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(_HeldVideo.loadsStarted, 1, reason: 'the load reached its video');
  }

  group('atomic write (ES-840)', () {
    test('permission codes are chosen per platform', () {
      // POSIX: EPERM and EACCES; 5 is EIO there, an I/O failure.
      expect(isPermissionErrorCode(1, windows: false), isTrue);
      expect(isPermissionErrorCode(13, windows: false), isTrue);
      expect(isPermissionErrorCode(5, windows: false), isFalse);
      expect(isPermissionErrorCode(28, windows: false), isFalse); // ENOSPC
      expect(isPermissionErrorCode(null, windows: false), isFalse);
      // Windows: ERROR_ACCESS_DENIED only.
      expect(isPermissionErrorCode(5, windows: true), isTrue);
      expect(isPermissionErrorCode(1, windows: true), isFalse);
      expect(isPermissionErrorCode(13, windows: true), isFalse);
      expect(isPermissionErrorCode(32, windows: true), isFalse);
    });

    test('replaces the file and leaves no temp file', () async {
      final path = p.join(dir.path, 's.esp');
      await File(path).writeAsString('old');
      final mode = await writeStringAtomically(path, 'new');
      expect(await File(path).readAsString(), 'new');
      expect(dir.listSync().map((e) => p.basename(e.path)), [
        's.esp',
      ], reason: 'no temp file is left behind');
      expect(mode, AtomicWriteMode.rename);
    });

    test('a failure other than permission keeps the previous file', () async {
      final path = p.join(dir.path, 's.esp');
      await File(path).writeAsString('last good');
      // A directory in place of the file makes the rename fail with an
      // error that is not a permission error, after the temp file was
      // written.
      await File(path).delete();
      await Directory(path).create();
      await File(p.join(path, 'keep')).writeAsString('last good');
      await expectLater(
        writeStringAtomically(path, 'new'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(p.join(path, 'keep')).readAsString(), 'last good');
      expect(
        dir.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
        reason: 'the temp file is removed after a failure',
      );
    });

    test(
      'no permission to write beside the file falls back in place',
      () async {
        final sub = await Directory(p.join(dir.path, 'locked')).create();
        final path = p.join(sub.path, 's.esp');
        await File(path).writeAsString('old');
        await Process.run('chmod', ['555', sub.path]);
        addTearDown(() => Process.run('chmod', ['755', sub.path]));
        final mode = await writeStringAtomically(path, 'new');
        expect(mode, AtomicWriteMode.inPlace);
        expect(await File(path).readAsString(), 'new');
      },
      skip: Platform.isWindows ? 'POSIX permissions' : null,
    );
  });

  group('save and the dirty flag (ES-842)', () {
    test('a save with no edit during it clears dirty', () async {
      final c = makeContainer();
      final n = c.read(sessionProvider.notifier)..markDirty();
      expect(await n.saveToPath(p.join(dir.path, 'a.esp')), isTrue);
      expect(c.read(sessionProvider).dirty, isFalse);
    });

    test('an edit while the save is writing keeps the session dirty', () async {
      final c = makeContainer();
      final n = c.read(sessionProvider.notifier)..markDirty();
      final saving = n.saveToPath(p.join(dir.path, 'a.esp'));
      // The snapshot is taken before the first await; this edit is not
      // in the file.
      n.markDirty();
      expect(await saving, isTrue);
      expect(c.read(sessionProvider).dirty, isTrue);
      expect(c.read(sessionProvider).filePath, p.join(dir.path, 'a.esp'));
    });
  });

  group('overtaken loads (ES-841)', () {
    test('New Session during a load keeps the new session', () async {
      final a = await writeSession('a.esp', [_element(1), _element(2)]);
      final c = makeContainer();
      // New Session's callers enter Creator first (workspace_actions.dart).
      c.read(workspaceModeProvider.notifier).enterCreator();
      final n = c.read(sessionProvider.notifier);
      final loading = n.loadFile(a);
      n.newSession();
      expect(await loading, isFalse);
      final s = c.read(sessionProvider);
      expect(s.filePath, isNull);
      expect(s.loading, isFalse);
      expect(c.read(elementsProvider), isEmpty);
    });

    test('a second load during the first leaves the second', () async {
      final a = await writeSession('a.esp', [_element(1)]);
      final b = await writeSession('b.esp', [_element(7), _element(8)]);
      final c = makeContainer();
      final n = c.read(sessionProvider.notifier);
      final first = n.loadFile(a);
      final second = n.loadFile(b);
      expect(await second, isTrue);
      expect(await first, isFalse);
      expect(c.read(sessionProvider).filePath, b);
      expect(c.read(elementsProvider).map((e) => e.id), [7, 8]);
      expect(c.read(sessionProvider).loading, isFalse);
    });
  });

  group('loads overtaken after writing the providers (ES-841)', () {
    test('New Session while a load waits for its video', () async {
      final a = await writeSession('a.esp', [
        _element(1),
      ], mediaPath: p.join(dir.path, 'clip.mp4'));
      final c = makeHeldContainer();
      c.read(workspaceModeProvider.notifier).enterCreator();
      final n = c.read(sessionProvider.notifier);
      final loading = n.loadFile(a);
      await untilVideoHeld();
      expect(c.read(elementsProvider).map((e) => e.id), [1]);

      n.newSession();
      _HeldVideo.gate.complete();
      expect(await loading, isFalse);
      expect(c.read(elementsProvider), isEmpty);
      expect(c.read(sessionProvider).filePath, isNull);
      expect(c.read(sessionProvider).loading, isFalse);
    });

    test('a load that overtakes a half-applied one and fails resets', () async {
      final open = await writeSession('open.esp', [_element(5)]);
      final a = await writeSession('a.esp', [
        _element(1),
      ], mediaPath: p.join(dir.path, 'clip.mp4'));
      final c = makeHeldContainer();
      final n = c.read(sessionProvider.notifier);
      _HeldVideo.gate.complete();
      expect(await n.loadFile(open), isTrue);

      _HeldVideo.gate = Completer<void>();
      _HeldVideo.loadsStarted = 0;
      final loadingA = n.loadFile(a);
      await untilVideoHeld();
      expect(c.read(elementsProvider).map((e) => e.id), [1]);

      // B fails: its file does not exist.
      expect(await n.loadFile(p.join(dir.path, 'missing.esp')), isFalse);
      _HeldVideo.gate.complete();
      expect(await loadingA, isFalse);

      final s = c.read(sessionProvider);
      expect(
        s.filePath,
        isNull,
        reason: "A's elements must not stay under open.esp's path",
      );
      expect(c.read(elementsProvider), isEmpty);
      expect(s.lastError, contains('Could not read'));
      expect(s.loading, isFalse);
    });

    test('a save during a load is refused', () async {
      final a = await writeSession('a.esp', [
        _element(1),
      ], mediaPath: p.join(dir.path, 'clip.mp4'));
      final c = makeHeldContainer();
      final n = c.read(sessionProvider.notifier);
      final loading = n.loadFile(a);
      await untilVideoHeld();
      expect(await n.saveToPath(p.join(dir.path, 'x.esp')), isFalse);
      expect(File(p.join(dir.path, 'x.esp')).existsSync(), isFalse);
      expect(c.read(sessionProvider).lastError, contains('still loading'));
      _HeldVideo.gate.complete();
      expect(await loading, isTrue);
    });
  });

  group('loads cancelled by a workspace switch', () {
    test('a load cancelled on leaving Creator writes nothing more', () async {
      final a = await writeSession('a.esp', [
        _element(1),
      ], mediaPath: p.join(dir.path, 'clip.mp4'));
      final c = makeHeldContainer();
      final n = c.read(sessionProvider.notifier);
      final loading = n.loadFile(a);
      await untilVideoHeld();

      // prepareForWorkspaceSwitch cancels the load before Playback.
      n.cancelLoad();
      c.read(workspaceModeProvider.notifier).enterPlayback();
      expect(c.read(sessionProvider).loading, isFalse);
      _HeldVideo.gate.complete();
      expect(await loading, isFalse);
      expect(c.read(sessionProvider).filePath, isNull);

      // A later failing open in Playback reports the error and does not
      // reset the workspace to a new Creator session.
      expect(await n.loadFile(p.join(dir.path, 'missing.esp')), isFalse);
      expect(c.read(sessionProvider).lastError, contains('Could not read'));
      expect(c.read(workspaceModeProvider), WorkspaceMode.playback);
    });
  });
}
