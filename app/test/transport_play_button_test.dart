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
import 'package:eclipsa_studio/widgets/transport_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The play button is a different widget per chrome style, several of
// them AnimatedContainers. A theme switch rebuilds the button in the
// new style and the AnimatedContainer's state tweens the old style's
// decoration into the new one, so every style's decoration must lerp
// cleanly against every other's: a BoxShape.circle tweened into a
// rounded rectangle carries both a circle shape and a border radius,
// which BoxDecoration rejects. This pumps the button through every
// ordered pair of themes, one frame into the transition, and expects
// no exception.

Widget _app() {
  return ProviderScope(
    child: MaterialApp(
      theme: eclipsaStudioTheme(),
      home: Scaffold(
        body: Center(
          child: TransportPlayButton(
            playing: false,
            onTap: () {},
            disabledTooltip: '',
          ),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('a theme switch does not tween one style into another', (
    tester,
  ) async {
    for (final from in AppThemeMode.values) {
      for (final to in AppThemeMode.values) {
        if (from == to) continue;
        T.setMode(from);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();
        T.setMode(to);
        await tester.pumpWidget(_app());
        // One frame into the transition, where a decoration tween
        // between the two styles would be evaluated.
        await tester.pump(const Duration(milliseconds: 30));
        expect(
          tester.takeException(),
          isNull,
          reason: '${from.name} -> ${to.name}',
        );
        await tester.pumpAndSettle();
      }
    }
  });
}
