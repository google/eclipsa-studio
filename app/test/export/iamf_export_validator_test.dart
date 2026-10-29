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

import 'package:eclipsa_studio/export/iamf_export_config.dart';
import 'package:eclipsa_studio/export/iamf_export_validator.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart'
    show BinauralProfile;
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/waveform/waveform.dart' show WavInfo;
import 'package:flutter_test/flutter_test.dart';

// Small fixture helpers so each test stays focused on what it verifies.

AudioElement _channelElement({
  required int id,
  String name = 'Bed',
  String layout = 'Stereo',
  String codec = 'LPCM',
  String? wavPath = '/tmp/fixture.wav',
  WavInfo? wavInfo,
}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Channel',
    layout: layout,
    codec: codec,
    color: 0xFF000000,
    wavPath: wavPath,
    wavInfo: wavInfo,
  );
}

AudioElement _objectElement({required int id, String name = 'Obj'}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Object',
    layout: 'Mono',
    codec: 'LPCM',
    color: 0xFF000000,
    wavPath: '/tmp/obj.wav',
  );
}

AudioElement _sceneElement({
  required int id,
  int order = 3,
  String name = 'Scene',
}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Scene',
    layout: '${order}OA',
    codec: 'LPCM',
    color: 0xFF000000,
    ambisonicsOrder: order,
    wavPath: '/tmp/scene.wav',
  );
}

Mix _mix({
  int id = 1,
  String name = 'Main',
  List<MixLayout>? layouts,
  List<SubMix>? subMixes,
}) {
  return Mix(
    id: id,
    name: name,
    subMixes:
        subMixes ??
        [
          SubMix(
            layouts:
                layouts ??
                const [
                  MixLayout(
                    soundSystem: SoundSystem.stereo,
                    loudness: LoudnessInfo(integratedLoudness: -18.0),
                  ),
                ],
          ),
        ],
  );
}

IamfExportConfig _config({
  IamfProfile profile = IamfProfile.baseEnhanced,
  IamfCodec codec = IamfCodec.lpcm,
  List<AudioElement>? elements,
  List<Mix>? mixes,
}) {
  return IamfExportConfig(
    profile: profile,
    sampleRate: 48000,
    codec: codec,
    framesPerCodedBlock: codec == IamfCodec.opus
        ? kOpusFramesPerCodedBlock
        : kDefaultFramesPerCodedBlock,
    elements: elements ?? [_channelElement(id: 1)],
    mixes: mixes ?? [_mix()],
    wavBasenames: const {1: 'fixture.wav'},
    outputPath: '/tmp/out.iamf',
  );
}

