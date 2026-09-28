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

import 'dart:io';

import 'package:eclipsa_studio/session/app_preferences.dart';
import 'package:eclipsa_studio/session/recent_qc_files.dart';
import 'package:eclipsa_studio/session/recent_sessions.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Routes the app-support directory to a per-run temp folder so the
/// preference and recent-list files do real IO without a platform channel.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Every remembered picker folder, paired with the provider that owns it.
/// Adding a folder means adding a row here — which is the point: the
/// round-trip below then covers it automatically.
final _providers = <String, NotifierProvider<LastDirNotifier, String?>>{
  'import': lastImportDirProvider,
  'video import': lastVideoImportDirProvider,
  'ADM destination': lastAdmDestDirProvider,
  'export': lastExportDirProvider,
  'log export': lastLogExportDirProvider,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('last_dirs_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
  });

  tearDown(() => dir.delete(recursive: true));

  test('each remembered folder persists under its own key', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Give every folder a distinct value in one batch.
    for (final entry in _providers.entries) {
      container
          .read(entry.value.notifier)
          .set(p.join(dir.path, entry.key.replaceAll(' ', '_')));
    }
    // set() persists without awaiting; let the write chain drain.
    await AppPreferences.set(AppPreferences.kThemeMode, 'dark');

    final prefs = await AppPreferences.load();
    final seenKeys = <String>{};
    for (final entry in _providers.entries) {
      final notifier = container.read(entry.value.notifier);
      final expected = p.join(dir.path, entry.key.replaceAll(' ', '_'));
      expect(
        container.read(entry.value),
        expected,
        reason: '${entry.key} dir not held in state',
      );
      expect(
        prefs[notifier.prefKey],
        expected,
        reason: '${entry.key} dir not persisted under ${notifier.prefKey}',
      );
      // No two folders may share a key, or they would overwrite each other.
      expect(
        seenKeys.add(notifier.prefKey),
        isTrue,
        reason: 'duplicate preference key ${notifier.prefKey}',
      );
    }
  });

  test('restore() rehydrates state without writing back', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    for (final entry in _providers.entries) {
      container.read(entry.value.notifier).restore('/restored/${entry.key}');
      expect(container.read(entry.value), '/restored/${entry.key}');
    }

    // restore() is the app-launch path: it must not persist, or a launch
    // would rewrite preferences it only just read.
    final prefs = await AppPreferences.load();
    for (final entry in _providers.entries) {
      final key = container.read(entry.value.notifier).prefKey;
      expect(prefs.containsKey(key), isFalse, reason: '$key written back');
    }
  });

  test('folders start null so pickers fall back to their own defaults', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    for (final entry in _providers.entries) {
      expect(container.read(entry.value), isNull, reason: entry.key);
    }
  });

  group('recent-list seeded folders', () {
    test(
      'RecentSessions.lastDirectory returns the newest live folder',
      () async {
        expect(await RecentSessions.lastDirectory(), isNull);

        final gone = p.join(dir.path, 'deleted');
        final live = await Directory(p.join(dir.path, 'projects')).create();
        // add() prepends, so the deleted one is newest and must be skipped.
        await RecentSessions.add(p.join(live.path, 'old.esp'));
        await RecentSessions.add(p.join(gone, 'missing.esp'));

        expect(await RecentSessions.lastDirectory(), live.path);
      },
    );

    test(
      'RecentQcFiles.lastDirectory returns the newest live folder',
      () async {
        expect(await RecentQcFiles.lastDirectory(), isNull);

        final live = await Directory(p.join(dir.path, 'deliverables')).create();
        await RecentQcFiles.add(p.join(live.path, 'mix.iamf'));

        expect(await RecentQcFiles.lastDirectory(), live.path);
      },
    );
  });
}
