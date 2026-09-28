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

// Pins the transport-clock invariant behind the sample-rate desync fix
// (ES-218): the transport's sample rate must follow the engine's actual
// device rate, and rebasing it must preserve the timeline length (and
// playhead position) in *seconds* while the underlying frame clock changes.
//
// These exercise TransportNotifier.rebaseSampleRate directly through a
// ProviderContainer — no engine / FFI — so they guard the rescale math the
// startup-restore pin and the mid-session rate-follow both depend on.

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransportNotifier.rebaseSampleRate', () {
    late ProviderContainer container;
    late TransportNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      notifier = container.read(transportProvider.notifier);
    });

    tearDown(() => container.dispose());

    test('default state clocks at 48 kHz', () {
      expect(container.read(transportProvider).sampleRate, 48000);
    });

    test('rebasing to a higher rate rescales frames but preserves seconds', () {
      // 10 s of audio at 48 kHz, playhead at 4 s.
      notifier.updateDuration(48000 * 10, 48000);
      notifier.seekSeconds(4.0);

      notifier.rebaseSampleRate(96000);

      final s = container.read(transportProvider);
      expect(s.sampleRate, 96000);
      expect(s.durationSamples, 96000 * 10);
      expect(s.samplePosition, 96000 * 4);
      // The whole point: wall-clock length and position are unchanged.
      expect(s.durationSeconds, closeTo(10.0, 1e-9));
      expect(s.seconds, closeTo(4.0, 1e-9));
    });

    test('closes the skip-reconfigure hole: 48k default → engine 96k', () {
      // Reproduces ES-218: the engine adopted 96 kHz but the startup restore's
      // early return left the transport at its 48000 default. The unconditional
      // pin must lift it to the engine rate.
      expect(container.read(transportProvider).sampleRate, 48000);

      notifier.rebaseSampleRate(96000); // == engine.currentSampleRate

      expect(container.read(transportProvider).sampleRate, 96000);
    });

    test('rebasing to the same rate is an identity no-op', () {
      notifier.updateDuration(48000 * 10, 48000);
      notifier.seekSeconds(3.0);
      final before = container.read(transportProvider);

      notifier.rebaseSampleRate(48000);

      final after = container.read(transportProvider);
      expect(after.sampleRate, before.sampleRate);
      expect(after.durationSamples, before.durationSamples);
      expect(after.samplePosition, before.samplePosition);
    });

    test('a non-positive rate is ignored', () {
      notifier.updateDuration(48000 * 10, 48000);
      notifier.rebaseSampleRate(0);
      notifier.rebaseSampleRate(-96000);
      expect(container.read(transportProvider).sampleRate, 48000);
      expect(container.read(transportProvider).durationSamples, 48000 * 10);
    });

    test('rebasing down to a lower rate also preserves seconds', () {
      notifier.updateDuration(96000 * 8, 96000);
      notifier.seekSeconds(2.0);

      notifier.rebaseSampleRate(48000);

      final s = container.read(transportProvider);
      expect(s.sampleRate, 48000);
      expect(s.durationSeconds, closeTo(8.0, 1e-9));
      expect(s.seconds, closeTo(2.0, 1e-9));
    });
  });
}
