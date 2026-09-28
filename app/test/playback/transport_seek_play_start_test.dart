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

// Pins the return-on-stop semantics from ES-277: a mid-playback user
// seek becomes the new play-start, a selected loop region always wins
// on stop, and clearing the loop region disarms the loop toggle only
// when a region actually existed (a region-less toggle is the
// deliberate whole-timeline loop mode).
//
// These exercise TransportNotifier / LoopRegionNotifier / PlayingNotifier
// directly through a ProviderContainer — no engine / FFI.

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;
  late TransportNotifier transport;

  setUp(() {
    container = ProviderContainer();
    transport = container.read(transportProvider.notifier);
    // 10 s of audio at 48 kHz.
    transport.updateDuration(48000 * 10, 48000);
  });

  tearDown(() => container.dispose());

  group('TransportNotifier.seek play-start tracking', () {
    test('seeking while playing moves the play-start to the target', () {
      transport.seekSeconds(2.0);
      container.read(playingProvider.notifier).set(true);
      transport.markPlayStart();

      transport.seek(0.5); // user relocation to 5 s while rolling

      expect(container.read(transportProvider).playStartPosition, 48000 * 5);
    });

    test('seeking while stopped keeps the existing mark', () {
      transport.seekSeconds(2.0);
      transport.markPlayStart();

      transport.seek(0.5);

      expect(container.read(transportProvider).playStartPosition, 48000 * 2);
    });

    test('internal seekSample never moves the mark (loop wrap)', () {
      transport.seekSeconds(2.0);
      container.read(playingProvider.notifier).set(true);
      transport.markPlayStart();

      transport.seekSample(48000 * 7);

      expect(container.read(transportProvider).playStartPosition, 48000 * 2);
    });
  });

  group('TransportNotifier.returnToPlayStart', () {
    test('returns to the play-start mark with no loop region', () {
      transport.seekSeconds(3.0);
      transport.markPlayStart();
      transport.seekSample(48000 * 8);

      transport.returnToPlayStart();

      expect(container.read(transportProvider).samplePosition, 48000 * 3);
    });

    test('a selected loop region overrides the mark', () {
      container
          .read(loopRegionProvider.notifier)
          .set(const LoopRegion(startSample: 48000 * 4, endSample: 48000 * 6));
      transport.seekSeconds(1.0);
      transport.markPlayStart();

      transport.returnToPlayStart();

      expect(container.read(transportProvider).samplePosition, 48000 * 4);
    });

    test('a region start past the duration is clamped', () {
      container
          .read(loopRegionProvider.notifier)
          .set(const LoopRegion(startSample: 48000 * 4, endSample: 48000 * 6));
      transport.updateDuration(48000 * 2, 48000); // duration shrank

      transport.returnToPlayStart();

      expect(container.read(transportProvider).samplePosition, 48000 * 2);
    });
  });

  group('LoopRegionNotifier loop-toggle disarm', () {
    test('clearing an existing region switches looping off', () {
      container
          .read(loopRegionProvider.notifier)
          .set(const LoopRegion(startSample: 0, endSample: 48000));
      container.read(loopingProvider.notifier).set(true);

      container.read(loopRegionProvider.notifier).clear();

      expect(container.read(loopRegionProvider), isNull);
      expect(container.read(loopingProvider), isFalse);
    });

    test('a no-op clear leaves the whole-timeline loop toggle armed', () {
      container.read(loopingProvider.notifier).set(true);

      container.read(loopRegionProvider.notifier).clear();

      expect(container.read(loopingProvider), isTrue);
    });

    test('a degenerate zero-width drag counts as a clear', () {
      container
          .read(loopRegionProvider.notifier)
          .set(const LoopRegion(startSample: 0, endSample: 48000));
      container.read(loopingProvider.notifier).set(true);

      container.read(loopRegionProvider.notifier).setFromFractions(0.3, 0.3);

      expect(container.read(loopRegionProvider), isNull);
      expect(container.read(loopingProvider), isFalse);
    });
  });
}
