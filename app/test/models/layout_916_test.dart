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

// The shared 9.1.6 table (ES-960): the order, its two names per channel,
// the display form and tooltips, the type tooltip, and the engine
// channel order an element declares. The order itself is pinned against
// the key in test/renderer/channel_layouts_test.dart.

import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/models/layout_916.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

AudioElement _element({
  String type = 'Channel',
  String layout = '9.1.6',
  int ambisonicsOrder = 1,
}) => AudioElement(
  id: 1,
  name: 'E',
  type: type,
  layout: layout,
  codec: 'LPCM',
  color: 0,
  ambisonicsOrder: ambisonicsOrder,
);

void main() {
  group('the table', () {
    test('has 16 channels with distinct names', () {
      expect(kAlt916Channels, hasLength(16));
      expect(kAlt916Channels.map((c) => c.iamf).toSet(), hasLength(16));
      expect(kAlt916Channels.map((c) => c.familiar).toSet(), hasLength(16));
    });

    test('the short labels are the familiar names, as in 7.1.4', () {
      expect(alt916Labels, [
        'L', 'R', 'C', 'LFE', 'Lw', 'Rw', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Lts', 'Rts', 'Ltr', 'Rtr',
      ]);
      expect(alt916IamfLabels, [
        'FLc', 'FRc', 'FC', 'LFE', 'FL', 'FR', 'SiL', 'SiR', 'BL', 'BR', //
        'TpFL', 'TpFR', 'TpSiL', 'TpSiR', 'TpBL', 'TpBR',
      ]);
    });

    test('the display form is familiar (IAMF), LFE alone', () {
      expect(alt916DisplayLabels, [
        'L (FLc)', 'R (FRc)', 'C (FC)', 'LFE', 'Lw (FL)', 'Rw (FR)', //
        'Lss (SiL)', 'Rss (SiR)', 'Lrs (BL)', 'Rrs (BR)', 'Ltf (TpFL)',
        'Rtf (TpFR)', 'Lts (TpSiL)', 'Rts (TpSiR)', 'Ltr (TpBL)',
        'Rtr (TpBR)',
      ]);
    });

    test('the IAMF bitstream order is a permutation of it', () {
      expect(kAlt916FromOar.toSet(), List.generate(16, (i) => i).toSet());
      expect(iamfOrder916IamfLabels, [
        'FL', 'FR', 'FC', 'LFE', 'BL', 'BR', 'FLc', 'FRc', 'SiL', 'SiR', //
        'TpFL', 'TpFR', 'TpBL', 'TpBR', 'TpSiL', 'TpSiR',
      ]);
    });

    test('the tooltips are by channel index: the label and its IAMF '
        'bitstream name, none for LFE', () {
      expect(alt916Tooltips[0], 'L (IAMF bitstream FLc)');
      expect(alt916Tooltips[4], 'Lw (IAMF bitstream FL)');
      expect(alt916Tooltips[12], 'Lts (IAMF bitstream TpSiL)');
      expect(alt916Tooltips[3], isNull);
      for (var i = 0; i < 16; i++) {
        final c = kAlt916Channels[i];
        expect(
          alt916Tooltips[i],
          c.iamf == 'LFE' ? isNull : '${c.familiar} (IAMF bitstream ${c.iamf})',
        );
      }
      expect(layout916Tooltips('9.1.6'), same(alt916Tooltips));
      expect(layout916Tooltips('7.1.4'), isNull);
    });

    test('every label no other layout uses has a full name', () {
      expect(k916ChannelFullNames, {
        'Lw': 'Left wide',
        'Rw': 'Right wide',
        'Lts': 'Left top side',
        'Rts': 'Right top side',
      });
    });
  });

  group('the element layout', () {
    test('is the one 9.1.6 layout with 16 channels', () {
      expect(
        LoudspeakerLayout.fromDisplayName('9.1.6'),
        LoudspeakerLayout.k9_1_6,
      );
      expect(LoudspeakerLayout.k9_1_6.channelCount, 16);
      expect(isLayout916('9.1.6'), isTrue);
      expect(isLayout916('7.1.4'), isFalse);
      expect(validConfigsForChannelCount(16).map((c) => c.label), [
        'Scene · 3OA',
        'Channel · 9.1.6',
      ]);
    });

    test('the type tooltip explains the channel order', () {
      final tip = layout916OrderTooltip('9.1.6')!;
      expect(
        tip,
        contains(
          'Channels in this order: L, R, C, LFE, Lw, Rw, Lss, Rss, Lrs, Rrs, '
          'Ltf, Rtf, Lts, Rts, Ltr, Rtr (IAMF names FLc, FRc, FC, LFE, FL, '
          'FR, SiL, SiR, BL, BR, TpFL, TpFR, TpSiL, TpSiR, TpBL, TpBR)',
        ),
      );
      expect(tip, contains('L and R (channels 1 and 2) are at ±30°'));
      expect(tip, contains('Lw and Rw (channels 5 and 6) are the wides'));
      expect(
        tip,
        contains(
          'A WAV in the IAMF bitstream order (FL, FR, FC, LFE, BL, BR, FLc, '
          'FRc, SiL, SiR, TpFL, TpFR, TpBL, TpBR, TpSiL, TpSiR) needs its '
          'channels reordered first.',
        ),
      );
      expect(layout916OrderTooltip('7.1.4'), isNull);
    });
  });

  group('elementChannelOrder', () {
    test('a 9.1.6 channel element is in the alt order', () {
      expect(elementChannelOrder(_element()), kChannelOrder916Alt);
      expect(channelOrderForLayout('9.1.6'), kChannelOrder916Alt);
    });

    test('every other element is fed as it is', () {
      expect(elementChannelOrder(_element(layout: '7.1.4')), kChannelOrderOar);
      expect(
        elementChannelOrder(_element(type: 'Scene', ambisonicsOrder: 3)),
        kChannelOrderOar,
      );
      expect(
        elementChannelOrder(_element(type: 'Object', layout: 'Mono')),
        kChannelOrderOar,
      );
      expect(channelOrderForLayout('7.1.4'), kChannelOrderOar);
    });
  });
}
