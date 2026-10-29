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

// The QC Loudness Report's plan (ES-520): probe layout strings to
// SoundSystem, the rows planned for a probe report (tagged layouts, the
// monitoring layout, stored values, not-measurable reasons), and the
// pass each row dispatches with the runner injected (no engine dylib).

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/iamf_measure_isolate.dart';
import 'package:eclipsa_studio/loudness/iamf_measure_isolate.dart';
import 'package:eclipsa_studio/loudness/loudness_measurement.dart';
import 'package:eclipsa_studio/loudness/qc_loudness_measurement.dart';
import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/state.dart';

IamfAe _ae(
  int id, {
  bool renderable = true,
  IamfAeSkipReason skipReason = IamfAeSkipReason.none,
}) => IamfAe(
  id: id,
  layoutLabel: 'Stereo',
  ambisonicsOrder: -1,
  numChannels: 2,
  renderable: renderable,
  skipReason: skipReason,
);

IamfSubMixLayout _layout(
  String soundSystem, {
  double integrated = -18,
  double? digitalPeak = -3,
  double? truePeak = -2.5,
  String layoutType = 'loudspeakers_ss_convention',
}) => IamfSubMixLayout(
  layoutType: layoutType,
  soundSystem: soundSystem,
  integratedLoudnessLufs: integrated,
  digitalPeakDbfs: digitalPeak,
  truePeakDbtp: truePeak,
);

IamfMixPresentation _mix(
  int id, {
  String? name,
  required List<IamfSubMixInfo> subMixes,
}) => IamfMixPresentation(
  id: id,
  name: name,
  language: 'en',
  loudnessLufs: null,
  truePeakDbtp: null,
  elements: subMixes.first.elements,
  layoutType: null,
  soundSystem: null,
  subMixes: subMixes,
);

IamfProbeReport _report({
  required List<IamfAe> aes,
  required List<IamfMixPresentation> mixes,
}) => IamfProbeReport(
  ok: true,
  errorMessage: null,
  sampleRate: 48000,
  totalSamples: 48000,
  audioElements: aes,
  mixPresentations: mixes,
);

const MixMeasureResult _kScalars = (
  integratedLufs: -19.5,
  truePeakDbtp: -1.0,
  digitalPeakDbfs: -1.0,
);

/// One recorded runPass invocation.
class _Pass {
  final String path;
  final int oarLayout;
  final double outputMixGainDb;
  final List<IamfMeasureElement> elements;
  _Pass(this.path, this.oarLayout, this.outputMixGainDb, this.elements);
}

