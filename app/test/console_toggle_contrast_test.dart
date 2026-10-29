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

// A ConsoleToggle's knob stands out from its track in both states and in
// every theme: at least 3:1, the non-text contrast minimum. In Classic
// and High Contrast the off knob was drawn in the track's own colour
// (ES-929). The knob also stays inside the track's rim, and the on knob's
// glow paints nothing outside the track.

import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contrast.dart';

Future<void> _pump(WidgetTester tester, {required bool value}) =>
    tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ConsoleToggle(value: value, onChanged: (_) {}),
        ),
      ),
    );

BoxDecoration _decoration(WidgetTester tester, Finder container) =>
    tester.widget<Container>(container).decoration! as BoxDecoration;

final _knob = find.descendant(
  of: find.byType(AnimatedPositioned),
  matching: find.byType(Container),
);

/// The track's fill and the colour the knob is seen by: its outline when
/// it has one, else its fill.
(Color track, Color knob) _colours(WidgetTester tester) {
  final track = _decoration(
    tester,
    find.ancestor(of: find.byType(Stack), matching: find.byType(Container)),
  );
  final knob = _decoration(tester, _knob);
  final border = knob.border;
  final outline = border is Border ? border.top.color : null;
  return (track.color!, outline ?? knob.color!);
}

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  for (final mode in AppThemeMode.values) {
    for (final value in [false, true]) {
      final state = value ? 'on' : 'off';
      testWidgets('the $state knob stands out, theme ${mode.name}', (
        tester,
      ) async {
        T.setMode(mode);
        await _pump(tester, value: value);
        final (track, knob) = _colours(tester);
        final ratio = contrastRatio(knob, track);
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason:
              '$state knob $knob on track $track is '
              '${ratio.toStringAsFixed(2)}:1',
        );
      });
    }
  }

  for (final mode in AppThemeMode.values) {
    for (final value in [false, true]) {
      final state = value ? 'on' : 'off';
      testWidgets('the $state knob sits inside the track, theme ${mode.name}', (
        tester,
      ) async {
        T.setMode(mode);
        await _pump(tester, value: value);
        await tester.pumpAndSettle();
        final track = tester.getRect(
          find.ancestor(
            of: find.byType(Stack),
            matching: find.byType(Container),
          ),
        );
        final knob = tester.getRect(_knob);
        // The knob's box, margin included, stays inside the track's rim
        // (1 px, High Contrast's borderWidth, none on the raised pill),
        // so the Stack never clips it.
        final rim = switch (T.chromeStyle) {
          ChromeStyle.raised => 0.0,
          ChromeStyle.outlined => T.borderWidth,
          _ => 1.0,
        };
        expect(knob.left, greaterThanOrEqualTo(track.left + rim));
        expect(knob.right, lessThanOrEqualTo(track.right - rim));
        expect(knob.top, greaterThanOrEqualTo(track.top + rim));
        expect(knob.bottom, lessThanOrEqualTo(track.bottom - rim));
        if (T.chromeStyle == ChromeStyle.raised) return;
        // In the well the knob's box fills the inside's height and
        // travels its whole width: against the rim on the left when off,
        // on the right when on.
        expect(knob.top, track.top + rim);
        expect(knob.bottom, track.bottom - rim);
        if (value) {
          expect(knob.right, track.right - rim);
        } else {
          expect(knob.left, track.left + rim);
        }
      });
    }
  }

  for (final mode in AppThemeMode.values) {
    testWidgets('the on knob paints nothing outside the track, '
        'theme ${mode.name}', (tester) async {
      T.setMode(mode);
      // flutter_test draws BoxShadow without its blur unless this is off;
      // the knob's glow is a blurred shadow.
      debugDisableShadows = false;
      try {
        const key = ValueKey('toggle');
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: ConsoleToggle(value: true, onChanged: (_) {}),
                ),
              ),
            ),
          ),
        );
        final boundary =
            tester.renderObject(find.byKey(key)) as RenderRepaintBoundary;
        late final ByteData data;
        late final int width;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          width = image.width;
          image.dispose();
        });
        // The 8 px padding around the 36 x 18 track stays unpainted.
        var lit = 0;
        for (var y = 0; y < data.lengthInBytes ~/ (4 * width); y++) {
          for (var x = 0; x < width; x++) {
            final inTrack = x >= 8 && x < 44 && y >= 8 && y < 26;
            if (!inTrack && data.getUint8((y * width + x) * 4 + 3) > 0) lit++;
          }
        }
        expect(lit, 0, reason: '$lit pixels painted outside the track');
      } finally {
        debugDisableShadows = true;
      }
    });
  }

  testWidgets('the High Contrast off knob is outlined, at the on size', (
    tester,
  ) async {
    T.setMode(AppThemeMode.highContrast);
    await _pump(tester, value: true);
    final onSize = tester.getSize(_knob);
    await _pump(tester, value: false);
    await tester.pumpAndSettle();
    final knob = _decoration(tester, _knob);
    final border = knob.border;
    expect(border, isA<Border>());
    border as Border;
    expect(border.top.color, T.borderStrong);
    expect(border.top.width, T.borderWidth);
    expect(knob.color, T.bgDeep);
    expect(tester.getSize(_knob), onSize);
  });
}
