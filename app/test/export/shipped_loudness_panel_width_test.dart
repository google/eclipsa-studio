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

// Pins the font-scale safety of the export receipt's shipped-loudness
// grid (ES-621): at every font-size mode, every column header and every
// value cell renders on one line inside its measured column with no
// clipping, and the column grows with the font scale. The seeded row
// prints the widest value the cells show, "-100.00".

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/iamf_export_dialog.dart';
import 'package:eclipsa_studio/theme.dart';

const _rows = [
  ShippedLoudnessRow(
    label: 'Main Mix · Stereo',
    measuredLufs: -100,
    measuredDigitalPeakDbfs: -100,
    measuredTruePeakDbtp: -100,
    shippedLufs: -100,
    shippedDigitalPeakDbfs: -100,
    shippedTruePeakDbtp: -100,
  ),
];

Future<void> _pumpPanel(WidgetTester tester, FontSizeMode mode) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: eclipsaStudioTheme(),
      // Keyed per mode: a const panel would be identical across pumps
      // and skip its rebuild, freezing the first mode's widths.
      home: Scaffold(
        body: ShippedLoudnessPanel(
          key: ValueKey(mode),
          rows: _rows,
          error: null,
        ),
      ),
    ),
  );
}

void _expectFits(WidgetTester tester, String text, FontSizeMode mode) {
  final paragraphs = tester.renderObjectList<RenderParagraph>(find.text(text));
  expect(paragraphs, isNotEmpty, reason: '"$text" must be in the grid');
  for (final p in paragraphs) {
    expect(
      p.textSize.width,
      lessThanOrEqualTo(p.size.width + 0.01),
      reason: '"$text" is clipped by its column at ${mode.label}',
    );
    expect(
      p.textSize.height,
      lessThanOrEqualTo(p.text.style!.fontSize! * 1.6),
      reason: '"$text" wraps to a second line at ${mode.label}',
    );
  }
}

void main() {
  tearDown(() => T.setFontMode(FontSizeMode.medium));

  for (final mode in FontSizeMode.values) {
    testWidgets('every header and value fits its column at ${mode.label}', (
      tester,
    ) async {
      T.setFontMode(mode);
      await _pumpPanel(tester, mode);
      for (final h in ShippedLoudnessPanel.headers) {
        _expectFits(tester, h, mode);
      }
      _expectFits(tester, '-100.00', mode);
      _expectFits(tester, '+0.00', mode);
    });
  }

  testWidgets('the value column tracks the font scale', (tester) async {
    final widths = <FontSizeMode, double>{};
    for (final mode in FontSizeMode.values) {
      T.setFontMode(mode);
      await _pumpPanel(tester, mode);
      widths[mode] = tester.getSize(find.text('PK dBFS')).width;
    }
    expect(widths[FontSizeMode.small], lessThan(widths[FontSizeMode.medium]!));
    expect(widths[FontSizeMode.medium], lessThan(widths[FontSizeMode.large]!));
  });
}
