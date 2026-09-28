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
import 'package:eclipsa_studio/widgets/app_button.dart';
import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [AppButton] is the app's one text button: two sizes, four roles, one
/// drawing in every theme, drawn from the tokens and not from Material.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: eclipsaStudioTheme(),
      home: Scaffold(body: Center(child: child)),
    ),
  );

  /// The button's own box: the [Container] AppButton draws.
  BoxDecoration face(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.descendant(
                  of: find.byType(AppButton),
                  matching: find.byType(Container),
                ),
              )
              .decoration
          as BoxDecoration;

  Color labelColor(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style!.color!;

  testWidgets('fires onPressed when enabled and not when disabled', (
    tester,
  ) async {
    var taps = 0;
    await pump(tester, AppButton(label: 'Go', onPressed: () => taps++));
    await tester.tap(find.byType(AppButton));
    expect(taps, 1);

    await pump(tester, const AppButton(label: 'Go', onPressed: null));
    await tester.tap(find.byType(AppButton));
    expect(taps, 1);
  });

  testWidgets('Enter activates an autofocused button', (tester) async {
    var taps = 0;
    await pump(
      tester,
      AppButton(label: 'Accept', autofocus: true, onPressed: () => taps++),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1, reason: 'the default action of a dialog takes Enter');
  });

  // The app theme takes Flutter's platform default visual density,
  // which is compact on desktop and takes 8 px off each side of a
  // Material button. AppButton draws no Material button, so it has to
  // measure the same under the desktop density as under the test's.
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('sizes hold in every theme and role on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        for (final mode in AppThemeMode.values) {
          T.setMode(mode);
          for (final size in AppButtonSize.values) {
            for (final role in AppButtonRole.values) {
              await tester.pumpWidget(const SizedBox());
              await pump(
                tester,
                AppButton(
                  label: 'Label',
                  role: role,
                  size: size,
                  onPressed: () {},
                ),
              );
              expect(
                tester.getSize(find.byType(AppButton)).height,
                AppButton.heightOf(size),
                reason: '${mode.name} ${size.name} ${role.name}',
              );
            }
          }
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('the affirmative is accentFill under accentInk in every theme', (
    tester,
  ) async {
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      await tester.pumpWidget(const SizedBox());
      await pump(
        tester,
        AppButton(
          label: 'Done',
          role: AppButtonRole.affirmative,
          onPressed: () {},
        ),
      );
      expect(face(tester).color, T.accentFill, reason: mode.name);
      expect(face(tester).gradient, isNull, reason: mode.name);
      expect(labelColor(tester, 'Done'), T.accentInk, reason: mode.name);
    }
  });

  testWidgets('roles take their ink and rim from the tokens', (tester) async {
    for (final mode in AppThemeMode.values) {
      T.setMode(mode);
      for (final role in [
        AppButtonRole.standard,
        AppButtonRole.destructive,
        AppButtonRole.quiet,
      ]) {
        await tester.pumpWidget(const SizedBox());
        await pump(tester, AppButton(label: 'X', role: role, onPressed: () {}));
        final box = face(tester);
        expect(box.color, isNull, reason: '${mode.name} ${role.name} fill');
        final rim = box.border!.top;
        expect(rim.width, T.borderWidth, reason: '${mode.name} ${role.name}');
        switch (role) {
          case AppButtonRole.standard:
            expect(rim.color, T.borderStrong, reason: mode.name);
            expect(labelColor(tester, 'X'), T.textPrimary, reason: mode.name);
          case AppButtonRole.destructive:
            expect(rim.color, T.borderStrong, reason: mode.name);
            expect(labelColor(tester, 'X'), T.errorRed, reason: mode.name);
          case AppButtonRole.quiet:
            expect(rim.color.a, 0, reason: '${mode.name}: quiet has no rim');
            expect(labelColor(tester, 'X'), T.textSecondary, reason: mode.name);
          case AppButtonRole.affirmative:
            break;
        }
      }
    }
  });

  // A Container with an alignment fills any bounded parent, which once
  // stretched an alert's OK across the whole footer.
  testWidgets('hugs its content under loose constraints and fills a tight '
      'width', (tester) async {
    await pump(
      tester,
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [AppButton(label: 'OK', onPressed: () {})],
      ),
    );
    final hugged = tester.getSize(find.byType(AppButton)).width;
    expect(hugged, lessThan(120), reason: 'OK plus 2 x 12 padding');

    await pump(
      tester,
      SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppButton(
              label: 'OK',
              mainAxisAlignment: MainAxisAlignment.start,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byType(AppButton)).width, 300);
    expect(
      tester.getTopLeft(find.text('OK')).dx,
      tester.getTopLeft(find.byType(AppButton)).dx + 12 + T.borderWidth,
      reason: 'the label starts at the left padding',
    );
  });

  testWidgets('foreground overrides the ink of a standard button', (
    tester,
  ) async {
    T.setMode(AppThemeMode.light);
    await pump(
      tester,
      AppButton(
        label: 'New Session',
        icon: Icons.add,
        foreground: T.chromeInk,
        onPressed: () {},
      ),
    );
    expect(labelColor(tester, 'New Session'), T.chromeInk);
    expect(tester.widget<Icon>(find.byIcon(Icons.add)).color, T.chromeInk);
  });

  testWidgets('disabled dims the ink and drops the accent fill', (
    tester,
  ) async {
    await pump(tester, const AppButton(label: 'Off', onPressed: null));
    expect(labelColor(tester, 'Off').a, closeTo(0.4, 0.01));
    expect(face(tester).border!.top.color.a, closeTo(0.4, 0.01));

    await pump(
      tester,
      const AppButton(
        label: 'Off',
        role: AppButtonRole.affirmative,
        onPressed: null,
      ),
    );
    expect(face(tester).color, T.bgControls);
    expect(labelColor(tester, 'Off'), T.textTertiary);
  });

  testWidgets('hover tints the face in the ink and focus rings it', (
    tester,
  ) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await pump(tester, AppButton(label: 'Hover', onPressed: () {}));
    Container box() => tester.widget<Container>(
      find.descendant(
        of: find.byType(AppButton),
        matching: find.byType(Container),
      ),
    );
    expect(box().foregroundDecoration, isNull);

    await mouse.moveTo(tester.getCenter(find.byType(AppButton)));
    await tester.pumpAndSettle();
    final overlay = (box().foregroundDecoration as BoxDecoration).color!;
    expect(overlay.a, closeTo(0.08, 0.01));
    expect(
      labelColor(tester, 'Hover'),
      T.textPrimary,
      reason: 'the label keeps its contrast through the hover',
    );

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    // The ring is drawn over the face in the ink, 2 px wide, so it
    // contrasts on every ground the button sits on, the landing card's
    // chromeBg included, where an accent would not be gated.
    final ring = (box().foregroundDecoration as BoxDecoration).border!.top;
    expect(ring.color, T.textPrimary);
    expect(ring.width, 2);
    expect(face(tester).border!.top.color, T.borderStrong);
  });

  group('face (ES-755)', () {
    testWidgets('raised draws RaisedFace in Light and the gradient face '
        'elsewhere', (tester) async {
      T.setMode(AppThemeMode.light);
      await pump(
        tester,
        AppButton(label: 'Go', onPressed: () {}, face: AppButtonFace.raised),
      );
      expect(find.byType(RaisedFace), findsOneWidget);

      T.setMode(AppThemeMode.dark);
      await pump(
        tester,
        AppButton(label: 'Go', onPressed: () {}, face: AppButtonFace.raised),
      );
      expect(find.byType(RaisedFace), findsNothing);
      expect(face(tester).gradient, isNotNull);
      expect(face(tester).boxShadow, isNotEmpty);
    });

    testWidgets('the raised face drops its shadow pressed and disabled', (
      tester,
    ) async {
      T.setMode(AppThemeMode.dark);
      await pump(
        tester,
        AppButton(label: 'Go', onPressed: () {}, face: AppButtonFace.raised),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppButton)),
      );
      await tester.pump();
      expect(face(tester).boxShadow, isNull);
      await gesture.up();

      await pump(
        tester,
        const AppButton(
          label: 'Go',
          onPressed: null,
          face: AppButtonFace.raised,
        ),
      );
      expect(face(tester).boxShadow, isNull);
    });

    testWidgets('recessed draws the recessed well', (tester) async {
      T.setMode(AppThemeMode.classic);
      await pump(
        tester,
        AppButton(label: 'Go', onPressed: () {}, face: AppButtonFace.recessed),
      );
      final well = recessedWell(radius: T.radiusSm);
      expect(face(tester).color, well.color);
      expect(face(tester).border, well.border);
    });

    testWidgets('a role other than standard ignores the face', (tester) async {
      T.setMode(AppThemeMode.dark);
      await pump(
        tester,
        AppButton(
          label: 'OK',
          onPressed: () {},
          role: AppButtonRole.affirmative,
          face: AppButtonFace.raised,
        ),
      );
      expect(face(tester).gradient, isNull);
      expect(face(tester).color, T.accentFill);
    });
  });
}
