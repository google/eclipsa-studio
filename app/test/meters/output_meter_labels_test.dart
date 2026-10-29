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

// Pins the output-bus label orders fixed in ES-552 to the engine's
// actual output channel order — OAR's layout map, copied verbatim
// from OAR `layout.c` into `engine/adm_import/scene/layouts.cc` (the
// speaker sequences are transcribed in the comments below). Two
// sources are pinned:
//
//  * `OarLayout.speakerLabels` — feeds the Monitoring output meter,
//    the routing matrix rows, and the Settings target summaries. All
//    of these are positional against the engine's output buffer, so a
//    wrong order mislabels real channels (before ES-960 the hand-kept
//    table had 9.1.6 wides-first while OAR rendered L60/R60 first with
//    the rears at 4–5; 9.1.6 is now reordered by the engine).
//  * `channelLabels` — the MultichannelMeter default when a call site
//    shows labels and passes none. No app call site does: the output
//    meter passes `OarLayout.meterLabels`, and the Mix view's strip
//    meters draw no labels. The old table was film order
//    (`L C R Ls Rs LFE`), which mislabeled 5 of 6 bars on a 5.1
//    monitoring bus.

import 'package:eclipsa_studio/meters/multichannel_meter_painter.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OarLayout.speakerLabels follows engine output order', () {
    test('length always equals the layout channel count', () {
      for (final layout in OarLayout.values) {
        expect(
          layout.speakerLabels.length,
          layout.channels,
          reason: '${layout.label} labels must cover every output channel',
        );
      }
    });

    test('stereo / binaural: L30 R30', () {
      expect(OarLayout.stereo.speakerLabels, ['L', 'R']);
      expect(OarLayout.binaural.speakerLabels, ['L', 'R']);
    });

    test('5.1: L30 R30 C LFE L110 R110', () {
      expect(OarLayout.layout51.speakerLabels, [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', //
      ]);
    });

    test('5.1.2 (count-ambiguous vs 7.1): heights last, not rears', () {
      expect(OarLayout.layout512.speakerLabels, [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf', //
      ]);
    });

    test('5.1.4: M+030 M-030 C LFE M+110 M-110 U+030 U-030 U+110 U-110', () {
      expect(OarLayout.layout514.speakerLabels, [
        'L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf', 'Ltr', 'Rtr', //
      ]);
    });

    test('7.1: L30 R30 C LFE L90 R90 L135 R135 (side pair Lss/Rss)', () {
      expect(OarLayout.layout71.speakerLabels, [
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', //
      ]);
    });

    test('7.1.2 (count-ambiguous vs 5.1.4): one height pair', () {
      expect(OarLayout.layout712.speakerLabels, [
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', 'Ltf', 'Rtf', //
      ]);
    });

    test('7.1.4: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45 UL135 UR135', () {
      expect(OarLayout.layout714.speakerLabels, [
        'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Ltr', 'Rtr',
      ]);
    });

    test('9.1.6 (alt order, ES-960): L30 R30 C LFE L60 R60 L90 R90 L135 '
        'R135 UL45 UR45 UL90 UR90 UL135 UR135', () {
      // The Settings summary shows the familiar name with the IAMF
      // name; the output meter and the routing matrix cells show the
      // familiar name alone, with the display form and the full name in
      // the cell tooltips, by channel index.
      expect(OarLayout.layout916.speakerLabels, [
        'L (FLc)', 'R (FRc)', 'C (FC)', 'LFE', 'Lw (FL)', 'Rw (FR)', //
        'Lss (SiL)', 'Rss (SiR)', 'Lrs (BL)', 'Rrs (BR)', 'Ltf (TpFL)',
        'Rtf (TpFR)', 'Lts (TpSiL)', 'Rts (TpSiR)', 'Ltr (TpBL)',
        'Rtr (TpBR)',
      ]);
      expect(OarLayout.layout916.meterLabels, [
        'L', 'R', 'C', 'LFE', 'Lw', 'Rw', 'Lss', 'Rss', 'Lrs', 'Rrs', //
        'Ltf', 'Rtf', 'Lts', 'Rts', 'Ltr', 'Rtr',
      ]);
      final tips = OarLayout.layout916.channelTooltips!;
      expect(tips[0], 'L (IAMF bitstream FLc)');
      expect(tips[3], isNull);
      expect(tips[12], 'Lts (IAMF bitstream TpSiL)');
      expect(OarLayout.layout714.channelTooltips, isNull);
    });

    test('the 9.1.6 meter labels fit the routing matrix cell', () {
      // The routing matrix draws each label in a 28 px cell at
      // T.fontMeter; JetBrains Mono advances 0.6 em, 9.2 px at Large.
      for (final label in OarLayout.layout916.meterLabels) {
        expect(label.length * 0.6 * 9.2, lessThanOrEqualTo(28), reason: label);
      }
    });

    test('every other layout meters with its speaker labels', () {
      for (final layout in OarLayout.values) {
        if (layout == OarLayout.layout916) continue;
        expect(layout.meterLabels, same(layout.speakerLabels));
      }
    });
  });

  group('MultichannelMeter default labels (channelLabels)', () {
    test('5.1 default is engine order, not film order', () {
      expect(channelLabels(6), ['L', 'R', 'C', 'LFE', 'Ls', 'Rs']);
    });

    test('mono / stereo', () {
      expect(channelLabels(1), ['M']);
      expect(channelLabels(2), ['L', 'R']);
    });

    test('unmapped counts fall back to Ch N', () {
      expect(channelLabels(4), ['Ch 1', 'Ch 2', 'Ch 3', 'Ch 4']);
    });
  });

  group('meterLabelsRotate', () {
    test('labels wider than the bar pitch rotate', () {
      // 9.1.6's four-character labels (~20 px) over 16 narrow bars
      // (~13.5 px pitch) collided when drawn horizontally.
      expect(meterLabelsRotate(maxLabelWidth: 20, barPitch: 13.5), isTrue);
    });

    test('a fit within 1 px of the pitch rotates too (touching is '
        'not fitting)', () {
      // 5.1's `LFE` at ~15 px under 14 px bars + 2 px gap fits with
      // slack and stays horizontal; a label inside the 1 px slack
      // band would touch its neighbors, so it rotates.
      expect(meterLabelsRotate(maxLabelWidth: 15, barPitch: 16), isFalse);
      expect(meterLabelsRotate(maxLabelWidth: 15.5, barPitch: 16), isTrue);
    });
  });

  group('meterLabelLayout (ES-795)', () {
    // JetBrains Mono (the meter label face) advances 0.6 em per glyph
    // with a 1.32 em line: T.fontMeter is 6.8 / 8 / 9.2 px at Small /
    // Medium / Large. At 9.1.6 the Renderer view's output meter puts
    // 16 bars on a 9.8 px pitch.
    const pitch916 = 9.8;
    List<double> widths(List<String> labels, double px) => [
      for (final l in labels) l.length * 0.6 * px,
    ];
    // The output meter's 9.1.6 labels are the familiar names alone
    // (ES-960), one to four characters (Lts is 19.2 px at Medium).
    final labels916 = OarLayout.layout916.meterLabels;

    test('9.1.6 at Small: one rotated row (a 9.0 px line fits)', () {
      expect(
        meterLabelLayout(
          widths: widths(labels916, 6.8),
          lineHeight: 1.32 * 6.8,
          barPitch: pitch916,
        ),
        (mode: MeterLabelMode.rotated, rows: 1),
      );
    });

    test('9.1.6 at Medium: two horizontal rows', () {
      expect(
        meterLabelLayout(
          widths: widths(labels916, 8),
          lineHeight: 1.32 * 8,
          barPitch: pitch916,
        ),
        (mode: MeterLabelMode.horizontal, rows: 2),
      );
    });

    test('9.1.6 with the display form takes two rotated rows at Medium '
        'and Large', () {
      for (final px in const [6.8, 8.0, 9.2]) {
        final layout = meterLabelLayout(
          widths: widths(OarLayout.layout916.speakerLabels, px),
          lineHeight: 1.32 * px,
          barPitch: pitch916,
        );
        expect(layout.mode, MeterLabelMode.rotated, reason: '$px px');
        if (px > 6.8) expect(layout.rows, 2, reason: '$px px');
      }
    });

    test('9.1.6 at Large: two horizontal rows (three-letter labels, '
        '16.6 px, share a 19.6 px double pitch)', () {
      expect(
        meterLabelLayout(
          widths: widths(labels916, 9.2),
          lineHeight: 1.32 * 9.2,
          barPitch: pitch916,
        ),
        (mode: MeterLabelMode.horizontal, rows: 2),
      );
    });

    test('labels that fit one row stay in one horizontal row', () {
      expect(
        meterLabelLayout(
          widths: widths(OarLayout.layout51.speakerLabels, 8),
          lineHeight: 10.56,
          barPitch: 16,
        ),
        (mode: MeterLabelMode.horizontal, rows: 1),
      );
    });

    test('a pitch of one line or more rotates in one row', () {
      expect(
        meterLabelLayout(
          widths: widths(labels916, 8),
          lineHeight: 10.56,
          barPitch: 13.5,
        ),
        (mode: MeterLabelMode.rotated, rows: 1),
      );
    });

    test('only same-row neighbours are checked when staggering', () {
      // 20 px labels side by side (bars 0 and 1) sit in different rows;
      // the same-row pairs (0, 2) and (1, 3) are 10 px + 20 px.
      expect(
        meterLabelLayout(widths: [20, 20, 10, 10], lineHeight: 12, barPitch: 9),
        (mode: MeterLabelMode.horizontal, rows: 2),
      );
      // Two 20 px labels in one row need 21 px, more than 2 x 9 px.
      expect(
        meterLabelLayout(widths: [20, 10, 20, 10], lineHeight: 12, barPitch: 9),
        (mode: MeterLabelMode.rotated, rows: 2),
      );
    });

    test('below half a line of pitch there are no labels', () {
      expect(
        meterLabelLayout(widths: [20, 20, 20], lineHeight: 12, barPitch: 5),
        (mode: MeterLabelMode.none, rows: 1),
      );
    });

    test('no labels for no bars', () {
      expect(meterLabelLayout(widths: const [], lineHeight: 10, barPitch: 10), (
        mode: MeterLabelMode.none,
        rows: 1,
      ));
    });
  });

  group('3D scene labels agree with the meter vocabulary', () {
    test('SpeakerLayout uses the same name for the same channel', () {
      // The Renderer's viz HUD labels per-channel bars positionally
      // from SpeakerLayout, and the 3D scene draws these names at the
      // speakers — one physical channel must wear one name across the
      // meters, routing matrix, and scene. (SpeakerLayout's mono and
      // 3.1.2 have no OarLayout counterpart and are not monitoring
      // targets; binaural maps to the stereo geometry by design.)
      // 9.1.6's speakerLabels add the IAMF name in brackets; the scene
      // and the meter carry the familiar name alone (meterLabels).
      for (final layout in OarLayout.values) {
        final scene = SpeakerLayout.byName(layout.label);
        expect(scene, isNotNull, reason: 'no scene layout: ${layout.label}');
        expect(
          [for (final s in scene!.speakers) s.label],
          layout.meterLabels,
          reason: '${layout.label} scene labels must match meterLabels',
        );
      }
    });
  });
}
