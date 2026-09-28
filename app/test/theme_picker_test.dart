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
import 'package:eclipsa_studio/widgets/console_widgets.dart';
import 'package:eclipsa_studio/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The Settings picker lists every shipped theme by name, in the
// registry order: Dark first, as the default.
void main() {
  test('every shipped theme is offered, in the registry order', () {
    expect(kThemeOptions.map((o) => o.$2).toList(), [
      'Dark',
      'Light',
      'Classic',
      'High Contrast',
    ]);
  });

  testWidgets('the open menu shows each name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: eclipsaStudioTheme(),
        home: Scaffold(
          body: Center(
            child: ConsoleSelector<AppThemeMode>(
              width: 180,
              value: AppThemeMode.classic,
              items: kThemeOptions,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();

    for (final (_, label) in kThemeOptions) {
      expect(find.text(label), findsWidgets, reason: '$label is not offered');
    }
  });
}
