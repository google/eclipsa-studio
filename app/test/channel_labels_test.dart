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

import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart';
import 'package:eclipsa_studio/widgets/routing_labels.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the timeline channel-label orders to OAR's authoritative layout
/// map (`obr/renderer/loudspeaker_layouts.h` in the OAR fork; the OBR
/// virtual-loudspeaker sequences are transcribed in the comments below).
/// The engine registers 16-channel elements as kLayout9_1_6_ch — the
/// primary L60-first ordering, NOT the `_alt` sequential variant
/// (verified via the fork's rid map in `renderer/obr/obr.c`), which is
/// what the 16-channel expectation here encodes.
///
/// Also pins that every label the app can emit has a full name for the
/// gutter tooltips (channelFullName never falls back to echoing for
/// known-layout labels).
void main() {
  List<String> byCount(int n) =>
      List.generate(n, (i) => standardChannelLabel(i, n));

  group('standardChannelLabel follows OAR order', () {
    test('mono / stereo', () {
      expect(byCount(1), ['M']); // OBR: C — "M" kept for DAW familiarity.
      expect(byCount(2), ['L', 'R']); // L30 R30
    });

    test('5.1: L30 R30 C LFE L110 R110', () {
      expect(byCount(6), ['L', 'R', 'C', 'LFE', 'Ls', 'Rs']);
    });

    test('7.1: L30 R30 C LFE L90 R90 L135 R135', () {
      expect(byCount(8), ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs']);
    });

    test('5.1.4: L30 R30 C LFE L110 R110 UL45 UR45 UL135 UR135', () {
      expect(byCount(10), [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf', 'Ltr', 'Rtr', //
      ]);
    });

    test('7.1.4: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45 UL135 UR135', () {
      expect(byCount(12), [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Ltr', 'Rtr',
      ]);
    });

    test('9.1.6 (primary, not _alt): L60 R60 C LFE1 L135 R135 L30 R30 '
        'L90 R90 UL45 UR45 UL135 UR135 UL90 UR90', () {
      expect(byCount(16), [
        'L', 'R', 'C', 'LFE', 'Lrs', 'Rrs', 'Lc', 'Rc', 'Lss', 'Rss', //
        'Ltf', 'Rtf', 'Ltr', 'Rtr', 'Ltss', 'Rtss',
      ]);
    });

    test('7.1.5.4: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45 T '
        'UL135 UR135 BL45 BR45 BL135 BR135', () {
      expect(byCount(17), [
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Tc', 'Ltr', 'Rtr', 'Lbf', 'Rbf', 'Lbr', 'Rbr',
      ]);
    });

    test('unmapped counts fall back to Ch N', () {
      expect(standardChannelLabel(0, 24), 'Ch 1');
      expect(standardChannelLabel(23, 24), 'Ch 24');
    });
  });

  group('iamfChannelLabels count-ambiguous overrides follow OAR order', () {
    test('3.1.2: L30 R30 C LFE UL45 UR45', () {
      expect(iamfChannelLabels(channelCount: 6, layoutHint: '3.1.2'), [
        'L', 'R', 'C', 'LFE', 'Ltf', 'Rtf', //
      ]);
    });

    test('5.1.2: L30 R30 C LFE L110 R110 UL30 UR30', () {
      expect(iamfChannelLabels(channelCount: 8, layoutHint: '5.1.2'), [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf', //
      ]);
    });

    test('7.1.2: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45', () {
      expect(iamfChannelLabels(channelCount: 10, layoutHint: '7.1.2'), [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lrs', 'Rrs', 'Ltf', 'Rtf', //
      ]);
    });

    test('no hint falls through to the count-based default', () {
      expect(iamfChannelLabels(channelCount: 6), byCount(6));
    });

    test('7.1.5.4 keeps its own vocabulary at 16 or 17 lanes', () {
      // The engine registers 7.1.5.4 elements as a 16-channel OAR
      // element, so outCh can be 16 against a 17-channel file; the
      // labels must stay 7.1.5.4 speakers (not the 9.1.6 vocabulary
      // the bare 16-channel fallback would produce), truncated when
      // only 16 lanes render.
      expect(
        iamfChannelLabels(channelCount: 17, layoutHint: '7.1.5.4'),
        byCount(17),
      );
      expect(
        iamfChannelLabels(channelCount: 16, layoutHint: '7.1.5.4'),
        byCount(17).sublist(0, 16),
      );
    });
  });

  group('channelFullName', () {
    test('covers every label any supported layout emits', () {
      final all = <String>{
        ...byCount(1), ...byCount(2), ...byCount(6), ...byCount(8),
        ...byCount(10), ...byCount(12), ...byCount(16), ...byCount(17),
        ...iamfChannelLabels(channelCount: 6, layoutHint: '3.1.2'),
        ...iamfChannelLabels(channelCount: 8, layoutHint: '5.1.2'),
        ...iamfChannelLabels(channelCount: 10, layoutHint: '7.1.2'),
        ...iamfChannelLabels(channelCount: 16, layoutHint: '7.1.5.4'),
        ...ambisonicsLabels(25),
        'Ch 1', //
      };
      for (final label in all) {
        expect(
          channelFullName(label),
          isNot(label),
          reason: '"$label" must have a distinct full name',
        );
      }
    });

    test('spot checks', () {
      expect(channelFullName('LFE'), 'Low-frequency effects');
      expect(channelFullName('Ltf'), 'Left top front');
      expect(channelFullName('ACN 12'), 'Ambisonics channel 12 (ACN order)');
      expect(channelFullName('Ch 3'), 'Channel 3');
      expect(channelFullName('???'), '???'); // unknown echoes back
    });
  });
}
