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
import 'package:eclipsa_studio/widgets/solo_mute_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The two drawings of the S / M toggle. Light's is the raised face;
// the flat one is what every shipped theme drew before it existed, and
// these assertions are what keeps it there.
void main() {
  setUp(() => T.setMode(AppThemeMode.classic));
  tearDown(() => T.setMode(T.defaultMode));

  Widget host({required bool active, bool enabled = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SoloMuteButton(
          label: 'S',
          tooltip: 'Solo',
          active: active,
          activeColor: T.meterYellow,
          onTap: () {},
          enabled: enabled,
        ),
      ),
    ),
  );

  BoxDecoration faceOf(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.descendant(
                  of: find.byType(SoloMuteButton),
                  matching: find.byType(Container),
                ),
              )
              .decoration
          as BoxDecoration;

  Color inkOf(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byType(SoloMuteButton),
          matching: find.byType(Text),
        ),
      )
      .style!
      .color!;

  group('flat', () {
    // Dark keeps the flat face; Classic draws the recessed well
    // since the 2026-09 remake.
    setUp(() => T.setMode(AppThemeMode.dark));

    testWidgets('engaged fills and rims with the active colour', (
      tester,
    ) async {
      await tester.pumpWidget(host(active: true));
      final deco = faceOf(tester);
      expect(deco.color, T.meterYellow.withValues(alpha: 0.3));
      expect(deco.border!.top.color, T.meterYellow.withValues(alpha: 0.6));
      expect(deco.border!.top.width, 1);
      expect(inkOf(tester), T.meterYellow);
    });

    testWidgets('idle is a bgControls well in a half-pixel rim', (
      tester,
    ) async {
      await tester.pumpWidget(host(active: false));
      final deco = faceOf(tester);
      expect(deco.color, T.bgControls);
      expect(deco.border!.top.color, T.borderStrong);
      expect(deco.border!.top.width, 0.5);
      expect(inkOf(tester), T.textTertiary);
    });
  });

  group('recessed', () {
    setUp(() => T.setMode(AppThemeMode.classic));

    testWidgets('idle is the transport buttons\' well', (tester) async {
      // recessedWell: bgControls in a chromeRimDark rim over a
      // chromeRimLight edge one pixel below.
      await tester.pumpWidget(host(active: false));
      final deco = faceOf(tester);
      expect(deco.color, T.bgControls);
      expect(deco.border!.top.color, T.chromeRimDark);
      expect(deco.boxShadow!.single.color, T.chromeRimLight);
      expect(deco.boxShadow!.single.offset, const Offset(0, 1));
      expect(inkOf(tester), T.textTertiary);
    });

    testWidgets('engaged lights the well with the active colour', (
      tester,
    ) async {
      // The rim stays the hole's; the state is the fill and the ink.
      await tester.pumpWidget(host(active: true));
      final deco = faceOf(tester);
      expect(deco.color, T.meterYellow.withValues(alpha: 0.3));
      expect(deco.border!.top.color, T.chromeRimDark);
      expect(inkOf(tester), T.meterYellow);
    });
  });

  group('raised', () {
    setUp(() => T.setMode(AppThemeMode.light));

    testWidgets('engaged is a border rim over bgElevated', (tester) async {
      // The rim's 1 px border insets its child, so the accent fill lands
      // exactly where the frame's `bg` sits inside `rim`.
      await tester.pumpWidget(host(active: true));
      final deco = faceOf(tester);
      expect(deco.color, T.bgElevated);
      expect(deco.border!.top.color, T.border);
      expect(deco.border!.top.width, T.borderWidth);
      // Container builds a DecoratedBox of its own for the rim, so the
      // accent fill is the deeper of the two.
      final fill =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(SoloMuteButton),
                          matching: find.byType(DecoratedBox),
                        )
                        .last,
                  )
                  .decoration
              as BoxDecoration;
      expect(fill.color, T.meterYellow);
      expect(fill.borderRadius, BorderRadius.circular(T.radiusSm - 1));
      // Not the frame's borderLight: that is 3.78:1 on meterRed, and
      // this control fills with the caller's colour, not the frame's
      // blue. accentFg clears 4.5 on both fills.
      expect(inkOf(tester), T.accentFg);
    });

    testWidgets('idle is a flat bgControls face with no rim', (tester) async {
      await tester.pumpWidget(host(active: false));
      final deco = faceOf(tester);
      expect(deco.color, T.bgControls);
      expect(deco.border, isNull);
      expect(inkOf(tester), T.chromeTabOn);
    });

    testWidgets('disabled and idle drops to textGhost', (tester) async {
      await tester.pumpWidget(host(active: false, enabled: false));
      expect(inkOf(tester), T.textGhost);
    });
  });

  // An element can be soloed and mix-excluded at once (ES-297), so the
  // engaged-and-disabled face is reachable. Disabling dims the idle
  // look only; an engaged button keeps its fill so it still reads as
  // latched and can be un-latched.
  testWidgets('engaged and disabled keeps the engaged ink in both styles', (
    tester,
  ) async {
    T.setMode(AppThemeMode.classic);
    await tester.pumpWidget(host(active: true, enabled: false));
    expect(inkOf(tester), T.meterYellow);
    expect(faceOf(tester).color, T.meterYellow.withValues(alpha: 0.3));
    T.setMode(AppThemeMode.light);
    await tester.pumpWidget(host(active: true, enabled: false));
    expect(inkOf(tester), T.accentFg);
    expect(faceOf(tester).color, T.bgElevated);
  });

  testWidgets('the face follows a theme switch without a remount', (
    tester,
  ) async {
    // SoloMuteButton reads T.* and is not const-constructed here, so a
    // rebuild after setMode must swap the drawing in place.
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Center(
                child: SoloMuteButton(
                  label: 'S',
                  tooltip: 'Solo',
                  active: true,
                  activeColor: T.meterYellow,
                  onTap: () {},
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(faceOf(tester).color, T.meterYellow.withValues(alpha: 0.3));
    T.setMode(AppThemeMode.light);
    rebuild(() {});
    await tester.pump();
    expect(faceOf(tester).color, T.bgElevated);
    expect(inkOf(tester), T.accentFg);
  });

  testWidgets('D keeps the flat face', (tester) async {
    // Light and, since the 2026-09 remake, Classic and High Contrast branch; Dark
    // must draw what it drew.
    for (final mode in [AppThemeMode.dark]) {
      T.setMode(mode);
      await tester.pumpWidget(host(active: true));
      expect(
        faceOf(tester).color,
        T.meterYellow.withValues(alpha: 0.3),
        reason: '${mode.name} engaged fill',
      );
      expect(inkOf(tester), T.meterYellow, reason: '${mode.name} engaged ink');
    }
  });

  testWidgets('High Contrast fills the engaged face and inks it accentFg', (
    tester,
  ) async {
    // A solid fill at borderWidth, no rim when on; the label takes
    // accentFg, the ink the theme puts on any fill.
    T.setMode(AppThemeMode.highContrast);
    await tester.pumpWidget(host(active: true));
    expect(faceOf(tester).color, T.meterYellow);
    expect(inkOf(tester), T.accentFg);
    await tester.pumpWidget(host(active: false));
    expect(faceOf(tester).color, T.bgControls);
    expect(
      faceOf(tester).border,
      Border.all(color: T.borderStrong, width: T.borderWidth),
    );
  });
}
