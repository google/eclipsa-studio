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

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loop region is set in sample positions of one workspace's
/// timeline, so leaving the workspace clears it (ES-783).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returning to the landing screen clears the loop region', () {
    final container = ProviderContainer(
      overrides: [
        engineLoadProvider.overrideWithValue(
          const EngineLoadResult.failure(
            EngineFailureKind.libraryNotLoaded,
            'test',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(loopingProvider.notifier).set(true);
    container
        .read(loopRegionProvider.notifier)
        .set(const LoopRegion(startSample: 48000, endSample: 96000));
    expect(container.read(loopRegionProvider), isNotNull);

    container.read(workspaceModeProvider.notifier).returnToLanding();

    expect(container.read(workspaceModeProvider), WorkspaceMode.none);
    expect(container.read(loopRegionProvider), isNull);
    expect(
      container.read(loopingProvider),
      isFalse,
      reason: 'the loop toggle is disarmed with its region',
    );
  });
}
