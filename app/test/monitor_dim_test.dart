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

// Pins the monitor DIM state (ES-629): off at start, toggles, and stays
// as set across the transport and mix changes that must not clear it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/state.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(null)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('starts undimmed and toggles', () {
    final c = container();
    expect(c.read(monitorDimProvider), isFalse);
    c.read(monitorDimProvider.notifier).toggle();
    expect(c.read(monitorDimProvider), isTrue);
    c.read(monitorDimProvider.notifier).set(false);
    expect(c.read(monitorDimProvider), isFalse);
  });

  test('stays engaged across stop, seek and mix switches', () {
    final c = container();
    c.read(monitorDimProvider.notifier).set(true);
    c.read(playingProvider.notifier).set(true);
    c.read(playingProvider.notifier).set(false);
    c.read(transportProvider.notifier).seek(1.5);
    c.read(loopingProvider.notifier).toggle();
    expect(c.read(monitorDimProvider), isTrue);
  });
}
