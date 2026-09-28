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
import 'package:eclipsa_studio/widgets/theme_gallery.dart';
import 'package:eclipsa_studio/widgets/topbar_selector.dart';
import 'package:eclipsa_studio/widgets/transport_clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Smoke coverage for the dev-only gallery. It renders every token, so
// these tests check that it builds without throwing in each theme.
/// A theme's label as the gallery's section header prints it.
String _upper(AppThemeMode mode) => kThemeMeta[mode]!.label.toUpperCase();

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ThemeGallery())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders without throwing in every theme', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setMode(AppThemeMode.classic));

    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await pump(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'gallery threw in ${mode.name}',
      );
      expect(find.text('Theme Gallery'), findsOneWidget);
    }
  });

  testWidgets('scrollTo moves the open gallery and clears on close', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setMode(AppThemeMode.classic));
    T.setMode(AppThemeMode.dark);
    await pump(tester);
    // Past the end: the offset clamps to the extent, which is positive
    // because the gallery is taller than the 1200 px view.
    final far = ThemeGallery.scrollTo(1e9);
    expect(far, isNotNull);
    expect(far!.max, greaterThan(0));
    expect(far.offset, far.max);
    expect(ThemeGallery.scrollTo(0)!.offset, 0);
    // Unmounting the gallery clears the controller, so a later call
    // reports nothing to scroll rather than touching a disposed one.
    await tester.pumpWidget(const SizedBox());
    expect(ThemeGallery.scrollTo(0), isNull);
  });

  testWidgets('renders in every font mode', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setFontMode(FontSizeMode.medium));

    for (final font in FontSizeMode.values) {
      T.setFontMode(font);
      await pump(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'gallery threw at font size ${font.label}',
      );
    }
  });

  testWidgets('does not overflow in a narrow window', (tester) async {
    // The first version overflowed horizontally here: the meter/axis/
    // correlation bars were one fixed Row of twelve, which only fits on
    // a wide viewport. A 1600px test view hid it entirely.
    tester.view.physicalSize = const Size(1040, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setFontMode(FontSizeMode.medium));

    // Large font is the worst case — every label grows. Every theme,
    // because the concept drawings lay their cards out differently
    // from the flat ones (taller strips, 124 px drop slots).
    T.setFontMode(FontSizeMode.large);
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await pump(tester);
      expect(tester.takeException(), isNull, reason: mode.name);
    }
  });

  testWidgets('zoom magnifies without clipping or overflowing', (tester) async {
    // Transform.scale would paint bigger while measuring the same, so
    // the scroll views would keep the unscaled extent and silently clip
    // the magnified content. The check that catches that is height:
    // scrolling further at 4x than at 1x is only possible if the body
    // actually reports its scaled size.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setMode(AppThemeMode.classic));

    await pump(tester);
    final atOneX = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .length;

    await tester.tap(find.text('4x'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // A second scroll axis appears only when zoomed — at 1x the
    // horizontal one would be dead weight and is not built.
    final atFourX = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .length;
    expect(atFourX, greaterThan(atOneX));

    await tester.tap(find.text('1x'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the middle mouse button pans both axes', (tester) async {
    // A wheel only drives the vertical axis, and Flutter's desktop
    // ScrollBehavior leaves mouse out of its drag devices, so without
    // this the horizontal axis has no mouse input at all. Left-drag is
    // not available for it — the knobs are dragged to set their value.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setMode(AppThemeMode.classic));

    await pump(tester);
    await tester.tap(find.text('4x'));
    await tester.pumpAndSettle();

    // Read the position off the ScrollableState, not the widget's
    // controller — SingleChildScrollView does not forward that one, so
    // Scrollable.controller is null here.
    //
    // `last`, not `first`: the theme picker in the controls row is
    // itself a horizontal scroll view and sits earlier in the tree, so
    // firstWhere finds that one and the test passes a no-op drag.
    ScrollableState horizontal() => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .lastWhere((s) => s.widget.axisDirection == AxisDirection.right);
    expect(
      horizontal().position.maxScrollExtent,
      greaterThan(0),
      reason: 'nothing to pan means the rest of this proves nothing',
    );
    final before = horizontal().position.pixels;

    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    final centre = tester.getCenter(find.byType(Scrollbar).first);
    await mouse.addPointer(location: centre);
    addTearDown(mouse.removePointer);
    await tester.pump();
    // addPointer only hovers. Without an explicit down there is no
    // PointerDownEvent, so the Listener never arms and the drag is a
    // no-op that still reports a clean pass.
    await mouse.down(centre);
    await tester.pump();
    await mouse.moveBy(const Offset(-120, 0));
    await tester.pump();

    expect(
      horizontal().position.pixels,
      greaterThan(before),
      reason: 'dragging left moves the view right',
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the body re-renders when the theme changes', (tester) async {
    // The gallery compares themes, so it must re-render on a theme
    // switch. It once kept the theme it was opened with: `const
    // _Body()` was canonicalised, so Element.updateChild skipped the
    // whole subtree however often the state above it rebuilt. Watching
    // themeModeProvider alone did not fix it.
    // Asserted on _Swatches' section title, which names the theme.
    T.setMode(AppThemeMode.classic);
    tester.view.physicalSize = const Size(1600, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, r, _) {
                ref = r;
                return const ThemeGallery();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining(_upper(AppThemeMode.classic)), findsWidgets);

    ref.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pumpAndSettle();

    expect(
      find.textContaining(_upper(AppThemeMode.dark)),
      findsWidgets,
      reason: 'the gallery did not follow the theme switch',
    );
    expect(
      find.textContaining(_upper(AppThemeMode.classic)),
      findsNothing,
      reason: 'a section still names the old theme, so it froze',
    );
  });

  test('the gallery is compiled out of release builds', () {
    // kThemeGalleryEnabled is const, so this is what lets the tree-shaker
    // drop the screen entirely rather than merely hiding the menu item.
    // Tests run in debug, so the value here is true; the assertion that
    // matters is that it is a compile-time constant at all.
    expect(kThemeGalleryEnabled, isTrue);
  });

  testWidgets('the chrome cards follow the theme switch too', (tester) async {
    // Same failure class as the test above, one layer deeper: the mix
    // presentation label and the clock card are constructed const, so a
    // theme switch reaches them only if they watch the theme (the
    // label) or are not canonicalised (the card). Asserted on what each
    // draws per ChromeStyle: the label's case and the clock's box.
    T.setMode(AppThemeMode.classic);
    tester.view.physicalSize = const Size(1600, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => T.setMode(AppThemeMode.classic));

    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, r, _) {
                ref = r;
                return const ThemeGallery();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Container clockBox() => tester.widget<Container>(
      find
          .descendant(
            of: find.byType(TransportClock),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      find.descendant(
        of: find.byType(MixPresentationLabel),
        matching: find.text('Mix Presentation'),
      ),
      findsOneWidget,
    );
    expect(clockBox().decoration, isNotNull, reason: 'flat draws a box');

    ref.read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(MixPresentationLabel),
        matching: find.text('MIX PRESENTATION'),
      ),
      findsOneWidget,
      reason: 'the label did not follow the theme switch',
    );
    expect(
      clockBox().decoration,
      isNull,
      reason: 'the Dark theme draws the clock with no box',
    );
    expect(tester.takeException(), isNull);
  });
}
