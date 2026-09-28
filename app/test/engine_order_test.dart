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

// Unit tests for EngineOrderNotifier.removeCompacted (ES-531): the
// slot→element map must mirror AudioGraph::remove_element's
// swap-with-last compaction, not do an order-preserving removal —
// otherwise every entry after the removed one maps to the wrong engine
// slot and elements read each other's meters and clip latches.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    container.read(workspaceModeProvider.notifier).enterCreator();
  });

  tearDown(() => container.dispose());

  EngineOrderNotifier notifier() =>
      container.read(engineOrderProvider.notifier);
  List<int> order() => container.read(engineOrderProvider);

  test('removing the first entry swaps the last into its slot', () {
    notifier().set([1, 2, 3]);
    notifier().removeCompacted(1);
    // Engine: remove_element(1) moves the last chain (3) into slot 0.
    // The discriminating case — order-preserving removal would give
    // [2, 3] here and cross every meter read after slot 0.
    expect(order(), [3, 2]);
  });

  test('removing the middle of three matches both schemes', () {
    notifier().set([1, 2, 3]);
    notifier().removeCompacted(2);
    // Swap-with-last happens to coincide with order-preserving removal
    // when the removed entry is second-to-last — do not lean on this
    // case alone to pin the semantics.
    expect(order(), [1, 3]);
  });

  test('removing the tail entry just drops it', () {
    notifier().set([1, 2, 3]);
    notifier().removeCompacted(3);
    expect(order(), [1, 2]);
  });

  test('removing the only entry empties the map', () {
    notifier().set([7]);
    notifier().removeCompacted(7);
    expect(order(), isEmpty);
  });

  test('removing an unknown id is a no-op', () {
    notifier().set([1, 2]);
    notifier().removeCompacted(99);
    expect(order(), [1, 2]);
  });
}
