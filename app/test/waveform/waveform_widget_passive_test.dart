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

// Regression test for ES-549: WaveformWidget must stay a passive
// renderer. The original bug was a widget-private GestureDetector
// whose scale/drag recognizers claimed trackpad pinches and pans (via
// PointerPanZoom opt-in) and zoomed/panned one channel row out of
// sync with the shared timeline viewport. Zoom and pan must come only
// from the parent's geometry, so the widget's subtree must contain no
// gesture recognizers at all.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/waveform/peak_cache.dart';
import 'package:eclipsa_studio/waveform/peak_data.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:eclipsa_studio/waveform/waveform_painter.dart';
import 'package:eclipsa_studio/waveform/waveform_widget.dart';

/// Serves canned pyramids without the engine's peak isolate.
class _FakePeakCache extends PeakCache {
  final List<PeakPyramid> pyramids;

  _FakePeakCache(this.pyramids);

  @override
  Future<List<PeakPyramid>> getPeaks(String wavPath) async => pyramids;
}

ChannelPeaks _peaks(int bins) => ChannelPeaks(
  mins: Float32List.fromList(List.filled(bins, -0.5)),
  maxs: Float32List.fromList(List.filled(bins, 0.5)),
  rms: Float32List.fromList(List.filled(bins, 0.3)),
  samplesPerPeak: 256,
  channelIndex: 0,
);

void main() {
  tearDown(() => WavDecoder.probeForTesting = null);

  testWidgets('loaded waveform subtree contains no gesture recognizers', (
    tester,
  ) async {
    WavDecoder.probeForTesting = (_) => jsonEncode({
      'ok': true,
      'container': 'riff',
      'channels': 1,
      'sample_rate': 48000,
      'bits_per_sample': 16,
      'is_float': false,
      'num_frames': 256 * 64,
      'data_offset': 44,
      'data_size': 256 * 64 * 2,
      'axml_bytes': 0,
      'chna_bytes': 0,
    });
    final cache = _FakePeakCache([
      PeakPyramid([_peaks(64)]),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WaveformWidget(filePath: 'x.wav', cache: cache),
        ),
      ),
    );
    // The load is async; the shimmer controller repeats forever, so
    // pumpAndSettle would never settle — pump fixed frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Guard against trivially passing on the shimmer/error branches:
    // the peaks painter must actually be in the tree.
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is WaveformPainter,
      ),
      findsOneWidget,
    );

    // The ES-549 invariant: no recognizers under the widget — neither a
    // GestureDetector nor anything lower-level that could enter the
    // gesture arena and claim pinches/pans from the timeline.
    final subtree = find.byType(WaveformWidget);
    expect(
      find.descendant(of: subtree, matching: find.byType(GestureDetector)),
      findsNothing,
    );
    expect(
      find.descendant(of: subtree, matching: find.byType(RawGestureDetector)),
      findsNothing,
    );
  });
}
