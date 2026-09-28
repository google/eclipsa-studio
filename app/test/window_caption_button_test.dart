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

import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:eclipsa_studio/widgets/window_titlebar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/window_manager_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(mockWindowManager);

  // The caption buttons are drawn on Windows only.
  testWidgets('a caption button shows the pressed face while held', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowFrameStrip(title: 'Session', onClose: () async {}),
        ),
      ),
    );
    Color? face() => tester
        .widget<Container>(
          find
              .descendant(
                of: find.byTooltip('Minimize'),
                matching: find.byType(Container),
              )
              .first,
        )
        .color;

    expect(face(), Colors.transparent);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Minimize')),
    );
    // The Tooltip's long-press recognizer holds the tap-down until the
    // press timeout (kPressTimeout, 100 ms) runs out.
    await tester.pump(kPressTimeout + const Duration(milliseconds: 10));
    expect(face(), titlebarHoverFace(pressed: true));
    // Dragging off past the tap slop cancels the press.
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(face(), Colors.transparent);
    await gesture.up();
  }, skip: !Platform.isWindows);
}
