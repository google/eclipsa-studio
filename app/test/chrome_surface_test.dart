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
import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the content fills every slice in every style', (tester) async {
    // The beveled and raised grounds put their 1 px lines and the
    // content in one Stack. Without StackFit.expand the Stack passes
    // loose constraints to the content — the lines are Positioned and
    // do not count — and aligns it topStart, so a row of text sat
    // against the strip's top edge instead of centring in it.
    //
    // The child has to be a Row, as every strip's is. A Center would
    // hide the fault: with no heightFactor it fills a loose constraint
    // and centres the text either way.
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      for (final slice in ChromeSlice.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  ChromeSurface(
                    key: ValueKey('${mode.name}/${slice.name}'),
                    slice: slice,
                    child: const Row(children: [Text('96000 Hz')]),
                  ),
                ],
              ),
            ),
          ),
        );
        final why = '${mode.name} / ${slice.name}';
        final strip = tester.getRect(find.byType(ChromeSurface));
        final text = tester.getRect(find.text('96000 Hz'));
        // Within a pixel: the raised titlebar and top bar carry a 1 px
        // border on one edge, which shifts the centre by half of it.
        expect(
          text.center.dy,
          closeTo(strip.center.dy, 1.0),
          reason: 'content is not vertically centred in $why',
        );
      }
    }
  });

  Future<void> pumpTitlebar(
    WidgetTester tester, {
    required String title,
    required Widget leading,
    Widget? dragRegion,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              width: 800,
              child: TitlebarStrip(
                title: title,
                leading: leading,
                trailing: const SizedBox(width: 138),
                dragRegion: dragRegion,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('the titlebar centres its title on the window', (tester) async {
    // The Windows menu bar on the left is wider than the caption buttons
    // on the right; centring in the gap between them would put the
    // title off the window's centre.
    await pumpTitlebar(
      tester,
      title: 'Session',
      leading: const SizedBox(width: 220),
    );
    final strip = tester.getRect(find.byType(TitlebarStrip));
    final text = tester.getRect(find.text('Session'));
    expect(text.center.dx, closeTo(strip.center.dx, 0.5));
  });

  testWidgets('a title too wide to centre stays between the two sides', (
    tester,
  ) async {
    await pumpTitlebar(
      tester,
      title: 'A very long session name ' * 8,
      leading: const SizedBox(width: 220),
    );
    final strip = tester.getRect(find.byType(TitlebarStrip));
    final text = tester.getRect(find.byType(Text));
    expect(text.left, greaterThanOrEqualTo(strip.left + 220));
    expect(text.right, lessThanOrEqualTo(strip.right - 138));
  });

  testWidgets('a click in the leading slot does not wait for the drag '
      'region', (tester) async {
    // The drag region recognizes double clicks. Were it an ancestor of
    // the menu bar, a click on a menu title would wait out the
    // double-tap timeout (300 ms) before it registered.
    var taps = 0;
    var dragRegionTaps = 0;
    await pumpTitlebar(
      tester,
      title: 'Session',
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: const SizedBox(width: 60, height: 28),
      ),
      dragRegion: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: () => dragRegionTaps++,
        child: const SizedBox.expand(),
      ),
    );
    await tester.tapAt(
      tester.getTopLeft(find.byType(TitlebarStrip)) + const Offset(30, 14),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(taps, 1);
    expect(dragRegionTaps, 0);
  });

  testWidgets('a drag over the title or empty strip reaches the drag '
      'region', (tester) async {
    // The row sits over the drag region, so the region only sees drags
    // the row lets through: the title ignores the pointer and the empty
    // space between the widgets hit-tests nothing.
    var drags = 0;
    await pumpTitlebar(
      tester,
      title: 'Session',
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: const SizedBox(width: 60, height: 28),
      ),
      dragRegion: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => drags++,
        child: const SizedBox.expand(),
      ),
    );
    await tester.drag(find.text('Session'), const Offset(40, 0));
    expect(drags, 1, reason: 'drag over the title');
    await tester.dragFrom(
      tester.getTopLeft(find.byType(TitlebarStrip)) + const Offset(120, 14),
      const Offset(40, 0),
    );
    expect(drags, 2, reason: 'drag over the empty strip');
  });

  testWidgets('the Light theme rims the status bar on its top edge only', (
    tester,
  ) async {
    // A rim on all four sides suits a bar that stands as a card. In
    // the app the bar is the window's bottom strip: macOS rounds the
    // window's corners, which cut a border drawn on the other three
    // edges, so the rim ran down the straight sides and stopped where
    // the curve began.
    T.setMode(AppThemeMode.light);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [
              ChromeSurface(
                slice: ChromeSlice.statusbar,
                child: SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(ChromeSurface),
            matching: find.byType(Container),
          )
          .first,
    );
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.top.color, T.chromeRimDark);
    expect(border.left, BorderSide.none);
    expect(border.right, BorderSide.none);
    expect(border.bottom, BorderSide.none);
  });
}
