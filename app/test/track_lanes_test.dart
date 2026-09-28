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

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart';
import 'package:eclipsa_studio/waveform/waveform_style.dart';
import 'package:eclipsa_studio/widgets/track_lanes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  test('the flat block, lanes and spacing are what the view drew', () {
    // Before track_lanes.dart the block was the element colour at 4%
    // in a 0.5 px border at 25% at radiusSm, lanes 2 px apart with no
    // fill of their own, and the waveform style untouched. Classic
    // keeps that block after the remake.
    for (final mode in [AppThemeMode.classic]) {
      T.setMode(mode);
      const c = Color(0xFF34D399);
      final d = trackBlockDecoration(c);
      expect(d.color, c.withValues(alpha: 0.04), reason: mode.name);
      expect(d.borderRadius, BorderRadius.circular(T.radiusSm));
      expect(
        d.border,
        Border.all(color: c.withValues(alpha: 0.25), width: 0.5),
      );
      expect(trackLaneFill(), isNull, reason: mode.name);
      expect(trackLaneSpacing(), 2, reason: mode.name);
      expect(trackBlockBorderWidth(), 0.5, reason: mode.name);
      expect(MultiChannelWaveform.spacing, 2, reason: mode.name);
      const base = WaveformStyle();
      expect(identical(trackLaneStyle(base), base), isTrue);
    }
  });

  test('High Contrast outlines the block in the element colour', () {
    // The same block at full-strength colour, borderWidth (2) wide,
    // around a 10% fill; lanes unfilled as in A and B.
    T.setMode(AppThemeMode.highContrast);
    const c = Color(0xFF34D399);
    final d = trackBlockDecoration(c);
    expect(d.color, c.withValues(alpha: 0.10));
    expect(d.border, Border.all(color: c, width: T.borderWidth));
    expect(trackBlockBorderWidth(), T.borderWidth);
    expect(trackLaneFill(), isNull);
    expect(trackLaneSpacing(), 2);
  });

  test('the concepts fill the lanes and keep the 2 px spacing', () {
    // The concepts divide the lanes with a 1 px line; the spacing is
    // 2 in every theme, since a component's size does not vary by
    // theme, only how it is drawn and coloured.
    T.setMode(AppThemeMode.dark);
    expect(trackBlockBorderWidth(), 1);
    expect(trackBlockDecoration(Colors.red).color, T.border);
    expect(trackLaneFill(), T.bgSurface);
    expect(trackLaneSpacing(), 2);
    expect(trackLaneStyle(const WaveformStyle()).borderRadius, 0);

    T.setMode(AppThemeMode.light);
    expect(trackBlockDecoration(Colors.red).color, T.borderLight);
    expect(trackLaneFill(), T.bgControls);
    expect(trackLaneSpacing(), 2);
  });

  testWidgets('a label cell and chip follow a theme switch in place', (
    tester,
  ) async {
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 34,
                    child: ChannelLabelCell(
                      label: 'LFE',
                      height: 20,
                      fontSize: 11,
                      show: true,
                    ),
                  ),
                  SizedBox(
                    width: 300,
                    child: TrackInfoChip(
                      text: 'a.wav',
                      color: const Color(0xFF34D399),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    Color labelColor() => tester.widget<Text>(find.text('LFE')).style!.color!;
    Color chipColor() => tester.widget<Text>(find.text('a.wav')).style!.color!;

    expect(labelColor(), T.textSecondary);
    expect(chipColor(), const Color(0xFF34D399).withValues(alpha: 0.7));
    expect(tester.getSize(find.byType(ChannelLabelCell)).height, 20);

    T.setMode(AppThemeMode.dark);
    rebuild(() {});
    await tester.pump();
    expect(labelColor(), T.white);
    expect(chipColor(), T.videoInk);

    T.setMode(AppThemeMode.light);
    rebuild(() {});
    await tester.pump();
    expect(labelColor(), T.chromeTabOn);
    expect(chipColor(), T.chromeTabOn);
    // The raised cell keeps the lane height with its chip 2 px in.
    expect(tester.getSize(find.byType(ChannelLabelCell)).height, 20);
    expect(tester.getSize(find.byType(DecoratedBox).last).height, 16);
  });

  group('the track panel ground', () {
    // The sidebar column left of the lanes. The Light theme draws each
    // track's controls as its own bgSurface card; the flat and beveled
    // themes
    // draw the list of rows the app has always drawn.
    test('every theme but E keeps the bottom line and no card', () {
      // A hairline in A and D; High Contrast's line is its borderWidth.
      for (final mode in [
        AppThemeMode.classic,
        AppThemeMode.highContrast,
        AppThemeMode.dark,
      ]) {
        T.setMode(mode);
        final deco = trackPanelDecoration();
        final width = mode == AppThemeMode.highContrast ? T.borderWidth : 0.5;
        expect(deco.color, isNull, reason: '${mode.name} fill');
        expect(deco.borderRadius, isNull, reason: '${mode.name} radius');
        expect(
          deco.border,
          isA<Border>().having((b) => b.bottom.width, 'width', width),
        );
        expect(trackPanelBorderHeight(), width, reason: mode.name);
        expect((deco.border! as Border).bottom.color, T.border);
        expect(
          trackPanelMargin(),
          EdgeInsets.zero,
          reason: '${mode.name} margin',
        );
        expect(trackPanelStripColor(), T.trackPanelBg, reason: mode.name);
      }
    });

    // The strip's colour is a token, not bgSurface. Classic and High Contrast
    // carry the value the strip had before the token existed; the Dark
    // theme puts it at #181716, a warm grey above the page ground, which is
    // the reason the token exists.
    test('the strip colour is trackPanelBg, and D no longer follows', () {
      for (final mode in [AppThemeMode.classic, AppThemeMode.highContrast]) {
        T.setMode(mode);
        expect(T.trackPanelBg, T.bgSurface, reason: mode.name);
      }
      T.setMode(AppThemeMode.dark);
      expect(T.trackPanelBg, const Color(0xFF181716));
      expect(T.trackPanelBg, isNot(T.bgSurface));
    });

    // The Light theme draws no rim on either gutter. The side has to stay in
    // the layout as a transparent colour: a border insets what it
    // wraps, so dropping it would move the gutter's content 0.5 px
    // against every other theme's.
    test('the gutter rim keeps its 0.5 px in every theme', () {
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        final raised = T.chromeStyle == ChromeStyle.raised;
        expect(
          gutterRimColor().a,
          raised ? 0.0 : T.border.a,
          reason: mode.name,
        );
      }
    });

    // The gutters run down the right edge and along the bottom of the
    // timeline. Classic and High Contrast keep the bgSurface they drew; both
    // concepts name their own ground, D #1D1B1B and E #202020.
    test('the gutter colour is gutterBg, and neither concept follows', () {
      for (final mode in [AppThemeMode.classic, AppThemeMode.highContrast]) {
        T.setMode(mode);
        expect(T.gutterBg, T.bgSurface, reason: mode.name);
      }
      T.setMode(AppThemeMode.dark);
      expect(T.gutterBg, const Color(0xFF1D1B1B));
      expect(T.gutterBg, isNot(T.bgSurface));
      T.setMode(AppThemeMode.light);
      expect(T.gutterBg, const Color(0xFFDAD7D1));
      expect(T.gutterBg, isNot(T.bgSurface));
    });

    test('raised is a bgSurface card at T.radius with no border', () {
      T.setMode(AppThemeMode.light);
      final deco = trackPanelDecoration();
      expect(deco.color, T.bgSurface);
      expect(deco.borderRadius, BorderRadius.circular(T.radius));
      expect(deco.border, isNull);
    });

    test('the strip under the card is a darker ground than the card', () {
      // A card the colour of its own ground draws nothing. Dark keeps
      // the strip darker than its panels; Light keeps the relation on
      // its own ramp, bgDeep under bgSurface.
      T.setMode(AppThemeMode.light);
      expect(trackPanelStripColor(), T.bgDeep);
      expect(trackPanelDecoration().color, T.bgSurface);
      expect(
        trackPanelStripColor().computeLuminance(),
        lessThan(trackPanelDecoration().color!.computeLuminance()),
      );
    });

    test('the raised margin is the inset the lane block takes', () {
      // elements_view wraps the waveform block in
      // EdgeInsets.symmetric(vertical: 4), so a card inset by the same
      // number lines up with its own block and sits 8 px from the next
      // card, as two adjacent blocks do.
      T.setMode(AppThemeMode.light);
      expect(trackPanelMargin(), const EdgeInsets.all(4));
    });

    test('the margin is paid for out of the padding, in every theme', () {
      // trackPanelMinHeight budgets the column, this padding and the
      // overhead, so the padding must give back what the margin takes
      // or a track at that minimum overflows by the difference.
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        final m = trackPanelMargin();
        final p = trackPanelPadding(kTrackPanelPadding);
        expect(
          m.vertical + p.vertical,
          kTrackPanelPadding.vertical,
          reason: '${mode.name} vertical box',
        );
        expect(
          m.horizontal + p.horizontal,
          kTrackPanelPadding.horizontal,
          reason: '${mode.name} horizontal box',
        );
        expect(
          trackPanelVerticalOverhead(kTrackPanelPadding),
          trackPanelBorderHeight(),
          reason: '${mode.name} overhead is the border alone',
        );
      }
    });

    test('a base with no room for the margin reports the shortfall', () {
      // The video row pads only the top and the left, so the floor
      // keeps 4 px of the margin that the padding cannot give back.
      T.setMode(AppThemeMode.light);
      const base = EdgeInsets.only(left: 8, top: 6);
      final p = trackPanelPadding(base);
      expect(p.top, 2);
      expect(p.bottom, 0);
      expect(p.left, 4);
      expect(p.right, 0);
      expect(trackPanelVerticalOverhead(base), 4);
    });

    test('the border height matches the decoration it is read from', () {
      // The value is written as a constant, so pin it against the
      // border trackPanelDecoration actually returns.
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        final border = trackPanelDecoration().border;
        expect(
          trackPanelBorderHeight(),
          border == null ? 0 : border.dimensions.vertical,
          reason: mode.name,
        );
      }
    });

    testWidgets('TrackPanel keeps the column width in every theme', (
      tester,
    ) async {
      // The inset comes out of the panel, not out of the column, so
      // the waveform beside it does not move when the theme changes.
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 200,
                child: Row(
                  children: [
                    TrackPanel(
                      key: const Key('panel'),
                      width: 180,
                      basePadding: kTrackPanelPadding,
                      child: const Column(children: [SizedBox(height: 40)]),
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byKey(const Key('panel'))).width,
          180,
          reason: mode.name,
        );
      }
    });

    testWidgets('the panel fills its row, so the card leaves no gap', (
      tester,
    ) async {
      // _AudioTrack's child is a Column at the default MainAxisSize.max
      // under the row's bounded height, so the panel takes the whole
      // row. The card needs that: an opaque fill short of the row
      // would leave bare ground above and below it.
      Widget host() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: Row(
              children: [
                TrackPanel(
                  key: const Key('panel'),
                  width: 180,
                  basePadding: kTrackPanelPadding,
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [SizedBox(height: 40, width: 10)],
                  ),
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      double painted() => tester
          .getSize(
            find
                .descendant(
                  of: find.byKey(const Key('panel')),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .height;

      T.setMode(AppThemeMode.classic);
      await tester.pumpWidget(host());
      expect(painted(), 200);

      T.setMode(AppThemeMode.light);
      await tester.pumpWidget(host());
      // Full row, less the inset the card is separated by.
      expect(painted(), 200 - trackPanelMargin().vertical);
    });

    testWidgets('the panel does not overflow a row at its minimum height', (
      tester,
    ) async {
      // trackPanelMinHeight is what _AudioTrack sizes its row to. Fill
      // a panel of that height with a column of exactly the height
      // trackPanelColumnHeight budgets and nothing may overflow. The
      // mix-excluded badge is the row that takes the budget to its
      // limit, and it is drawn only when the element is excluded.
      final element = AudioElement(
        id: 1,
        name: 'e',
        type: 'Object',
        layout: '',
        codec: 'LPCM',
        color: 0,
      );
      const meterChannels = 12;
      final column = trackPanelColumnHeight(element, meterChannels);
      for (final mode in AppThemeMode.values) {
        T.setMode(mode);
        // Measured per theme: the panel's bottom line is part of the
        // budget, and High Contrast's is its borderWidth.
        final row = trackPanelMinHeight(element, meterChannels);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: row,
                child: Row(
                  children: [
                    TrackPanel(
                      width: 180,
                      basePadding: kTrackPanelPadding,
                      child: Column(
                        children: [SizedBox(height: column, width: 10)],
                      ),
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: mode.name);
      }
    });
  });
}
