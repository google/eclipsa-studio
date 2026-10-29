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

import 'dart:io';

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/video/video_popout_chrome.dart';
import 'package:eclipsa_studio/widgets/statusbar.dart';
import 'package:eclipsa_studio/widgets/window_titlebar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_manager_mock.dart';

/// The pop-out window's chrome (ES-744): its own title bar and a status
/// strip with the playhead outside fullscreen, neither in fullscreen,
/// nothing drawn over the picture, and the chrome recolouring when the
/// theme changes; and its key rule (ES-797).
///
/// WindowFrameStrip branches on the host platform: it collapses to
/// nothing on Linux, so the title-bar geometry tests run on macOS and
/// Windows only. On Windows it asks window_manager for the maximized
/// state, answered by the mocked channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const title = 'clip.mp4';
  const readout = '00:12.345 / 01:02.000';
  const pictureKey = Key('picture');
  const height = 540.0;
  final hasStrip = Platform.isMacOS || Platform.isWindows;

  setUp(mockWindowManager);
  tearDown(() => T.setMode(T.defaultMode));

  Future<void> pump(
    WidgetTester tester, {
    bool fullscreen = false,
    VoidCallback? onToggleFullscreen,
    VoidCallback? onLeaveFullscreen,
    ValueListenable<String>? readoutValue,
    double width = 960,
    String name = title,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PopoutChrome(
            title: name,
            fullscreen: fullscreen,
            readout: readoutValue ?? const _Const(readout),
            onClose: () async {},
            onToggleFullscreen: onToggleFullscreen ?? () {},
            onLeaveFullscreen: onLeaveFullscreen ?? () {},
            picture: const ColoredBox(key: pictureKey, color: Colors.black),
          ),
        ),
      ),
    );
  }

  Finder inStrip(Finder f) =>
      find.descendant(of: find.byType(WindowFrameStrip), matching: f);

  testWidgets('outside fullscreen the title bar heads the window', (
    tester,
  ) async {
    await pump(tester);
    final strip = find.byType(WindowFrameStrip);
    expect(strip, findsOneWidget);
    expect(inStrip(find.text(title)), findsOneWidget);
    final stripRect = tester.getRect(strip);
    expect(stripRect.top, 0);
    expect(stripRect.height, T.titlebar);
  }, skip: !hasStrip);

  testWidgets('the title is centred in the title bar', (tester) async {
    await pump(tester);
    final strip = tester.getRect(find.byType(WindowFrameStrip));
    final titleRect = tester.getRect(inStrip(find.text(title)));
    expect(titleRect.center.dx, closeTo(strip.center.dx, 1));
    expect(titleRect.center.dy, closeTo(strip.center.dy, 1));
  }, skip: !hasStrip);

  testWidgets('at 320 px a long title ellipsises inside the strip', (
    tester,
  ) async {
    const long = 'a_very_long_video_file_name_that_keeps_going_on.mp4';
    await pump(tester, width: 320, name: long);
    expect(tester.takeException(), isNull);
    final name = tester.getRect(inStrip(find.text(long)));
    final strip = tester.getRect(find.byType(WindowFrameStrip));
    expect(name.left, greaterThanOrEqualTo(strip.left));
    expect(name.right, lessThanOrEqualTo(strip.right));
  }, skip: !hasStrip);

  testWidgets('the status strip shows the readout under the picture', (
    tester,
  ) async {
    await pump(tester);
    final status = find.byType(StatusbarStrip);
    expect(status, findsOneWidget);
    expect(
      find.descendant(of: status, matching: find.text(readout)),
      findsOneWidget,
    );
    final rect = tester.getRect(status);
    expect(rect.height, T.statusbar);
    expect(rect.bottom, height);
  });

  testWidgets('the readout is centred in the status strip', (tester) async {
    await pump(tester);
    final strip = tester.getRect(find.byType(StatusbarStrip));
    final text = tester.getRect(find.text(readout));
    expect(text.center.dx, closeTo(strip.center.dx, 1));
  });

  testWidgets('a readout change redraws the text alone', (tester) async {
    final value = ValueNotifier<String>('00:00.000');
    addTearDown(value.dispose);
    await pump(tester, readoutValue: value);
    expect(find.text('00:00.000'), findsOneWidget);
    value.value = '00:01.500';
    await tester.pump();
    expect(find.text('00:01.500'), findsOneWidget);
    expect(find.text('00:00.000'), findsNothing);
  });

  testWidgets('the picture lies between the two strips', (tester) async {
    await pump(tester);
    final picture = tester.getRect(find.byKey(pictureKey));
    expect(picture.top, T.titlebar);
    expect(picture.bottom, height - T.statusbar);
  }, skip: !hasStrip);

  testWidgets('in fullscreen there is no chrome', (tester) async {
    await pump(tester, fullscreen: true);
    expect(find.byType(WindowFrameStrip), findsNothing);
    expect(find.byType(StatusbarStrip), findsNothing);
    expect(find.text(title), findsNothing);
    expect(find.text(readout), findsNothing);
    final picture = tester.getRect(find.byKey(pictureKey));
    expect(picture.top, 0);
    expect(picture.bottom, height);
  });

  testWidgets('nothing is drawn over the picture', (tester) async {
    await pump(tester);
    // The picture's gesture detector wraps the picture alone: no text,
    // no icon, no close button lies over it.
    final overPicture = find.ancestor(
      of: find.byKey(pictureKey),
      matching: find.byType(GestureDetector),
    );
    expect(overPicture, findsOneWidget);
    expect(
      find.descendant(of: overPicture, matching: find.byType(Text)),
      findsNothing,
    );
    expect(
      find.descendant(of: overPicture, matching: find.byType(Icon)),
      findsNothing,
    );
  });

  testWidgets('the picture takes a double-click for fullscreen only', (
    tester,
  ) async {
    // Two taps through the test binding do not reach a lone
    // DoubleTapGestureRecognizer in this harness, so the wiring is
    // checked on the detector itself: a double-click handler and no
    // single-click one.
    var toggles = 0;
    await pump(tester, onToggleFullscreen: () => toggles++);
    final detector = tester.widget<GestureDetector>(
      find.ancestor(
        of: find.byKey(pictureKey),
        matching: find.byType(GestureDetector),
      ),
    );
    expect(detector.onTap, isNull);
    expect(detector.onDoubleTap, isNotNull);
    detector.onDoubleTap!();
    expect(toggles, 1);
  });

  testWidgets('a single click on the picture does nothing', (tester) async {
    var toggles = 0;
    await pump(tester, onToggleFullscreen: () => toggles++);
    await tester.tapAt(tester.getCenter(find.byKey(pictureKey)));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
    expect(toggles, 0);
  });

  testWidgets('the chrome recolours after a theme change and rebuild', (
    tester,
  ) async {
    T.setMode(AppThemeMode.dark);
    await pump(tester);
    Color ink() => tester.widget<Text>(inStrip(find.text(title))).style!.color!;
    Color statusInk() => tester.widget<Text>(find.text(readout)).style!.color!;
    final darkInk = ink();
    final darkStatusInk = statusInk();

    // The appearance message sets T and rebuilds the root, which the
    // second pump stands in for here.
    T.setMode(AppThemeMode.light);
    await pump(tester);
    expect(ink(), isNot(darkInk));
    expect(statusInk(), isNot(darkStatusInk));
  }, skip: !hasStrip);

  group('keys (ES-797)', () {
    test('plain presses and Option are consumed', () {
      for (final windows in [false, true]) {
        expect(
          PopoutChrome.keyResult(
            meta: false,
            control: false,
            alt: false,
            windows: windows,
          ),
          KeyEventResult.handled,
        );
      }
      expect(
        PopoutChrome.keyResult(
          meta: false,
          control: false,
          alt: true,
          windows: false,
        ),
        KeyEventResult.handled,
      );
    });

    test('Command and Control chords pass through', () {
      for (final windows in [false, true]) {
        expect(
          PopoutChrome.keyResult(
            meta: true,
            control: false,
            alt: false,
            windows: windows,
          ),
          KeyEventResult.ignored,
        );
        expect(
          PopoutChrome.keyResult(
            meta: false,
            control: true,
            alt: false,
            windows: windows,
          ),
          KeyEventResult.ignored,
        );
      }
    });

    test('Alt chords pass through on Windows', () {
      expect(
        PopoutChrome.keyResult(
          meta: false,
          control: false,
          alt: true,
          windows: true,
        ),
        KeyEventResult.ignored,
      );
    });

    testWidgets('the chrome reports plain key presses as handled', (
      tester,
    ) async {
      await pump(tester);
      for (final key in [
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyA,
      ]) {
        expect(await tester.sendKeyEvent(key), isTrue, reason: '$key');
      }
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA), isTrue);
      expect(await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    });

    testWidgets('Esc in fullscreen leaves fullscreen', (tester) async {
      var leaves = 0;
      await pump(tester, fullscreen: true, onLeaveFullscreen: () => leaves++);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
      expect(leaves, 1);
      // Other keys do nothing in fullscreen either.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyF), isTrue);
      expect(leaves, 1);
    });

    testWidgets('Command+Esc in fullscreen does not leave it', (tester) async {
      var leaves = 0;
      await pump(tester, fullscreen: true, onLeaveFullscreen: () => leaves++);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(leaves, 0);
    });

    testWidgets('Esc in a window does nothing', (tester) async {
      var leaves = 0;
      await pump(tester, onLeaveFullscreen: () => leaves++);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
      expect(leaves, 0);
    });

    testWidgets('the chrome leaves Command chords unhandled', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    });
  });
}

/// A readout that never changes, for the tests that do not drive it.
class _Const extends ValueListenable<String> {
  const _Const(this.value);

  @override
  final String value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
