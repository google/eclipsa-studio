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

import 'dart:ui' as ui;

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/workspace/landing_ground.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dark's landing ground: the flat token pair (bgBase) under a glow
/// centred on the top edge that fades out towards the sides and the
/// bottom.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the glow is brightest at the top centre and bgBase at the '
      'corners', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RepaintBoundary(key: key, child: const LandingGround()),
        ),
      ),
    );
    ProviderScope.containerOf(
      tester.element(find.byType(LandingGround)),
    ).read(themeModeProvider.notifier).set(AppThemeMode.dark);
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int red(int x, int y) => bytes.getUint8((y * image.width + x) * 4);
      final w = image.width, h = image.height;
      final base = (T.bgBase.r * 255).round();
      // The top centre is the gradient's opaque #2F2F2F.
      expect(red(w ~/ 2, 0), closeTo(0x2F, 1));
      // At the ellipse's edge and at the bottom, where the gradient is
      // all but transparent, only bgBase shows.
      expect(red(0, h - 1), base);
      expect(red(w - 1, h - 1), base);
      expect(red(0, 0), base);
      // It falls off from the centre, down and to the sides.
      expect(red(w ~/ 2, h ~/ 2), lessThan(red(w ~/ 2, 0)));
      expect(red(w ~/ 4, 0), lessThan(red(w ~/ 2, 0)));
    });
  });
}