void main() {
  group('validateIamfExport — session shape', () {
    test('empty elements is an error', () {
      final r = validateIamfExport(_config(elements: []));
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.sessionNoElements),
      );
    });

    test('empty mixes is an error', () {
      final r = validateIamfExport(_config(mixes: []));
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.sessionNoMixes),
      );
    });

    test('stereo-only session passes with no errors', () {
      final r = validateIamfExport(_config());
      expect(r.canExport, isTrue);
      expect(r.errors, isEmpty);
    });
  });

  group('validateIamfExport — profile capacity', () {
    test('Simple profile rejects 2 elements', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.simple,
          elements: [
            _channelElement(id: 1, layout: 'Stereo'),
            _channelElement(id: 2, layout: 'Stereo'),
          ],
        ),
      );
      expect(r.canExport, isFalse);
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileTooManyElements),
      );
    });

    test('Base profile rejects 19 channels', () {
      // Base allows 18 channels. Two 9.1.6 (16ch) elements = 32 channels.
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [
            _channelElement(id: 1, layout: '9.1.6'),
            _channelElement(id: 2, layout: '9.1.6'),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileTooManyChannels),
      );
    });

    test('Base-Enhanced rejects object element (iamf-tools rule)', () {
      // iamf-tools' profile_filter.cc excludes Base-Enhanced from objects,
      // matching IamfProfile.allowObjectBased=false for Base-Enhanced. The
      // validator enforces this independently at export time.
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseEnhanced,
          elements: [_objectElement(id: 1)],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileObjectsNotAllowed),
      );
    });

    test('Base-Advanced accepts object element', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseAdvanced,
          elements: [_objectElement(id: 1)],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileObjectsNotAllowed)),
      );
    });

    test('Base rejects mixed channel + scene types', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [
            _channelElement(id: 1, layout: 'Stereo'),
            _sceneElement(id: 2, order: 1),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileMixedTypesNotAllowed),
      );
    });

    test('Base-Advanced rejects object + channel in one mix', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseAdvanced,
          elements: [
            _objectElement(id: 1),
            _channelElement(id: 2, layout: 'Stereo'),
          ],
          mixes: [
            _mix(
              subMixes: [
                const SubMix(
                  layouts: [
                    MixLayout(
                      soundSystem: SoundSystem.stereo,
                      loudness: LoudnessInfo(integratedLoudness: -18.0),
                    ),
                  ],
                  elementSettings: [
                    MixElementSettings(elementId: 1),
                    MixElementSettings(elementId: 2),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileObjectMixedWithOtherTypes),
      );
    });

    test('Base-Advanced rejects a channel mix before an object mix', () {
      SubMix subMix(int elementId) => SubMix(
        layouts: const [
          MixLayout(
            soundSystem: SoundSystem.stereo,
            loudness: LoudnessInfo(integratedLoudness: -18.0),
          ),
        ],
        elementSettings: [MixElementSettings(elementId: elementId)],
      );
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseAdvanced,
          elements: [
            _objectElement(id: 1),
            _channelElement(id: 2, layout: 'Stereo'),
          ],
          mixes: [
            _mix(id: 1, name: 'Bed', subMixes: [subMix(2)]),
            _mix(id: 2, name: 'Objects', subMixes: [subMix(1)]),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileFirstMixNotObjectOnly),
      );
    });

    test('Base-Enhanced allows mixed types', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseEnhanced,
          elements: [
            _channelElement(id: 1, layout: 'Stereo'),
            _sceneElement(id: 2, order: 1),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileMixedTypesNotAllowed)),
      );
    });

    test('Simple profile rejects 2 sub-mixes', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.simple,
          mixes: [
            Mix(id: 1, name: 'Main', subMixes: const [SubMix(), SubMix()]),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileTooManySubMixes),
      );
    });

    test('Base-Advanced allows 2 sub-mixes', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseAdvanced,
          mixes: [
            Mix(id: 1, name: 'Main', subMixes: const [SubMix(), SubMix()]),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileTooManySubMixes)),
      );
    });
  });

  group('validateIamfExport — element shape', () {
    test('element with no WAV is an error', () {
      final r = validateIamfExport(
        _config(elements: [_channelElement(id: 1, wavPath: null)]),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.elementMissingWav),
      );
    });

    test('Custom(Nch) layout is unmappable for now', () {
      final r = validateIamfExport(
        _config(elements: [_channelElement(id: 1, layout: 'Custom(5ch)')]),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.elementLayoutUnmappable),
      );
    });

    test('9.1.6 (supported expanded layout) is mappable', () {
      final r = validateIamfExport(
        _config(elements: [_channelElement(id: 1, layout: '9.1.6')]),
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.elementLayoutUnmappable)),
      );
    });

    test('7.1.5.4 (unsupported expanded layout) is blocked pre-flight', () {
      // Channel count maps (16ch), but it has no render/label support yet —
      // the validator must block it before the bounce so the builder never
      // throws mid-export. Keeps validator and builder in lockstep.
      final r = validateIamfExport(
        _config(elements: [_channelElement(id: 1, layout: '7.1.5.4')]),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.elementLayoutUnmappable),
      );
    });

    test('WAV channel-count mismatch warns (does not block)', () {
      final r = validateIamfExport(
        _config(
          elements: [
            _channelElement(
              id: 1,
              layout: 'Stereo',
              wavInfo: const WavInfo(
                channels: 6,
                sampleRate: 48000,
                bitsPerSample: 24,
                audioFormat: 1,
                dataOffset: 44,
                dataSize: 18000,
                totalSamples: 1000,
              ),
            ),
          ],
        ),
      );
      expect(r.canExport, isTrue);
      expect(
        r.warnings.map((i) => i.code),
        contains(ExportIssueCode.elementChannelMismatch),
      );
    });
  });

  group('validateIamfExport — loudness', () {
    test('unmeasured integrated loudness no longer produces a warning', () {
      // Loudness is auto-measured during export (via
      // runMixMeasureOnIsolate in iamf_export_dialog.dart's
      // _measureLoudness pass), so a 0 LUFS
      // sentinel in the pre-export config is not a user-actionable issue.
      final r = validateIamfExport(
        _config(
          mixes: [
            _mix(
              layouts: const [
                MixLayout(
                  soundSystem: SoundSystem.stereo,
                  loudness: LoudnessInfo(),
                ),
              ],
            ),
          ],
        ),
      );
      expect(r.canExport, isTrue);
      expect(r.warnings, isEmpty);
    });
  });

  // Gap H (ES-156 Phase 5): the validator now delegates to the rule engine, so
  // it catches the categories the old hand-rolled checks missed — expanded
  // element layouts, mix output layouts, headphones mode and binaural filter
  // below the profile that permits them. These are the backstop for loaded /
  // older sessions and any UI-bypass.
  group('validateIamfExport — profile parity (gap H)', () {
    // A mix whose single sub-mix includes [elementId] with the given
    // per-element rendering settings, plus a stereo output layout.
    Mix mixWithRef({
      required int elementId,
      HeadphonesRenderingMode headphonesMode =
          HeadphonesRenderingMode.binauralWorldLocked,
      BinauralProfile binauralProfile = BinauralProfile.ambient,
      SoundSystem layout = SoundSystem.stereo,
    }) {
      return Mix(
        id: 1,
        name: 'Main',
        subMixes: [
          SubMix(
            elementSettings: [
              MixElementSettings(
                elementId: elementId,
                headphonesMode: headphonesMode,
                binauralProfile: binauralProfile,
              ),
            ],
            layouts: [MixLayout(soundSystem: layout)],
          ),
        ],
      );
    }

    test('expanded element layout (9.1.6) is rejected under Base', () {
      // 9.1.6 needs v1.1 (Base-Enhanced+); a single one fits Base's channel
      // budget, so only the layout filter catches it.
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [_channelElement(id: 1, layout: '9.1.6')],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileElementLayoutNotAllowed),
      );
    });

    test('expanded mix output layout (9.1.6) is rejected under Base', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [_channelElement(id: 1)],
          mixes: [
            _mix(
              layouts: const [
                MixLayout(soundSystem: SoundSystem.surround9_1_6),
              ],
            ),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileMixLayoutNotAllowed),
      );
    });

    test('head-locked headphones mode is rejected below Base-Advanced', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [_channelElement(id: 1)],
          mixes: [
            mixWithRef(
              elementId: 1,
              headphonesMode: HeadphonesRenderingMode.binauralHeadLocked,
            ),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileHeadphonesModeNotAllowed),
      );
    });

    test('binaural filter profile is rejected below Base-Advanced', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [_channelElement(id: 1)],
          mixes: [
            mixWithRef(elementId: 1, binauralProfile: BinauralProfile.direct),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileBinauralFilterNotAllowed),
      );
    });

    test('Base-Advanced permits head-locked + binaural filter + 9.1.6', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseAdvanced,
          elements: [_channelElement(id: 1, layout: '9.1.6')],
          mixes: [
            mixWithRef(
              elementId: 1,
              headphonesMode: HeadphonesRenderingMode.binauralHeadLocked,
              binauralProfile: BinauralProfile.direct,
              layout: SoundSystem.surround9_1_6,
            ),
          ],
        ),
      );
      const gated = [
        ExportIssueCode.profileElementLayoutNotAllowed,
        ExportIssueCode.profileMixLayoutNotAllowed,
        ExportIssueCode.profileHeadphonesModeNotAllowed,
        ExportIssueCode.profileBinauralFilterNotAllowed,
      ];
      expect(r.errors.map((i) => i.code), isNot(anyElement(isIn(gated))));
    });
  });

  group('validateIamfExport — codec configs (gap I)', () {
    test('two distinct codecs exceed Base (1 codec config)', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          elements: [
            _channelElement(id: 1, codec: 'LPCM'),
            _channelElement(id: 2, codec: 'Opus'),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileTooManyCodecConfigs),
      );
    });

    test('Opus export collapses mixed sources to one codec config', () {
      // Opus transcodes every element, so mixed source codecs and bit
      // depths — which would need 2 configs under LPCM — dedupe to the
      // single shared Opus config and fit Base (1 codec config).
      WavInfo wavInfo(int bits) => WavInfo(
        channels: 2,
        sampleRate: 48000,
        bitsPerSample: bits,
        audioFormat: 1,
        dataOffset: 44,
        dataSize: 12000 * bits ~/ 8,
        totalSamples: 6000,
      );
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.base,
          codec: IamfCodec.opus,
          elements: [
            _channelElement(id: 1, codec: 'LPCM', wavInfo: wavInfo(16)),
            _channelElement(id: 2, codec: 'Opus', wavInfo: wavInfo(24)),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileTooManyCodecConfigs)),
      );
    });

    test('two distinct codecs fit Base-Advanced (2 codec configs)', () {
      final r = validateIamfExport(
        _config(
          profile: IamfProfile.baseAdvanced,
          elements: [
            _channelElement(id: 1, codec: 'LPCM'),
            _channelElement(id: 2, codec: 'Opus'),
          ],
        ),
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileTooManyCodecConfigs)),
      );
    });
  });

  group('validateIamfExport — MP4 mux target', () {
    test('MP4 target rejects a draft profile (Advanced-2)', () {
      final r = validateIamfExport(
        _config(profile: IamfProfile.advanced2),
        muxToMp4: true,
      );
      expect(r.canExport, isFalse);
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileCannotMuxToMp4),
      );
    });

    test('MP4 target rejects Base-Advanced (first draft profile)', () {
      final r = validateIamfExport(
        _config(profile: IamfProfile.baseAdvanced),
        muxToMp4: true,
      );
      expect(
        r.errors.map((i) => i.code),
        contains(ExportIssueCode.profileCannotMuxToMp4),
      );
    });

    test('MP4 target allows Base-Enhanced (highest muxable profile)', () {
      final r = validateIamfExport(
        _config(profile: IamfProfile.baseEnhanced),
        muxToMp4: true,
      );
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileCannotMuxToMp4)),
      );
    });

    test('IAMF-only export permits a draft profile', () {
      // Bare .iamf has no mux step, so draft profiles are fine. muxToMp4
      // defaults to false.
      final r = validateIamfExport(_config(profile: IamfProfile.advanced2));
      expect(
        r.errors.map((i) => i.code),
        isNot(contains(ExportIssueCode.profileCannotMuxToMp4)),
      );
    });
  });

  group('channelCountForLayout', () {
    test('covers common channel layouts', () {
      expect(channelCountForLayout(_channelElement(id: 1, layout: 'Mono')), 1);
      expect(
        channelCountForLayout(_channelElement(id: 1, layout: 'Stereo')),
        2,
      );
      expect(channelCountForLayout(_channelElement(id: 1, layout: '5.1')), 6);
      expect(
        channelCountForLayout(_channelElement(id: 1, layout: '7.1.4')),
        12,
      );
      expect(
        channelCountForLayout(_channelElement(id: 1, layout: '9.1.6')),
        16,
      );
    });

    test('ambisonics orders', () {
      expect(channelCountForLayout(_sceneElement(id: 1, order: 1)), 4);
      expect(channelCountForLayout(_sceneElement(id: 1, order: 2)), 9);
      expect(channelCountForLayout(_sceneElement(id: 1, order: 3)), 16);
      expect(channelCountForLayout(_sceneElement(id: 1, order: 4)), 25);
    });

    test('object mono vs dual', () {
      expect(channelCountForLayout(_objectElement(id: 1)), 1);
      final dual = AudioElement(
        id: 2,
        name: 'D',
        type: 'Object',
        layout: 'Mono',
        codec: 'LPCM',
        color: 0xFF000000,
        isDual: true,
      );
      expect(channelCountForLayout(dual), 2);
    });
  });
}
