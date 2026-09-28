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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A closed dropdown must have an edge on a dialog, whose ground is
// bgElevated: either its fill differs from that ground or its rim is
// drawn. In Dark and Light controlBg equals bgElevated, so the rim
// carries the edge there.
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  for (final mode in AppThemeMode.values) {
    test('${mode.name}: the closed control has an edge on a dialog', () {
      T.setMode(mode);
      final d = SelectorChrome.decoration(hover: false, dim: 1);
      final fillDiffers = d.color != null && d.color != T.bgElevated;
      final side = (d.border as Border?)?.top;
      final rimDrawn =
          side != null &&
          side.width > 0 &&
          side.color.a > 0 &&
          side.color != T.bgElevated;
      expect(
        fillDiffers || rimDrawn,
        isTrue,
        reason: '${kThemeMeta[mode]!.label}: fill ${d.color}, rim $side',
      );
    });
  }

  test('the filled control rests on a border rim and lifts on hover', () {
    T.setMode(AppThemeMode.dark);
    expect(T.controlStyle, ControlStyle.filled);
    final rest = SelectorChrome.decoration(hover: false, dim: 1);
    final hover = SelectorChrome.decoration(hover: true, dim: 1);
    expect((rest.border! as Border).top.color, T.border);
    expect(
      (hover.border! as Border).top.color,
      T.controlFg.withValues(alpha: 0.25),
    );
  });
}
