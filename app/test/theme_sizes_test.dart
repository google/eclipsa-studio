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

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/video/video_panel.dart';
import 'package:eclipsa_studio/video/video_strip.dart';
import 'package:eclipsa_studio/video/video_track.dart';
import 'package:eclipsa_studio/waveform/multi_channel_waveform.dart';
import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:eclipsa_studio/widgets/drop_zone.dart';
import 'package:eclipsa_studio/widgets/statusbar.dart';
import 'package:eclipsa_studio/widgets/time_ruler.dart';
import 'package:eclipsa_studio/widgets/track_lanes.dart';
import 'package:eclipsa_studio/widgets/transport_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A component's size is the same in every theme; the themes differ in
// how the component is drawn and in its colours. The concept frames
// draw several of these larger — a 56 px top bar, a 52 px status bar
// spacing its items 56 apart, 32/36 px transport buttons, a 124 px
// drop target, a 32 px dropdown, 20 px tabs — and the app takes the
// shipped size.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  test('every fixed component size is the same in every theme', () {
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      final why = mode.name;
      expect(T.titlebar, 28, reason: why);
      expect(T.topbar, 44, reason: why);
      expect(T.statusbar, 28, reason: why);
      expect(TransportButton.size, 30, reason: why);
      expect(TransportButton.gap, T.gapSm, reason: why);
      expect(TransportPlayButton.size, 34, reason: why);
      expect(TimeRulerStrip.height, 32, reason: why);
      expect(DropZone.areaHeight, 80, reason: why);
      expect(StatusbarStrip.gap, T.gapXl, reason: why);
      expect(StatusbarStrip.pairGap, T.gapMd, reason: why);
      expect(trackLaneSpacing(), 2, reason: why);
      expect(MultiChannelWaveform.spacing, 2, reason: why);
      expect(SelectorChrome.height, 24, reason: why);
      expect(SelectorChrome.caretSize, T.iconXs, reason: why);
      expect(SelectorChrome.labelStyle(1).fontSize, T.fontBody, reason: why);
      expect(
        VideoLane.padding,
        const EdgeInsets.symmetric(vertical: 6),
        reason: why,
      );
      expect(VideoStrip.headerHeight, 24, reason: why);
      expect(const VideoPanel().initialHeight, 224, reason: why);
    }
  });

  testWidgets('the video strip header is one size in every theme', (
    tester,
  ) async {
    // The concepts drew this row with iconMd/iconLg glyphs and a
    // fontBody/fontHeading name, which made the header taller in D and
    // Light than in Classic and High Contrast. Since the header lies over the picture,
    // that came out of the picture: the same video drew at a different
    // size depending on the theme.
    final heights = <String, double>{};
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await tester.pumpWidget(
        MaterialApp(
          // The actions are Tooltips, which need an Overlay, and the
          // strip needs a bounded width to lay its Row out in.
          home: Material(
            child: Center(
              child: SizedBox(
                width: 400,
                child: VideoStrip(
                  height: 200,
                  fileName: 'take.mp4',
                  hasMedia: true,
                  isStillImage: false,
                  visible: true,
                  actions: [
                    VideoStripAction(
                      icon: Icons.close,
                      tooltip: 'Remove',
                      onTap: () {},
                    ),
                  ],
                  body: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      heights[mode.name] = tester.getSize(find.text('take.mp4')).height;
      expect(
        tester.getSize(find.byType(VideoStrip)).height,
        200,
        reason: '${mode.name} strip',
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.videocam_outlined)).size,
        T.iconXs,
        reason: '${mode.name} glyph',
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.close)).size,
        T.iconSm,
        reason: '${mode.name} action',
      );
    }
    expect(
      heights.values.toSet(),
      hasLength(1),
      reason: 'the name is one size in every theme: $heights',
    );
  });

  test('the chrome text sizes are the same in every theme', () {
    // Decision 8 of the concept-D plan: where a frame sets text larger
    // than the shipped token, the app draws the shipped size.
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      expect(statusbarTextStyle().fontSize, T.fontBody, reason: mode.name);
    }
  });

  test('the titlebar title is the native window title in every theme', () {
    // The strip stands in for the hidden macOS titlebar, so the title
    // is 13 px semibold in every theme and at every font-size setting,
    // and only its colour is the theme's.
    addTearDown(() => T.setFontMode(FontSizeMode.medium));
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      for (final font in FontSizeMode.values) {
        T.setFontMode(font);
        final style = titlebarTitleStyle();
        expect(style.fontSize, 13, reason: '${mode.name} ${font.name}');
        expect(style.fontWeight, FontWeight.w600, reason: mode.name);
        expect(style.letterSpacing, isNull, reason: mode.name);
        expect(style.color, T.chromeInk, reason: mode.name);
      }
    }
  });
}
