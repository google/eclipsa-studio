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

// Tooltips wrap at T.tooltipMaxWidth instead of growing to the width
// of the window (the 9.1.6 channel-order note was one line across it).

import 'package:eclipsa_studio/models/layout_916.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a long tooltip wraps at the theme maximum width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final message = layout916OrderTooltip('9.1.6')!;
    await tester.pumpWidget(
      MaterialApp(
        theme: eclipsaStudioTheme(),
        home: Scaffold(
          body: Center(
            child: Tooltip(message: message, child: const Text('hover')),
          ),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(find.text('hover')));
    await tester.pump();
    await tester.pump(T.tooltipWait + const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final text = find.text(message);
    expect(text, findsOneWidget);
    expect(tester.getSize(text).width, lessThanOrEqualTo(T.tooltipMaxWidth));
    await gesture.removePointer();
  });
}
