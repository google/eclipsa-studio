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

import 'package:eclipsa_studio/import/adm_import_flow.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ADM probe and bed render drive private OAR instances, so the import
/// must hold the live renderer offline-exclusive while they run, the way
/// the export dialog and the Loudness Report do. These pin the hold: it
/// stops transport, pairs every pause with a release whatever the body
/// does, and keeps play unavailable until the last hold ends.
void main() {
  late ProviderContainer c;
  late List<bool> pauses;

  setUp(() {
    c = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(null)],
    );
    pauses = <bool>[];
  });

  tearDown(() => c.dispose());

  test(
    'stops transport, holds the renderer, releases after the body',
    () async {
      c.read(playingProvider.notifier).set(true);
      var blockedInside = false;
      final result = await holdRendererForImport<int>(c, () async {
        blockedInside = c.read(transportBlockedProvider);
        expect(c.read(playingProvider), isFalse);
        expect(pauses, [true]);
        return 7;
      }, setExportPaused: pauses.add);

      expect(result, 7);
      expect(blockedInside, isTrue);
      expect(pauses, [true, false]);
      expect(c.read(admImportBusyProvider), 0);
      expect(c.read(transportBlockedProvider), isFalse);
    },
  );

  test('releases when the body throws, and rethrows', () async {
    await expectLater(
      holdRendererForImport<void>(
        c,
        () async => throw StateError('probe isolate died'),
        setExportPaused: pauses.add,
      ),
      throwsStateError,
    );

    expect(pauses, [true, false]);
    expect(c.read(admImportBusyProvider), 0);
    expect(c.read(transportBlockedProvider), isFalse);
  });

  test('nested holds unblock transport only at the last exit', () async {
    await holdRendererForImport<void>(c, () async {
      await holdRendererForImport<void>(c, () async {
        expect(c.read(admImportBusyProvider), 2);
      }, setExportPaused: pauses.add);
      expect(c.read(admImportBusyProvider), 1);
      expect(c.read(transportBlockedProvider), isTrue);
    }, setExportPaused: pauses.add);

    expect(pauses, [true, true, false, false]);
    expect(c.read(transportBlockedProvider), isFalse);
  });

  test('the space-bar play is swallowed while the hold lasts', () async {
    await holdRendererForImport<void>(c, () async {
      c.read(playingProvider.notifier).toggleTransport();
      expect(c.read(playingProvider), isFalse);
    }, setExportPaused: pauses.add);

    c.read(playingProvider.notifier).toggleTransport();
    expect(c.read(playingProvider), isTrue);
  });

  test('a missing engine still marks the import busy', () async {
    await holdRendererForImport<void>(c, () async {
      expect(c.read(transportBlockedProvider), isTrue);
    });

    expect(c.read(transportBlockedProvider), isFalse);
  });
}
