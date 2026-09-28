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

// ES-628: an element whose WAV could not be read is not handed to the
// engine. The engine open fails the same way the header read did, and
// its "Couldn't Load Audio" dialog then queues behind the notice that
// already explains the failure and carries the remedy.
//
// The skip lives in _syncElementsToEngine, which returns early when the
// engine is null, so this needs the real dylib. Skips when it has not
// been built (CI builds it before `flutter test`; run
// `./build.sh engine` locally first).

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart'
    show eclipsaStudioEngineProvider;
import 'package:eclipsa_studio/session/session_model.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';

import '../support/engine_dylib.dart';
import '../support/session_env.dart';

void main() {
  // Provider teardown reaches platform channels (video pop-out close);
  // a binding must exist for those to no-op instead of asserting.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a session with one unreadable WAV loads the rest, with one notice',
    () async {
      final dylib = engineDylibOrSkip();
      if (dylib == null) return;
      useEngineDylib(dylib);

      final dir = Directory.systemTemp.createTempSync(
        'eclipsa_studio_sync_skip',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      PathProviderPlatform.instance = FakePathProvider(dir.path);

      final good = p.join(dir.path, 'good.wav');
      File(good).writeAsBytesSync(wavBytes(channels: 2));
      // Referenced by the session, never written: the header read fails and
      // the engine open would fail identically.
      final gone = p.join(dir.path, 'gone.wav');

      final esp = p.join(dir.path, 'session.esp');
      File(esp).writeAsStringSync(
        SessionModel(
          iamfProfile: IamfProfile.baseEnhanced,
          elements: [
            for (final (i, path) in [good, gone].indexed)
              AudioElement(
                id: i + 1,
                name: p.basenameWithoutExtension(path),
                type: 'Channel',
                layout: 'Stereo',
                codec: 'LPCM',
                color: 0xFF888888,
                wavPath: path,
              ),
          ],
        ).encode(relativeTo: dir.path),
      );

      final engine = EclipsaStudioEngine();
      expect(engine.init(), 0, reason: 'engine init failed');
      addTearDown(engine.shutdown);

      final container = ProviderContainer(
        overrides: [
          eclipsaStudioEngineProvider.overrideWithValue(engine),
          recentSessionsProvider.overrideWith(StubRecentSessions.new),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(sessionProvider.notifier).loadFile(esp),
        isTrue,
      );

      final elements = container.read(elementsProvider);
      expect(elements.first.wavInfo, isNotNull);
      expect(elements.last.wavInfo, isNull);
      expect(container.read(engineOrderProvider), [
        elements.first.id,
      ], reason: 'only the readable element reaches the engine');
      expect(engine.elementIds(), [elements.first.id]);

      final notice = container.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(
        notice!.title,
        isNot("Couldn't Load Audio"),
        reason:
            'the engine must not stack a second dialog on the notice '
            'that already carries the remedy',
      );
      expect(notice.actionLabel, anyOf('Locate…', 'Grant Access…'));
    },
  );
}
