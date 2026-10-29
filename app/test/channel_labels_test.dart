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
/// A 16-channel element is 9.1.6 in the app's order, OBR's alt order
/// (`kLayout9_1_6_ch_alt`, L30 first), with the familiar names; the
/// engine permutes it into OAR's order at the feed (ES-960). The 7.1
/// family's side pair is Lss/Rss, as in IAMF; the 5.1 family's surround
/// pair is Ls/Rs.
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
      expect(byCount(8), ['L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs']);
    });

    test('5.1.4: L30 R30 C LFE L110 R110 UL45 UR45 UL135 UR135', () {
      expect(byCount(10), [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf', 'Ltr', 'Rtr', //
      ]);
    });

    test('7.1.4: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45 UL135 UR135', () {
      expect(byCount(12), [
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Ltr', 'Rtr',
      ]);
    });

    test('9.1.6 (alt order): L30 R30 C LFE L60 R60 L90 R90 L135 R135 '
        'UL45 UR45 UL90 UR90 UL135 UR135', () {
      expect(byCount(16), [
        'L', 'R', 'C', 'LFE', 'Lw', 'Rw', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Lts', 'Rts', 'Ltr', 'Rtr',
      ]);
      expect(iamfChannelLabels(channelCount: 16, layoutHint: '9.1.6'), [
        'L', 'R', 'C', 'LFE', 'Lw', 'Rw', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Lts', 'Rts', 'Ltr', 'Rtr',
      ]);
    });

    test('7.1.5.4: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45 T '
        'UL135 UR135 BL45 BR45 BL135 BR135', () {
      expect(byCount(17), [
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Tc', 'Ltr', 'Rtr', 'Lbf', 'Rbf', 'Lbr', 'Rbr',
      ]);
    });

    test('10.2.9.3 (OAR order): L60 R60 C LFE1 L135 R135 L30 R30 M180 LFE2 '
        'L90 R90 UL45 UR45 UL0 T UL135 UR135 UL90 UR90 UL180 B0 B45 B-45', () {
      expect(byCount(24), [
        'Lw', 'Rw', 'C', 'LFE', 'Lrs', 'Rrs', 'L', 'R', 'Cs', 'LFE2', //
        'Lss', 'Rss', 'Ltf', 'Rtf', 'Ctf', 'Tc', 'Ltr', 'Rtr', 'Lts', 'Rts',
        'Ctr', 'Cbf', 'Lbf', 'Rbf',
      ]);
    });

    test('unmapped counts fall back to Ch N', () {
      expect(standardChannelLabel(0, 20), 'Ch 1');
      expect(standardChannelLabel(19, 20), 'Ch 20');
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
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', 'Ltf', 'Rtf', //
      ]);
    });

    test('no hint falls through to the count-based default', () {
      expect(iamfChannelLabels(channelCount: 6), byCount(6));
    });

    test('7.1.5.4 and 10.2.9.3 are unambiguous by count', () {
      expect(
        iamfChannelLabels(channelCount: 17, layoutHint: '7.1.5.4'),
        byCount(17),
      );
      expect(
        iamfChannelLabels(channelCount: 24, layoutHint: '10.2.9.3'),
        byCount(24),
      );
    });
  });

  group('channelFullName', () {
    test('covers every label any supported layout emits', () {
      final all = <String>{
        ...byCount(1), ...byCount(2), ...byCount(6), ...byCount(8),
        ...byCount(10), ...byCount(12), ...byCount(16), ...byCount(17),
        ...byCount(24),
        ...iamfChannelLabels(channelCount: 6, layoutHint: '3.1.2'),
        ...iamfChannelLabels(channelCount: 8, layoutHint: '5.1.2'),
        ...iamfChannelLabels(channelCount: 10, layoutHint: '7.1.2'),
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

    test('lane tooltips are by index within a 9.1.6 layout (ES-960)', () {
      final alt = channelLaneTooltips('9.1.6', byCount(16));
      expect(alt[0], 'L (IAMF bitstream FLc)');
      expect(alt[4], 'Lw (IAMF bitstream FL)');
      expect(alt[12], 'Lts (IAMF bitstream TpSiL)');
      // LFE has one name, so its lane falls back to the full name.
      expect(alt[3], 'Low-frequency effects');
      // A 7.1.4 lane labelled L is Left: the familiar names are also
      // other layouts' labels, so nothing is looked up by label text.
      final l714 = channelLaneTooltips('7.1.4', byCount(12));
      expect(l714[0], 'Left');
      expect(l714[4], 'Left side surround');
      expect(l714[8], 'Left top front');
      expect(channelLaneTooltips('3OA', ['ACN 3']), [
        'Ambisonics channel 3 (ACN order)',
      ]);
      // Lanes past the layout (a 20-channel WAV declared 9.1.6 without
      // routing) keep the count-based full name.
      final wide = channelLaneTooltips('9.1.6', [...byCount(16), 'Ch 17']);
      expect(wide[16], 'Channel 17');
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
