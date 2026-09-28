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

// Hermetic tests for computeMixApplication — the pure mapping from a
// selected mix presentation to what the engine gets told: per-element
// applied gains (element + folded sub-mix output gain), the gated
// element set, and the time-varying-gain approximation flags.

import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/playback/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

IamfMixPresentation _mix({
  required List<IamfSubMixInfo> subMixes,
  List<IamfMixElementGain> elements = const [],
}) => IamfMixPresentation(
  id: 1,
  name: 'Test',
  language: 'en',
  loudnessLufs: null,
  truePeakDbtp: null,
  elements: elements,
  layoutType: null,
  soundSystem: null,
  subMixes: subMixes,
);

void main() {
  group('computeMixApplication', () {
    test('folds sub-mix output gain into per-element gains', () {
      final app = computeMixApplication(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 1, defaultGainDb: -3),
                IamfMixElementGain(audioElementId: 2, defaultGainDb: 1.5),
              ],
              outputMixGainDb: -2,
            ),
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 3, defaultGainDb: 0),
              ],
              outputMixGainDb: -6,
            ),
          ],
        ),
        [1, 2, 3],
      );
      expect(app.gainsByElementId, {1: -5.0, 2: -0.5, 3: -6.0});
      expect(app.excludedElementIds, isEmpty);
      expect(app.approximatedElementIds, isEmpty);
    });

    test('gates session elements the presentation omits', () {
      final app = computeMixApplication(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 2, defaultGainDb: 0),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
        [1, 2, 3],
      );
      expect(app.excludedElementIds, {1, 3});
      expect(app.gainsByElementId.keys, [2]);
    });

    test('mix entries absent from the session never enter the gate set', () {
      final app = computeMixApplication(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 9, defaultGainDb: 0),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
        [1],
      );
      expect(app.excludedElementIds, {1});
      // Harmless extra gain for an AE the session doesn't decode.
      expect(app.gainsByElementId.keys, [9]);
    });

    test('flags param-mode-0 element gains as approximated', () {
      final app = computeMixApplication(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(
                  audioElementId: 1,
                  defaultGainDb: 0,
                  paramDefinitionMode: 0,
                ),
                IamfMixElementGain(audioElementId: 2, defaultGainDb: 0),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
        [1, 2],
      );
      expect(app.approximatedElementIds, {1});
    });

    test('a param-mode-0 output gain flags every element of its sub-mix', () {
      final app = computeMixApplication(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 1, defaultGainDb: 0),
                IamfMixElementGain(audioElementId: 2, defaultGainDb: 0),
              ],
              outputMixGainDb: 0,
              outputGainParamDefinitionMode: 0,
            ),
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 3, defaultGainDb: 0),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
        [1, 2, 3],
      );
      expect(app.approximatedElementIds, {1, 2});
    });

    test('falls back to the convenience list when subMixes is empty', () {
      final app = computeMixApplication(
        _mix(
          subMixes: const [],
          elements: const [
            IamfMixElementGain(audioElementId: 1, defaultGainDb: -4),
          ],
        ),
        [1, 2],
      );
      expect(app.gainsByElementId, {1: -4.0});
      expect(app.excludedElementIds, {2});
    });
  });

  group('computeRenderingConfigs', () {
    test('maps probe strings to IAMF spec values', () {
      final configs = computeRenderingConfigs(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(
                  audioElementId: 1,
                  defaultGainDb: 0,
                  headphonesRenderingMode: 'stereo',
                  binauralFilterProfile: 'direct',
                ),
                IamfMixElementGain(
                  audioElementId: 2,
                  defaultGainDb: 0,
                  headphonesRenderingMode: 'binaural_world_locked',
                  binauralFilterProfile: 'ambient',
                ),
                IamfMixElementGain(
                  audioElementId: 3,
                  defaultGainDb: 0,
                  headphonesRenderingMode: 'binaural_head_locked',
                  binauralFilterProfile: 'reverberant',
                ),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
      );
      expect(configs, {
        1: (mode: 0, profile: 1),
        2: (mode: 1, profile: 0),
        3: (mode: 2, profile: 2),
      });
    });

    test('skips references without a probed config', () {
      // No full-probe enrichment → headphonesRenderingMode is null →
      // nothing is staged and the engine keeps OAR's default.
      final configs = computeRenderingConfigs(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(audioElementId: 1, defaultGainDb: 0),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
      );
      expect(configs, isEmpty);
    });

    test('reserved strings fall back to spec-safe defaults', () {
      final configs = computeRenderingConfigs(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(
                  audioElementId: 1,
                  defaultGainDb: 0,
                  headphonesRenderingMode: 'reserved_3',
                  binauralFilterProfile: 'reserved(5)',
                ),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
      );
      // World-locked / ambient — spec-safe, and staging them beats
      // leaving a stale value from the previous presentation.
      expect(configs, {1: (mode: 1, profile: 0)});
    });

    test('later sub-mixes win for duplicate references', () {
      final configs = computeRenderingConfigs(
        _mix(
          subMixes: const [
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(
                  audioElementId: 1,
                  defaultGainDb: 0,
                  headphonesRenderingMode: 'stereo',
                ),
              ],
              outputMixGainDb: 0,
            ),
            IamfSubMixInfo(
              elements: [
                IamfMixElementGain(
                  audioElementId: 1,
                  defaultGainDb: 0,
                  headphonesRenderingMode: 'binaural_world_locked',
                ),
              ],
              outputMixGainDb: 0,
            ),
          ],
        ),
      );
      expect(configs, {1: (mode: 1, profile: 0)});
    });
  });
}
