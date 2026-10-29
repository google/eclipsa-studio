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

// The 3D scene's speaker labels: where sceneLabelPosition places a point
// of the camera's view space, and what SceneLabelOverlay paints.

import 'dart:math' as math;

import 'package:eclipsa_studio/renderer/scene_label_overlay.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _view = Size(800, 600);

Offset? _at(
  double x,
  double y,
  double z, {
  double fovDeg = 90,
  double halfHeight = 0,
  double gap = 0,
}) => sceneLabelPosition(
  viewX: x,
  viewY: y,
  viewZ: z,
  fovDeg: fovDeg,
  near: 0.1,
  far: 100,
  viewSize: _view,
  halfHeight: halfHeight,
  gap: gap,
);

void main() {
  group('sceneLabelPosition', () {
    test('a point on the view axis lands at the centre', () {
      expect(_at(0, 0, -4), const Offset(400, 300));
    });

    test('a point at the edge of the field of view lands on the edge', () {
      // At 90 degrees the frustum's half height equals the depth.
      expect(_at(0, 2, -2), const Offset(400, 0));
      expect(_at(0, -2, -2), const Offset(400, 600));
      // The horizontal scale is the vertical one: square pixels.
      expect(_at(2, 0, -2), const Offset(700, 300));
    });

    test('the label sits below the mesh by its projected half height', () {
      // 0.5 units at depth 2 is a quarter of the 300 px half height.
      expect(_at(0, 0, -2, halfHeight: 0.5, gap: 7), const Offset(400, 382));
      // At depth 5 the half height projects to 30 px.
      expect(_at(0, 0, -5, halfHeight: 0.5, gap: 7), const Offset(400, 337));
    });

    test('follows the field of view', () {
      // Pixels per unit at unit depth for a 60 degree field of view.
      final focal = 300 / math.tan(30 * math.pi / 180);
      expect(_at(0, 1, -1, fovDeg: 60)!.dy, (300 - focal).roundToDouble());
    });

    test('rejects a point outside the depth range', () {
      expect(_at(0, 0, 1), isNull, reason: 'behind the camera');
      expect(_at(0, 0, -0.05), isNull, reason: 'nearer than the near plane');
      expect(_at(0, 0, -200), isNull, reason: 'past the far plane');
    });
  });

  group('SceneLabelOverlay', () {
    tearDown(() => T.setMode(T.defaultMode));

    testWidgets('paints each label centred on its position and repaints', (
      tester,
    ) async {
      final labels = ValueNotifier<List<SceneLabel>>(const [
        SceneLabel('Ltf', Offset(100, 50)),
      ]);
      addTearDown(labels.dispose);
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, r, _) {
                ref = r;
                return SceneLabelOverlay(labels: labels);
              },
            ),
          ),
        ),
      );
      final painter = find.descendant(
        of: find.byType(SceneLabelOverlay),
        matching: find.byType(CustomPaint),
      );
      // Centred: the text's top left is half its size up and left of
      // the label position.
      Offset topLeft(String text, Offset at) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: SceneLabelOverlay.labelStyle()),
          textDirection: TextDirection.ltr,
        )..layout();
        final offset = at - Offset(tp.width / 2, tp.height / 2);
        tp.dispose();
        return offset;
      }

      expect(
        painter,
        paints..paragraph(offset: topLeft('Ltf', const Offset(100, 50))),
      );

      labels.value = const [
        SceneLabel('L', Offset(10, 10)),
        SceneLabel('R', Offset(30, 10)),
      ];
      await tester.pump();
      expect(
        painter,
        paints
          ..paragraph(offset: topLeft('L', const Offset(10, 10)))
          ..paragraph(offset: topLeft('R', const Offset(30, 10))),
      );

      // A theme switch rebuilds the overlay with the new mode.
      final other = AppThemeMode.values.firstWhere((m) => m != T.mode);
      ref.read(themeModeProvider.notifier).set(other);
      await tester.pump();
      expect(painter, paints..paragraph());
    });
  });
}
