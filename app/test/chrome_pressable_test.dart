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

import 'package:eclipsa_studio/widgets/chrome_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ChromePressable's press state must not outlive a disable. A control
// disabled mid-press disposes its tap recognizer, whose cancel fires
// during the rebuild, where setState must not run; didUpdateWidget
// clears the state before build instead.
void main() {
  testWidgets('a press does not survive a disable and re-enable', (
    tester,
  ) async {
    PressableState? last;
    Widget host({required bool enabled}) => MaterialApp(
      home: Center(
        child: ChromePressable(
          onTap: enabled ? () {} : null,
          builder: (context, state) {
            last = state;
            return const SizedBox(
              width: 40,
              height: 40,
              child: ColoredBox(color: Color(0xFF000000)),
            );
          },
        ),
      ),
    );

    await tester.pumpWidget(host(enabled: true));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ChromePressable)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(last!.pressed, isTrue, reason: 'held down');

    await tester.pumpWidget(host(enabled: false));
    expect(last!.pressed, isFalse, reason: 'disabled');

    await tester.pumpWidget(host(enabled: true));
    expect(last!.pressed, isFalse, reason: 'enabled again, pointer held');

    await gesture.up();
    await tester.pump();
    expect(last!.pressed, isFalse, reason: 'released');
  });
}
