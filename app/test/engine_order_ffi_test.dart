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

// FFI-backed integration test for the slot→element mapping (ES-531):
// drives the REAL engine dylib through the app's element add / delete /
// WAV-swap paths and cross-checks engineOrderProvider against
// eclipsa_studio_element_ids — the engine-authoritative slot order — after
// every mutation. This automates the manual smoke test for the crossed
// meters bug: engine compaction is swap-with-last, and any Dart-side
// bookkeeping that disagrees shows up here as a list mismatch.
//
// Skips when the engine dylib has not been built (CI builds it before
// `flutter test`; run `./build.sh engine` locally first).

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/meters/meter_provider.dart'
    show eclipsaStudioEngineProvider;
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';

import 'support/engine_dylib.dart';

void main() {
  // Provider teardown reaches platform channels (video pop-out close);
  // a binding must exist for those to no-op instead of asserting.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'engineOrder mirrors engine slots through delete and WAV swap',
    () async {
      final dylib = engineDylibOrSkip();
      if (dylib == null) return;
      useEngineDylib(dylib);

      final tmp = Directory.systemTemp.createTempSync(
        'eclipsa_studio_order_ffi',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      String wav(String name, {int channels = 1}) {
        final f = File('${tmp.path}/$name.wav')
          ..writeAsBytesSync(wavBytes(channels: channels));
        return f.path;
      }

      final engine = EclipsaStudioEngine();
      expect(engine.init(), 0, reason: 'engine init failed');
      addTearDown(engine.shutdown);

      final container = ProviderContainer(
        overrides: [eclipsaStudioEngineProvider.overrideWithValue(engine)],
      );
      addTearDown(container.dispose);
      container.read(workspaceModeProvider.notifier).enterCreator();
      // Base caps at 2 elements; the scenario needs 3.
      container
          .read(iamfProfileProvider.notifier)
          .set(IamfProfile.baseEnhanced);

      List<int> order() => container.read(engineOrderProvider);
      void expectInSync(String when) => expect(
        engine.elementIds(),
        order(),
        reason: 'engine slots and engineOrder diverged $when',
      );

      // Add three elements through the real add path.
      expect(await addNewElementFromWav(container, wav('a')), isNull);
      expect(await addNewElementFromWav(container, wav('b')), isNull);
      expect(await addNewElementFromWav(container, wav('c')), isNull);
      expect(order(), hasLength(3));
      expectInSync('after adding three elements');
      final ids = order();

      // Delete the FIRST element: the engine compacts swap-with-last, so
      // the LAST chain lands in slot 0 — [c, b], NOT the [b, c] an
      // order-preserving removal would produce. This is the discriminating
      // case (deleting the middle of three yields the same list under
      // both schemes and would not catch the crossed-meters bug).
      deleteElementById(container, ids[0]);
      expectInSync('after deleting the first element');
      expect(order(), [ids[2], ids[1]]);

      // WAV-swap the element now in slot 0, same channel count: engine
      // remove (compacts) + re-add under the same id (appends).
      expect(await assignWavToElement(container, ids[2], wav('a2')), isNull);
      expectInSync('after a same-channel-count WAV swap');
      expect(order(), [ids[1], ids[2]]);

      // WAV-swap the slot-0 element with a DIFFERENT channel count:
      // delete (compacts — slot 1's element moves to slot 0) + fresh
      // element appended under a new id.
      expect(
        await assignWavToElement(container, ids[1], wav('c2', channels: 2)),
        isNull,
      );
      expectInSync('after a different-channel-count WAV swap');
      expect(order(), hasLength(2));
      expect(order().first, ids[2]);

      // Drain to empty — the tail-removal branch on both sides.
      for (final id in List<int>.from(order())) {
        deleteElementById(container, id);
        expectInSync('while draining element $id');
      }
      expect(order(), isEmpty);
    },
  );
}