void main() {
  group('soundSystemForProbeLayout', () {
    test('maps the probe names to SoundSystem', () {
      expect(
        soundSystemForProbeLayout(
          layoutType: 'loudspeakers_ss_convention',
          soundSystem: 'Stereo',
        ),
        SoundSystem.stereo,
      );
      expect(
        soundSystemForProbeLayout(
          layoutType: 'loudspeakers_ss_convention',
          soundSystem: '7.1.4',
        ),
        SoundSystem.surround7_1_4,
      );
      expect(
        soundSystemForProbeLayout(
          layoutType: 'loudspeakers_ss_convention',
          soundSystem: '22.2',
        ),
        SoundSystem.surround10_2_9_3,
      );
      expect(
        soundSystemForProbeLayout(layoutType: 'binaural'),
        SoundSystem.binaural,
      );
    });

    test('returns null for layouts without a SoundSystem', () {
      for (final name in ['5+4+1', '3+7+0', '9.1.4', 'reserved(14)']) {
        expect(
          soundSystemForProbeLayout(
            layoutType: 'loudspeakers_ss_convention',
            soundSystem: name,
          ),
          isNull,
          reason: name,
        );
      }
      expect(soundSystemForProbeLayout(layoutType: 'reserved(2)'), isNull);
      expect(
        soundSystemForProbeLayout(layoutType: 'loudspeakers_ss_convention'),
        isNull,
      );
    });
  });

  group('planQcLoudnessRows', () {
    final report = _report(
      aes: [_ae(300), _ae(301)],
      mixes: [
        _mix(
          400,
          name: 'Main',
          subMixes: [
            IamfSubMixInfo(
              elements: const [
                IamfMixElementGain(audioElementId: 300, defaultGainDb: -3),
                IamfMixElementGain(audioElementId: 301, defaultGainDb: 0),
              ],
              outputMixGainDb: -1.5,
              layouts: [
                _layout('Stereo', integrated: -19.53, truePeak: 2.32),
                _layout('7.1.4', integrated: -20.1, truePeak: null),
              ],
            ),
          ],
        ),
        _mix(
          401,
          subMixes: [
            IamfSubMixInfo(
              elements: const [
                IamfMixElementGain(audioElementId: 301, defaultGainDb: 2),
              ],
              outputMixGainDb: 0,
              layouts: [_layout('Stereo')],
            ),
          ],
        ),
      ],
    );

    test('one tagged row per declared layout, carrying stored values', () {
      final rows = planQcLoudnessRows(report);
      expect(rows.map((r) => r.key), ['400/0/0', '400/0/1', '401/0/0']);
      expect(rows.every((r) => r.taggedInFile && r.measurable), isTrue);
      expect(rows[0].mixLabel, 'Main');
      expect(rows[0].soundSystem, SoundSystem.stereo);
      expect(rows[0].shipped!.integratedLufs, -19.53);
      expect(rows[0].shipped!.digitalPeakDbfs, -3);
      expect(rows[0].shipped!.truePeakDbtp, 2.32);
      expect(rows[1].shipped!.truePeakDbtp, isNull);
      // A presentation without a name is labelled by its id.
      expect(rows[2].mixLabel, 'Mix presentation 401');
    });

    test('adds the monitoring layout untagged where not declared', () {
      final rows = planQcLoudnessRows(
        report,
        monitoringLayout: SoundSystem.binaural,
      );
      expect(rows.map((r) => r.key), [
        '400/0/0',
        '400/0/1',
        '400/0/-1',
        '401/0/0',
        '401/0/-1',
      ]);
      final mon = rows[2];
      expect(mon.taggedInFile, isFalse);
      expect(mon.shipped, isNull);
      expect(mon.soundSystem, SoundSystem.binaural);
      expect(mon.measurable, isTrue);
    });

    test('does not add the monitoring layout the sub-mix declares', () {
      final rows = planQcLoudnessRows(
        report,
        monitoringLayout: SoundSystem.stereo,
      );
      expect(rows.length, 3);
      expect(rows.every((r) => r.taggedInFile), isTrue);
    });

    test('marks a layout the renderer cannot target', () {
      final rows = planQcLoudnessRows(
        _report(
          aes: [_ae(300)],
          mixes: [
            _mix(
              400,
              subMixes: [
                IamfSubMixInfo(
                  elements: const [
                    IamfMixElementGain(audioElementId: 300, defaultGainDb: 0),
                  ],
                  outputMixGainDb: 0,
                  layouts: [_layout('9.1.4')],
                ),
              ],
            ),
          ],
        ),
      );
      expect(rows, hasLength(1));
      expect(rows[0].soundSystem, isNull);
      expect(rows[0].layoutLabel, '9.1.4');
      expect(rows[0].measurable, isFalse);
      expect(rows[0].notMeasurableReason, 'The renderer cannot render 9.1.4.');
      // The stored values are still carried for display.
      expect(rows[0].shipped!.integratedLufs, -18);
    });

    test('marks every row of a sub-mix with an unrenderable element', () {
      final rows = planQcLoudnessRows(
        _report(
          aes: [
            _ae(300),
            _ae(
              302,
              renderable: false,
              skipReason: IamfAeSkipReason.objectBased,
            ),
          ],
          mixes: [
            _mix(
              400,
              subMixes: [
                IamfSubMixInfo(
                  elements: const [
                    IamfMixElementGain(audioElementId: 300, defaultGainDb: 0),
                    IamfMixElementGain(audioElementId: 302, defaultGainDb: 0),
                  ],
                  outputMixGainDb: 0,
                  layouts: [_layout('Stereo'), _layout('5.1')],
                ),
              ],
            ),
          ],
        ),
        monitoringLayout: SoundSystem.binaural,
      );
      expect(rows, hasLength(3));
      for (final row in rows) {
        expect(row.measurable, isFalse, reason: row.key);
        expect(
          row.notMeasurableReason,
          "Audio element 302 cannot be rendered: object-based audio isn't "
          'supported yet.',
        );
      }
    });

    test('marks a sub-mix referencing an element the file lacks', () {
      final rows = planQcLoudnessRows(
        _report(
          aes: [_ae(300)],
          mixes: [
            _mix(
              400,
              subMixes: [
                IamfSubMixInfo(
                  elements: const [
                    IamfMixElementGain(audioElementId: 999, defaultGainDb: 0),
                  ],
                  outputMixGainDb: 0,
                  layouts: [_layout('Stereo')],
                ),
              ],
            ),
          ],
        ),
      );
      expect(
        rows.single.notMeasurableReason,
        'Audio element 999 is not in the file.',
      );
    });

    test('a file without mix presentations plans nothing', () {
      expect(
        planQcLoudnessRows(
          _report(aes: [_ae(300)], mixes: const []),
          monitoringLayout: SoundSystem.stereo,
        ),
        isEmpty,
      );
    });

    test('flags every row of a sub-mix whose gains can vary over time', () {
      IamfProbeReport withModes({int element = 1, int output = 1}) => _report(
        aes: [_ae(300)],
        mixes: [
          _mix(
            400,
            subMixes: [
              IamfSubMixInfo(
                elements: [
                  IamfMixElementGain(
                    audioElementId: 300,
                    defaultGainDb: 0,
                    paramDefinitionMode: element,
                  ),
                ],
                outputMixGainDb: 0,
                outputGainParamDefinitionMode: output,
                layouts: [_layout('Stereo')],
              ),
            ],
          ),
        ],
      );
      List<bool> flags(IamfProbeReport r) => [
        for (final row in planQcLoudnessRows(
          r,
          monitoringLayout: SoundSystem.binaural,
        ))
          row.gainsMayVary,
      ];
      // A tagged row and the monitoring row each time.
      expect(flags(withModes()), [false, false]);
      expect(flags(withModes(element: 0)), [true, true]);
      expect(flags(withModes(output: 0)), [true, true]);
    });
  });

  group('measureQcLoudness', () {
    final report = _report(
      aes: [_ae(300), _ae(301)],
      mixes: [
        _mix(
          400,
          name: 'Main',
          subMixes: [
            IamfSubMixInfo(
              elements: const [
                IamfMixElementGain(
                  audioElementId: 300,
                  defaultGainDb: -3,
                  headphonesRenderingMode: 'stereo',
                  binauralFilterProfile: 'direct',
                ),
                IamfMixElementGain(audioElementId: 301, defaultGainDb: 0),
              ],
              outputMixGainDb: -1.5,
              layouts: [_layout('Stereo'), _layout('9.1.4')],
            ),
          ],
        ),
      ],
    );

    test(
      'dispatches one pass per measurable row with the stored gains',
      () async {
        final passes = <_Pass>[];
        final rows = planQcLoudnessRows(
          report,
          monitoringLayout: SoundSystem.binaural,
        );
        expect(rows.map((r) => r.measurable), [true, false, true]);
        final progress = <(int, int)>[];
        final outcome = await measureQcLoudness(
          path: '/f/a.mp4',
          report: report,
          rows: rows,
          withTraces: true,
          onProgress: (d, t) => progress.add((d, t)),
          maxConcurrency: 1,
          runPass:
              ({
                required path,
                required bufferSize,
                required oarLayout,
                required outputMixGainDb,
                required elements,
                withTraces = false,
              }) async {
                passes.add(_Pass(path, oarLayout, outputMixGainDb, elements));
                expect(bufferSize, 1024);
                expect(withTraces, isTrue);
                return const IamfMeasureOutcome(
                  MixMeasureOutcome(scalars: _kScalars),
                );
              },
        );

        expect(outcome.status, LoudnessPassStatus.completed);
        expect(passes, hasLength(2));
        expect(passes[0].path, '/f/a.mp4');
        expect(passes[0].oarLayout, 2); // stereo
        expect(passes[1].oarLayout, 0xFF); // binaural
        expect(passes[0].outputMixGainDb, -1.5);
        final elements = passes[0].elements;
        expect(elements.map((e) => e.audioElementId), [300, 301]);
        expect(elements[0].mixGainDb, -3);
        expect(elements[0].headphonesMode, 0); // 'stereo'
        expect(elements[0].binauralProfile, 1); // 'direct'
        // No rendering config in the file: OAR's defaults.
        expect(elements[1].headphonesMode, 1);
        expect(elements[1].binauralProfile, 0);

        // The unmeasurable row counts toward progress and has no result.
        expect(progress, [(1, 3), (2, 3), (3, 3)]);
        expect(outcome.results.map((r) => r.row.key), ['400/0/0', '400/0/-1']);
        expect(outcome.results[0].deltaIntegratedLu, closeTo(-18 + 19.5, 1e-9));
        expect(outcome.results[1].deltaIntegratedLu, isNull);
      },
    );

    test('a failed pass reports the row label', () async {
      final rows = planQcLoudnessRows(report);
      final outcome = await measureQcLoudness(
        path: '/f/a.mp4',
        report: report,
        rows: rows,
        maxConcurrency: 1,
        runPass:
            ({
              required path,
              required bufferSize,
              required oarLayout,
              required outputMixGainDb,
              required elements,
              withTraces = false,
            }) async =>
                const IamfMeasureOutcome.failed('unsupported: no decoder'),
      );
      expect(outcome.status, LoudnessPassStatus.failed);
      expect(outcome.failedRowLabel, 'Main / Stereo');
      expect(outcome.failedReason, 'unsupported: no decoder');
      expect(outcome.results, isEmpty);
    });

    test('a failed pass without a message has no reason', () async {
      final outcome = await measureQcLoudness(
        path: '/f/a.mp4',
        report: report,
        rows: planQcLoudnessRows(report),
        maxConcurrency: 1,
        runPass:
            ({
              required path,
              required bufferSize,
              required oarLayout,
              required outputMixGainDb,
              required elements,
              withTraces = false,
            }) async => const IamfMeasureOutcome.failed(),
      );
      expect(outcome.status, LoudnessPassStatus.failed);
      expect(outcome.failedRowLabel, 'Main / Stereo');
      expect(outcome.failedReason, isNull);
    });

    test('cancel between rows keeps the completed rows', () async {
      final many = _report(
        aes: [_ae(300)],
        mixes: [
          _mix(
            400,
            subMixes: [
              IamfSubMixInfo(
                elements: const [
                  IamfMixElementGain(audioElementId: 300, defaultGainDb: 0),
                ],
                outputMixGainDb: 0,
                layouts: [_layout('Stereo'), _layout('5.1'), _layout('7.1.4')],
              ),
            ],
          ),
        ],
      );
      final rows = planQcLoudnessRows(many);
      var calls = 0;
      final outcome = await measureQcLoudness(
        path: '/f/a.iamf',
        report: many,
        rows: rows,
        maxConcurrency: 1,
        isCancelled: () => calls >= 1,
        runPass:
            ({
              required path,
              required bufferSize,
              required oarLayout,
              required outputMixGainDb,
              required elements,
              withTraces = false,
            }) async {
              calls++;
              return const IamfMeasureOutcome(
                MixMeasureOutcome(scalars: _kScalars),
              );
            },
      );
      expect(outcome.status, LoudnessPassStatus.cancelled);
      expect(outcome.results.map((r) => r.row.layoutLabel), ['Stereo']);
    });
  });

  group('QcMeasuredRow.deltaIntegratedLu', () {
    QcLoudnessRow row({required double stored}) => planQcLoudnessRows(
      _report(
        aes: [_ae(300)],
        mixes: [
          _mix(
            400,
            subMixes: [
              IamfSubMixInfo(
                elements: const [
                  IamfMixElementGain(audioElementId: 300, defaultGainDb: 0),
                ],
                outputMixGainDb: 0,
                layouts: [_layout('Stereo', integrated: stored)],
              ),
            ],
          ),
        ],
      ),
    ).single;
    MixMeasureResult measured(double lufs) =>
        (integratedLufs: lufs, truePeakDbtp: -1.0, digitalPeakDbfs: -1.0);

    test('is stored minus measured', () {
      expect(
        QcMeasuredRow(
          row: row(stored: -18),
          scalars: measured(-19.5),
        ).deltaIntegratedLu,
        closeTo(1.5, 1e-9),
      );
    });

    test('is null when either value is at the silence floor', () {
      expect(
        QcMeasuredRow(
          row: row(stored: -18),
          scalars: measured(-120),
        ).deltaIntegratedLu,
        isNull,
      );
      expect(
        QcMeasuredRow(
          row: row(stored: -128),
          scalars: measured(-19.5),
        ).deltaIntegratedLu,
        isNull,
      );
    });
  });
}
