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
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/views/elements_view.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:eclipsa_studio/widgets/track_lanes.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The line under an element row runs from the controls panel across
/// the channel-label gutter and the waveform lanes (ES-759).
void main() {
  tearDown(() => T.setMode(T.defaultMode));

  AudioElement elem(int id, {bool wav = false}) => AudioElement(
    id: id,
    name: 'e$id',
    type: 'Channel',
    layout: 'Stereo',
    codec: 'Opus',
    color: 0xFF34D399,
    wavPath: wav ? '/missing/e$id.wav' : null,
    wavInfo: wav
        ? const WavInfo(
            channels: 2,
            sampleRate: 48000,
            bitsPerSample: 24,
            audioFormat: 1,
            dataOffset: 44,
            dataSize: 48000 * 10 * 2 * 3,
            totalSamples: 48000 * 10,
          )
        : null,
  );

  /// The divider box right of the first row's panel.
  final laneDivider = find.byKey(const ValueKey('track_row_divider'));

  Future<void> pumpRows(
    WidgetTester tester,
    AppThemeMode mode, {
    bool wav = false,
  }) async {
    T.setMode(mode);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ElementsView())),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ElementsView)),
    );
    container.read(workspaceModeProvider.notifier).enterCreator();
    container.read(elementsProvider.notifier).set([
      elem(1, wav: wav),
      elem(2, wav: wav),
    ]);
    await tester.pumpAndSettle();
  }

  for (final mode in [
    AppThemeMode.dark,
    AppThemeMode.classic,
    AppThemeMode.highContrast,
  ]) {
    testWidgets('${mode.name}: the divider spans the row, level with the '
        "panel's", (tester) async {
      await pumpRows(tester, mode);
      final panel = tester.getRect(find.byType(TrackPanel).first);
      final lanes = tester.getRect(laneDivider.first);
      final deco =
          tester.widget<DecoratedBox>(laneDivider.first).decoration
              as BoxDecoration;

      expect(deco.border, Border(bottom: trackRowDivider()!));
      expect(lanes.left, panel.right, reason: 'starts where the panel ends');
      expect(lanes.bottom, panel.bottom, reason: "level with the panel's");
      // It reaches the vertical zoom strip, 20 px from the right edge.
      expect(lanes.right, 1400 - 20);
    });
  }

  testWidgets('with a WAV loaded the divider runs under the channel-label '
      'gutter', (tester) async {
    await pumpRows(tester, AppThemeMode.dark, wav: true);
    final panel = tester.getRect(find.byType(TrackPanel).first);
    final lanes = tester.getRect(laneDivider.first);
    final gutter = tester.getRect(find.byType(ChannelLabelCell).first);

    expect(gutter.width, greaterThan(0), reason: 'the gutter is built');
    expect(lanes.left, panel.right);
    expect(lanes.left, lessThanOrEqualTo(gutter.left));
    expect(lanes.right, greaterThan(gutter.right));
    expect(lanes.bottom, panel.bottom);
  });

  testWidgets('light: no divider, the panels are cards', (tester) async {
    await pumpRows(tester, AppThemeMode.light);
    expect(trackRowDivider(), isNull);
    final deco =
        tester.widget<DecoratedBox>(laneDivider.first).decoration
            as BoxDecoration;
    expect(deco.border, isNull);
  });
}
