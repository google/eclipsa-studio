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
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Routes the app-support directory to a per-run temp folder so
/// [AppPreferences] does real file IO without a platform channel.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('prefs_test');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
  });

  tearDown(() => dir.delete(recursive: true));

  test('concurrent writes merge instead of clobbering each other', () async {
    // Fire without awaiting in between — mirrors two persistence
    // listeners running in the same microtask batch (e.g. theme + font
    // size). Unserialized, both load() the same stale map and the later
    // write drops the earlier key.
    await Future.wait([
      AppPreferences.set(AppPreferences.kThemeMode, 'light'),
      AppPreferences.set(AppPreferences.kFontSizeMode, 'large'),
      AppPreferences.setAll({AppPreferences.kColormap: 'viridis'}),
    ]);

    final prefs = await AppPreferences.load();
    expect(prefs[AppPreferences.kThemeMode], 'light');
    expect(prefs[AppPreferences.kFontSizeMode], 'large');
    expect(prefs[AppPreferences.kColormap], 'viridis');
  });

  test('later write wins for the same key', () async {
    await Future.wait([
      AppPreferences.set(AppPreferences.kThemeMode, 'light'),
      AppPreferences.set(AppPreferences.kThemeMode, 'dark'),
    ]);
    final prefs = await AppPreferences.load();
    expect(prefs[AppPreferences.kThemeMode], 'dark');
  });

  test('writes are atomic: no temp file left, loads never see a torn '
      'file', () async {
    await AppPreferences.set(AppPreferences.kThemeMode, 'dark');

    // Hammer writes while concurrently loading. With a non-atomic
    // writeAsString a load can catch preferences.json mid-write, hit the
    // FormatException handler, and silently return defaults (ES-420); with
    // temp-file + rename every load sees a complete file.
    final writes = <Future<void>>[];
    final loads = <Future<void>>[];
    for (var i = 0; i < 50; i++) {
      writes.add(AppPreferences.setAll({AppPreferences.kColormap: 'c$i'}));
      loads.add(
        AppPreferences.load().then((prefs) {
          expect(
            prefs[AppPreferences.kThemeMode],
            'dark',
            reason: 'load fell back to defaults mid-write',
          );
        }),
      );
    }
    await Future.wait([...writes, ...loads]);

    final leftovers = dir
        .listSync()
        .where((e) => e.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
    final prefs = await AppPreferences.load();
    expect(prefs[AppPreferences.kColormap], 'c49');
  });

  test('reset keeps audio keys and runs in the write chain', () async {
    await Future.wait([
      AppPreferences.set(AppPreferences.kAudioDeviceName, 'Duplex A'),
      AppPreferences.set(AppPreferences.kThemeMode, 'light'),
      AppPreferences.reset(),
    ]);
    final prefs = await AppPreferences.load();
    expect(prefs[AppPreferences.kAudioDeviceName], 'Duplex A');
    expect(prefs.containsKey(AppPreferences.kThemeMode), isFalse);
  });
}
