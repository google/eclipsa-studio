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

// TransportNotifier.setSamplePosition clamps engine position reads to
// the timeline and warns about a desync, except for the overshoot of
// playback that reached the end between two ticks (ES-967), and
// PlayingNotifier.stopAtTimelineEnd arms a seek that brings the engine
// counter back to where the playhead stops.

import 'package:eclipsa_studio/logging/log.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 64 s at 48 kHz, the session in ES-967.
  const duration = 48000 * 64;
  // One 60 Hz tick (800 frames) and one 512-frame block.
  const tolerance = 800 + 512;

  late ProviderContainer container;
  late TransportNotifier transport;

  bool warned() => Log.instance.entries.any(
    (e) => e.level == LogLevel.warn && e.category == LogCat.transport,
  );

  setUp(() {
    Log.instance.clear();
    container = ProviderContainer();
    transport = container.read(transportProvider.notifier);
    transport.updateDuration(duration, 48000);
  });

  tearDown(() => container.dispose());

  test('a read past the end within the tolerance clamps silently', () {
    transport.setSamplePosition(duration + 369, pastEndTolerance: tolerance);

    expect(container.read(transportProvider).samplePosition, duration);
    expect(warned(), isFalse);
  });

  test('a read past the end by exactly the tolerance clamps silently', () {
    transport.setSamplePosition(
      duration + tolerance,
      pastEndTolerance: tolerance,
    );

    expect(warned(), isFalse);
  });

  test('a read further past the end than the tolerance warns', () {
    transport.setSamplePosition(
      duration + tolerance + 1,
      pastEndTolerance: tolerance,
    );

    expect(container.read(transportProvider).samplePosition, duration);
    expect(warned(), isTrue);
  });

  test('a read past the end with no tolerance warns', () {
    transport.setSamplePosition(duration + 369);

    expect(warned(), isTrue);
  });

  test('a negative read warns whatever the tolerance', () {
    transport.setSamplePosition(-1, pastEndTolerance: tolerance);

    expect(container.read(transportProvider).samplePosition, 0);
    expect(warned(), isTrue);
  });

  test('a read inside the timeline does not warn', () {
    transport.setSamplePosition(duration ~/ 2);

    expect(container.read(transportProvider).samplePosition, duration ~/ 2);
    expect(warned(), isFalse);
  });

  group('PlayingNotifier.stopAtTimelineEnd', () {
    late PlayingNotifier playing;

    // Play from 10 s and read the engine counter past the end.
    void playToEnd() {
      transport.seekSeconds(10.0);
      playing.start();
      transport.consumeSeek(); // the tick loop forwards it on play
      transport.setSamplePosition(duration + 369, pastEndTolerance: tolerance);
    }

    setUp(() => playing = container.read(playingProvider.notifier));

    test('return-on-stop off: stays at the end and seeks the engine '
        'there', () {
      container.read(returnOnStopProvider.notifier).restore(false);
      playToEnd();

      playing.stopAtTimelineEnd();

      final s = container.read(transportProvider);
      expect(container.read(playingProvider), isFalse);
      expect(s.samplePosition, duration);
      expect(s.playStartPosition, isNull);
      expect(transport.seekPending, isTrue);
    });

    // With return-on-stop, stop() arms the seek to the play-start itself,
    // so this test passes without stopAtTimelineEnd's own seek; the
    // return-on-stop off test above is the one that pins that seek.
    test('return-on-stop on: returns to the play-start and seeks the '
        'engine there', () {
      container.read(returnOnStopProvider.notifier).restore(true);
      playToEnd();

      playing.stopAtTimelineEnd();

      final s = container.read(transportProvider);
      expect(s.samplePosition, 48000 * 10);
      expect(s.playStartPosition, isNull);
      expect(transport.seekPending, isTrue);
    });
  });
}
