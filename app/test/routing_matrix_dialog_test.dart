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

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:eclipsa_studio/widgets/routing_matrix_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the Type & Routing dialog's matrix geometry.
void main() {
  AudioElement sceneElement(int order, int channels) => AudioElement(
    id: 1,
    name: 'test',
    type: 'Scene',
    layout: '${order}OA',
    codec: 'WAV 24bit',
    color: 0xFF00FF00,
    ambisonicsOrder: order,
    wavInfo: WavInfo(
      channels: channels,
      sampleRate: 48000,
      bitsPerSample: 24,
      audioFormat: 1,
      dataOffset: 44,
      dataSize: channels * 48000 * 3,
      totalSamples: 48000,
    ),
  );

  Future<void> openDialog(WidgetTester tester, AudioElement element) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRoutingMatrixDialog(
                context: context,
                element: element,
                profile: IamfProfile.baseEnhanced,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('"Source Channels" stays on one line over a narrow matrix', (
    tester,
  ) async {
    // An Object · Mono element with a stereo source spans just two
    // 28px columns — narrower than the label, which used to wrap and
    // clip inside the fixed-height header (ES-455). It must render as a
    // single line, spilling past the span while centered on it.
    await openDialog(
      tester,
      AudioElement(
        id: 1,
        name: 'test',
        type: 'Object',
        layout: 'Mono',
        codec: 'WAV 24bit',
        color: 0xFF00FF00,
        wavInfo: WavInfo(
          channels: 2,
          sampleRate: 48000,
          bitsPerSample: 24,
          audioFormat: 1,
          dataOffset: 44,
          dataSize: 2 * 48000 * 3,
          totalSamples: 48000,
        ),
      ),
    );

    final label = find.text('Source Channels');
    final labelSize = tester.getSize(label);
    expect(
      labelSize.height,
      lessThan(18),
      reason: 'label must not wrap to a second (clipped) line',
    );
    expect(
      labelSize.width,
      greaterThan(2 * 28.0),
      reason: 'label must overflow the 2-column span, not squeeze into it',
    );

    // Centered over the input columns: label center ≈ midpoint of the
    // two column-number headers.
    final col1 = tester.getCenter(find.text('1'));
    final col2 = tester.getCenter(find.text('2'));
    expect(
      (tester.getCenter(label).dx - (col1.dx + col2.dx) / 2).abs(),
      lessThan(1.0),
      reason: 'label must stay centered on the column span',
    );
  });

  testWidgets('"Source Channels" stays centered over a wide matrix', (
    tester,
  ) async {
    // A 5.1 source spans six columns (168px) — wider than the label's
    // natural text width, so the span's tight minWidth stretches the
    // Text box and textAlign (not the OverflowBox alignment) must
    // center the glyphs. Guards the regime the narrow test can't see.
    await openDialog(
      tester,
      AudioElement(
        id: 1,
        name: 'test',
        type: 'Channel',
        layout: '5.1',
        codec: 'WAV 24bit',
        color: 0xFF00FF00,
        wavInfo: WavInfo(
          channels: 6,
          sampleRate: 48000,
          bitsPerSample: 24,
          audioFormat: 1,
          dataOffset: 44,
          dataSize: 6 * 48000 * 3,
          totalSamples: 48000,
        ),
      ),
    );

    // Measure actual glyph paint position, not the layout box: the
    // stretched box is centered by construction, so only the glyph
    // bounds reveal a left-pinned (missing textAlign) regression.
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('Source Channels'),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(
        baseOffset: 0,
        extentOffset: 'Source Channels'.length,
      ),
    );
    final glyphCenterX = paragraph
        .localToGlobal(Offset((boxes.first.left + boxes.last.right) / 2, 0))
        .dx;
    final col1 = tester.getCenter(find.text('1'));
    final col6 = tester.getCenter(find.text('6'));
    expect(
      (glyphCenterX - (col1.dx + col6.dx) / 2).abs(),
      lessThan(1.0),
      reason: 'label glyphs must stay centered on the six-column span',
    );
  });

  testWidgets('rotated axis label centers on the row array', (tester) async {
    await openDialog(tester, sceneElement(2, 9));

    // The label must be intrinsically sized: if layout stretches it to
    // the full column height, its glyphs pin to one end even though the
    // box center still measures as "centered" (the OverflowBox
    // minHeight regression).
    final labelSize = tester.getSize(find.text('2OA'));
    expect(
      labelSize.width,
      lessThan(60),
      reason: 'axis label text must not be stretched to the column height',
    );

    final labelCenter = tester.getCenter(find.text('2OA'));
    final firstRow = tester.getCenter(find.text('ACN 0'));
    final lastRow = tester.getCenter(find.text('ACN 8'));
    final rowsCenterY = (firstRow.dy + lastRow.dy) / 2;

    expect(
      (labelCenter.dy - rowsCenterY).abs(),
      lessThan(1.0),
      reason: 'axis label must be vertically centered on the rows',
    );
  });

  testWidgets('ambisonic order groups are separated by a divider gap', (
    tester,
  ) async {
    await openDialog(tester, sceneElement(3, 16));

    // Rows within an order sit exactly one cell (28px) apart; an order
    // boundary (ACN 3 → ACN 4, ACN 8 → ACN 9) adds the divider gap.
    final acn2 = tester.getCenter(find.text('ACN 2'));
    final acn3 = tester.getCenter(find.text('ACN 3'));
    final acn4 = tester.getCenter(find.text('ACN 4'));
    final acn8 = tester.getCenter(find.text('ACN 8'));
    final acn9 = tester.getCenter(find.text('ACN 9'));

    final withinOrder = acn3.dy - acn2.dy;
    expect(acn4.dy - acn3.dy, greaterThan(withinOrder));
    expect(acn9.dy - acn8.dy, greaterThan(withinOrder));
  });
}
