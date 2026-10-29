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

import 'dart:typed_data';

import 'package:eclipsa_studio/renderer/element_stats.dart';
import 'package:eclipsa_studio/renderer/modules/wavefronts.dart';
import 'package:eclipsa_studio/renderer/speaker_layout.dart';
import 'package:eclipsa_studio/renderer/viz_layer.dart';
import 'package:eclipsa_studio/renderer/viz_module.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stats for [channels] channels with an onset and full energy on the
/// channels in [onsets].
ElementStats _stats(int channels, {Set<int> onsets = const {}}) {
  final energy = Float32List(channels);
  final onset = Uint8List(channels);
  for (final c in onsets) {
    energy[c] = 1;
    onset[c] = 1;
  }
  return ElementStats(
    channelCount: channels,
    energy: energy,
    cohLo: Float32List(channels),
    cohMid: Float32List(channels),
    cohHi: Float32List(channels),
    onset: onset,
    corr: Float32List(0),
  );
}

ChannelVizInput _frame(SpeakerLayout layout, ElementStats stats) {
  final element = AudioElement(
    id: 7,
    name: 'Bed',
    type: 'Channel',
    layout: layout.name,
    codec: 'WAV 24bit',
    color: 0xFF336699,
  );
  return ChannelVizInput(
    elements: [
      ChannelVizElement(
        element: element,
        layout: layout,
        peaks: List<double>.filled(stats.channelCount, 0),
        stats: stats,
      ),
    ],
    timeSec: 0,
    dtSec: 0.1,
  );
}

void main() {
  test('an element whose channel count rises keeps emitting pulses', () {
    final module = WavefrontsModule();
    final params = VizParamValues(const {}, module.params);

    // Stereo first, then 5.1 for the same element id: an 8-channel WAV
    // routed as Stereo and then as 5.1.
    module.build(_frame(SpeakerLayout.stereo, _stats(2)), params);
    final layers = module.build(
      _frame(SpeakerLayout.layout51, _stats(6, onsets: {4})),
      params,
    );

    final pulses = [
      for (final layer in layers.whereType<WavefrontLayer>()) ...layer.pulses,
    ];
    expect(pulses, hasLength(1), reason: 'one pulse from Ls (channel 4)');
  });
}
