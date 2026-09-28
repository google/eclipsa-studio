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

import 'package:eclipsa_studio/widgets/window_titlebar.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/window_manager_mock.dart';

/// The main window's titlebar hands WindowFrameStrip the landing ground
/// while the landing screen shows, and no ground otherwise (ES-744).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(mockWindowManager);

  Future<WindowFrameStrip> pump(
    WidgetTester tester, {
    required bool landing,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [landingVisibleProvider.overrideWithValue(landing)],
        child: const MaterialApp(home: WindowTitlebar()),
      ),
    );
    return tester.widget<WindowFrameStrip>(find.byType(WindowFrameStrip));
  }

  testWidgets('on the landing screen the strip is the page ground', (
    tester,
  ) async {
    final strip = await pump(tester, landing: true);
    expect(strip.ground, isA<SizedBox>());
    expect(strip.title, 'Eclipsa Studio');
  });

  testWidgets('with a workspace the strip draws its own chrome', (
    tester,
  ) async {
    final strip = await pump(tester, landing: false);
    expect(strip.ground, isNull);
  });
}
