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

// Hermetic tests for MixesNotifier.reorderMix (ES-181).
//
// Contract under test: the moved mix's FINAL index equals newIndex in
// both directions — it takes the drop target's original position — so
// dropping onto an adjacent neighbor swaps them. (Distinct from
// ElementsNotifier.reorder, whose newIndex is a ReorderableListView
// gap index.)

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Mix _mix(int id) =>
    Mix(id: id, name: 'Mix $id', language: 'en', subMixes: const [SubMix()]);

void main() {
  late ProviderContainer container;
  late MixesNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    // Mix mutators are Creator-only (assertCreatorMode throws in
    // debug otherwise).
    container.read(workspaceModeProvider.notifier).enterCreator();
    notifier = container.read(mixesNotifierProvider.notifier);
    notifier.set([_mix(1), _mix(2), _mix(3)]);
  });

  tearDown(() => container.dispose());

  List<int> ids() =>
      container.read(mixesNotifierProvider).map((m) => m.id).toList();

  test('forward move lands at the target\'s original index', () {
    notifier.reorderMix(0, 2);
    expect(ids(), [2, 3, 1]);
  });

  test('backward move lands at the target\'s original index', () {
    notifier.reorderMix(2, 0);
    expect(ids(), [3, 1, 2]);
  });

  test('adjacent forward drop swaps the pair', () {
    notifier.reorderMix(0, 1);
    expect(ids(), [2, 1, 3]);
  });

  test('adjacent backward drop swaps the pair', () {
    notifier.reorderMix(1, 0);
    expect(ids(), [2, 1, 3]);
  });

  test('same index is a no-op', () {
    notifier.reorderMix(1, 1);
    expect(ids(), [1, 2, 3]);
  });

  test('out-of-range oldIndex is a no-op', () {
    notifier.reorderMix(-1, 1);
    notifier.reorderMix(3, 1);
    expect(ids(), [1, 2, 3]);
  });

  test('newIndex is clamped to the list end', () {
    notifier.reorderMix(0, 99);
    expect(ids(), [2, 3, 1]);
  });
}
