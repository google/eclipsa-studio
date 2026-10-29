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

// Pins the return-on-stop semantics from ES-277 and ES-564: a user seek
// while playing or paused becomes the new play-start, a pause keeps
// the play-start and a stop clears it, a selected loop region always
// wins on stop, and clearing the loop region disarms the loop toggle only
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

    test('seeking while paused moves the play-start to the target', () {
      transport.seekSeconds(2.0);
      transport.markPlayStart(); // a play pass, now paused

      transport.seek(0.5);

      expect(container.read(transportProvider).playStartPosition, 48000 * 5);
    });

    test('seeking while stopped sets no mark', () {
      transport.seek(0.5);

      expect(container.read(transportProvider).playStartPosition, isNull);
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

  group('pause, resume and stop (ES-564)', () {
    late PlayingNotifier playing;

    // Play from 2 s, pause at 6 s.
    void playThenPause() {
      transport.seekSeconds(2.0);
      playing.start();
      transport.setSamplePosition(48000 * 6);
      playing.pause();
    }

    // Resume, play to the end of the timeline and stop there; returns
    // where the playhead lands.
    int resumeToEndAndStop() {
      playing.start();
      transport.setSamplePosition(48000 * 10);
      playing.stop();
      return container.read(transportProvider).samplePosition;
    }

    setUp(() => playing = container.read(playingProvider.notifier));

    test('resuming after a pause keeps the play-start', () {
      playThenPause();

      playing.start();

      expect(container.read(playingProvider), isTrue);
      expect(container.read(transportProvider).playStartPosition, 48000 * 2);
    });

    test('a Space-bar resume keeps the play-start too', () {
      playThenPause();

      playing.toggleTransport();

      expect(container.read(transportProvider).playStartPosition, 48000 * 2);
    });

    test('a stop after a resume returns to where playback started', () {
      playThenPause();

      expect(resumeToEndAndStop(), 48000 * 2);
      expect(container.read(playingProvider), isFalse);
      expect(container.read(transportProvider).playStartPosition, isNull);
    });

    test('a hold that stops playback keeps the play-start', () {
      transport.seekSeconds(2.0);
      playing.start();
      transport.setSamplePosition(48000 * 6);
      playing.set(false); // export, Loudness Report or ADM import

      expect(resumeToEndAndStop(), 48000 * 2);
    });

    test('Return to start while playing makes 0 the play-start', () {
      // The whole-timeline loop wrap calls resetPosition the same way.
      transport.seekSeconds(3.0);
      playing.start();
      transport.setSamplePosition(48000 * 5);
      transport.resetPosition();
      transport.setSamplePosition(48000 * 4);
      playing.pause();

      expect(resumeToEndAndStop(), 0);
    });

    test('Return to start while paused clears the play-start', () {
      playThenPause();

      transport.resetPosition();

      expect(container.read(transportProvider).playStartPosition, isNull);
      playing.start();
      expect(container.read(transportProvider).playStartPosition, 0);
    });

    test('a stop with return-on-stop off stays put and drops the mark', () {
      container.read(returnOnStopProvider.notifier).restore(false);
      playThenPause();
      playing.start();
      transport.setSamplePosition(48000 * 8);

      playing.stop();
      playing.start();

      final s = container.read(transportProvider);
      expect(s.samplePosition, 48000 * 8);
      expect(s.playStartPosition, 48000 * 8);
    });

    test('a mark past a shortened timeline returns to its end', () {
      playThenPause();
      transport.updateDuration(48000 * 1, 48000);

      playing.stop();

      expect(container.read(transportProvider).samplePosition, 48000);
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
