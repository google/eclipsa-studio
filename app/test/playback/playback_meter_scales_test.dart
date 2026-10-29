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

// Hermetic tests for the pure renderer-level helpers on the playback
// session: computeMixMeterScales (ES-294), the per-element linear
// factors the tick loop folds into the scene/sidebar levels so they
// reflect the selected presentation's mix gains (which the engine
// applies after the per-element meter tap), and
// playbackOutputMixGainReadout (ES-293), the resolution behind the
// renderer view's read-only output mix gain footer.

import 'dart:math' as math;

import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/playback/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

IamfMixPresentation _presentation(List<IamfSubMixInfo> subMixes) =>
    IamfMixPresentation(
      id: 1,
      name: 'test',
      language: null,
      loudnessLufs: null,
      truePeakDbtp: null,
      elements: subMixes.isEmpty ? const [] : subMixes.first.elements,
      layoutType: null,
      soundSystem: null,
      subMixes: subMixes,
    );

double _lin(double db) => math.pow(10, db / 20).toDouble();

PlaybackSession _session(
  List<IamfMixPresentation> mixPresentations, {
  int? activeMixIndex,
}) => PlaybackSession(
  path: '/tmp/test.iamf',
  report: IamfProbeReport(
    ok: true,
    errorMessage: null,
    sampleRate: 48000,
    totalSamples: 0,
    audioElements: const [],
    mixPresentations: mixPresentations,
  ),
  activeMixIndex: activeMixIndex ?? (mixPresentations.isEmpty ? -1 : 0),
  sampleRate: 48000,
  totalFrames: 0,
  audioElements: const [],
);

void main() {
  test('null mix means unity for every slot', () {
    expect(computeMixMeterScales(null, [11, 12, 13]), [1.0, 1.0, 1.0]);
  });

  test('folds per-element gain with the sub-mix output gain', () {
    final mix = _presentation([
      const IamfSubMixInfo(
        elements: [
          IamfMixElementGain(audioElementId: 11, defaultGainDb: -6),
          IamfMixElementGain(audioElementId: 12, defaultGainDb: 3),
        ],
        outputMixGainDb: -2,
      ),
    ]);
    final scales = computeMixMeterScales(mix, [11, 12]);
    expect(scales[0], closeTo(_lin(-8), 1e-12));
    expect(scales[1], closeTo(_lin(1), 1e-12));
  });

  test('all-zero gains stay exactly at unity', () {
    final mix = _presentation([
      const IamfSubMixInfo(
        elements: [IamfMixElementGain(audioElementId: 11, defaultGainDb: 0)],
        outputMixGainDb: 0,
      ),
    ]);
    expect(computeMixMeterScales(mix, [11]), [1.0]);
  });

  test('excluded elements get unity (engine gates them to silence)', () {
    final mix = _presentation([
      const IamfSubMixInfo(
        elements: [IamfMixElementGain(audioElementId: 11, defaultGainDb: -6)],
        outputMixGainDb: 0,
      ),
    ]);
    final scales = computeMixMeterScales(mix, [11, 99]);
    expect(scales[0], closeTo(_lin(-6), 1e-12));
    expect(scales[1], 1.0);
  });

  test('multi-sub-mix presentations fold each sub-mix output gain', () {
    final mix = _presentation([
      const IamfSubMixInfo(
        elements: [IamfMixElementGain(audioElementId: 11, defaultGainDb: 0)],
        outputMixGainDb: -3,
      ),
      const IamfSubMixInfo(
        elements: [IamfMixElementGain(audioElementId: 12, defaultGainDb: -1)],
        outputMixGainDb: 6,
      ),
    ]);
    final scales = computeMixMeterScales(mix, [11, 12]);
    expect(scales[0], closeTo(_lin(-3), 1e-12));
    expect(scales[1], closeTo(_lin(5), 1e-12));
  });

  test('falls back to the convenience element list when subMixes is '
      'empty (no output gain to fold)', () {
    final mix = IamfMixPresentation(
      id: 1,
      name: 'unenriched',
      language: null,
      loudnessLufs: null,
      truePeakDbtp: null,
      elements: const [
        IamfMixElementGain(audioElementId: 11, defaultGainDb: -6),
      ],
      layoutType: null,
      soundSystem: null,
    );
    expect(computeMixMeterScales(mix, [11]), [closeTo(_lin(-6), 1e-12)]);
  });

  group('playbackOutputMixGainReadout', () {
    const sub3 = IamfSubMixInfo(elements: [], outputMixGainDb: -3);
    const sub6 = IamfSubMixInfo(elements: [], outputMixGainDb: 6);

    test('hidden without a session', () {
      expect(playbackOutputMixGainReadout(null).show, isFalse);
    });

    test('hidden when the file carries no presentations', () {
      expect(playbackOutputMixGainReadout(_session(const [])).show, isFalse);
    });

    test('hidden when the presentation has no sub-mixes', () {
      final s = _session([_presentation(const [])]);
      expect(playbackOutputMixGainReadout(s).show, isFalse);
    });

    test('single sub-mix shows its output gain', () {
      final s = _session([
        _presentation(const [sub3]),
      ]);
      expect(playbackOutputMixGainReadout(s), (show: true, gainDb: -3.0));
    });

    test('agreeing sub-mixes show the shared value', () {
      final s = _session([
        _presentation(const [sub3, sub3]),
      ]);
      expect(playbackOutputMixGainReadout(s), (show: true, gainDb: -3.0));
    });

    test('disagreeing sub-mixes show no single value', () {
      final s = _session([
        _presentation(const [sub3, sub6]),
      ]);
      expect(playbackOutputMixGainReadout(s), (show: true, gainDb: null));
    });

    test('follows the selected presentation index', () {
      final s = _session([
        _presentation(const [sub3]),
        _presentation(const [sub6]),
      ], activeMixIndex: 1);
      expect(playbackOutputMixGainReadout(s), (show: true, gainDb: 6.0));
    });
  });

  // The Renderer view's Playback cards show each element's mix gain
  // beside the output mix gain footer. The element figures must not
  // include the sub-mix output gain, and the footer must not include
  // any element gain (ES-1006).
  test('elementMixGainsDb leaves out the sub-mix output gain', () {
    final mix = _presentation([
      const IamfSubMixInfo(
        elements: [
          IamfMixElementGain(audioElementId: 11, defaultGainDb: -3),
          IamfMixElementGain(audioElementId: 12, defaultGainDb: 2),
        ],
        outputMixGainDb: -6,
      ),
      const IamfSubMixInfo(
        elements: [IamfMixElementGain(audioElementId: 13, defaultGainDb: 0)],
        outputMixGainDb: 4,
      ),
    ]);
    expect(elementMixGainsDb(mix), {11: -3.0, 12: 2.0, 13: 0.0});
    // The engine still applies the two folded.
    expect(computeMixApplication(mix, [11, 12, 13]).gainsByElementId, {
      11: -9.0,
      12: -4.0,
      13: 4.0,
    });
  });
}
