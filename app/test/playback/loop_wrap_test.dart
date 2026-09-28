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

// Pins the loop-wrap decision rule from ES-535: the tick loop's wrap
// to the region start is edge-triggered — it fires only when playback
// crossed the region end this tick with no user seek armed. A
// deliberate seek past the region must stick (the loop stays armed),
// so a playhead merely sitting past the end never wraps.
//
// Pure-function tests over shouldLoopWrap — no containers, no FFI.

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldLoopWrap', () {
    test('crossing the region end with no seek armed wraps', () {
      expect(
        shouldLoopWrap(
          prevPos: 47000,
          pos: 48000,
          effectiveEnd: 48000,
          userSeekArmed: false,
        ),
        isTrue,
      );
    });

    test('sitting level past the end (prev already past) never wraps', () {
      // The playhead was deliberately placed past the region on an
      // earlier tick; merely being past the end is not a crossing.
      expect(
        shouldLoopWrap(
          prevPos: 50000,
          pos: 50800,
          effectiveEnd: 48000,
          userSeekArmed: false,
        ),
        isFalse,
      );
    });

    test('a crossing with a user seek armed is the seek, not a wrap', () {
      // Seek from inside the region to past its end while playing:
      // positions look like a crossing, but the armed seek says the
      // user placed the playhead there.
      expect(
        shouldLoopWrap(
          prevPos: 20000,
          pos: 60000,
          effectiveEnd: 48000,
          userSeekArmed: true,
        ),
        isFalse,
      );
    });

    test('position before the end never wraps, regardless of prev', () {
      expect(
        shouldLoopWrap(
          prevPos: 0,
          pos: 47999,
          effectiveEnd: 48000,
          userSeekArmed: false,
        ),
        isFalse,
      );
      // Backwards seek from past the end back inside (seek already
      // consumed): still no wrap.
      expect(
        shouldLoopWrap(
          prevPos: 60000,
          pos: 30000,
          effectiveEnd: 48000,
          userSeekArmed: false,
        ),
        isFalse,
      );
    });

    test('a zero effective end (empty/unknown duration) never wraps', () {
      expect(
        shouldLoopWrap(
          prevPos: 0,
          pos: 100,
          effectiveEnd: 0,
          userSeekArmed: false,
        ),
        isFalse,
      );
    });

    test('region shrunk behind the playhead does not snap it back', () {
      // The user dragged the region end to before the playhead: prev
      // is already at/past the new end, so no edge — playback keeps
      // going from where it is.
      expect(
        shouldLoopWrap(
          prevPos: 48000,
          pos: 48800,
          effectiveEnd: 24000,
          userSeekArmed: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldWrapAtTimelineEnd', () {
    // Deliberately level-triggered (unlike shouldLoopWrap): a playhead
    // placed past the loop region runs into the timeline end and wraps
    // — the tick loop then targets the region start when a region is
    // selected (region wins over 0). There is nothing past the
    // timeline end to respect a placement at.
    test('at the timeline end wraps', () {
      expect(
        shouldWrapAtTimelineEnd(pos: 480000, durationSamples: 480000),
        isTrue,
      );
    });

    test('past the timeline end wraps (level-triggered)', () {
      expect(
        shouldWrapAtTimelineEnd(pos: 480800, durationSamples: 480000),
        isTrue,
      );
    });

    test('before the timeline end never wraps', () {
      expect(
        shouldWrapAtTimelineEnd(pos: 479999, durationSamples: 480000),
        isFalse,
      );
    });

    test('unknown duration (0, lazy scan pending) never wraps', () {
      expect(shouldWrapAtTimelineEnd(pos: 0, durationSamples: 0), isFalse);
      expect(shouldWrapAtTimelineEnd(pos: 48000, durationSamples: 0), isFalse);
    });
  });
}
