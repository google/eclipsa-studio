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

/// The Loudness Report's measurement plan for a loaded IAMF file (ES-520).
///
/// In Playback (QC) mode the report measures the file itself: each mix
/// presentation's sub-mix is decoded and rendered at every loudness
/// layout the file declares for it, plus the current monitoring layout
/// when the file does not declare it, and the result sits beside the
/// loudness_info the file stores for that layout. The rows come from the
/// enriched probe report; the passes run through
/// [runIamfMeasureOnIsolate] on the same bounded pool as the creator
/// report ([runMeasurePool]).
///
/// Measured and stored values differ where the stored values were
/// computed differently: by another renderer, without this
/// application's -1 dBFS limiter (the report states that its measurement
/// runs after the limiter), or from the audio before a lossy encode.
library;

import '../export/iamf_format_maps.dart';
import '../export/iamf_measure_isolate.dart';
import '../logging/log.dart';
import '../playback/iamf_probe.dart';
import '../playback/playback_session.dart'
    show binauralProfileSpecValue, headphonesModeSpecValue;
import '../state.dart' show SoundSystem;
import 'iamf_measure_isolate.dart';
import 'loudness_measurement.dart';

/// The [SoundSystem] a probe loudness layout renders to, or null when
/// the layout has no equivalent the renderer can target (sound systems
/// E, F and G, and any reserved value). [layoutType] and [soundSystem]
/// are the probe's strings (`loudspeakers_ss_convention` with a sound
/// system name such as `Stereo` or `7.1.4`, or `binaural`).
SoundSystem? soundSystemForProbeLayout({
  required String layoutType,
  String? soundSystem,
}) {
  if (layoutType == 'binaural') return SoundSystem.binaural;
  if (layoutType != 'loudspeakers_ss_convention' || soundSystem == null) {
    return null;
  }
  // The probe names sound system H by its channel count; the app's
  // canonical label is the ITU count.
  if (soundSystem == '22.2') return SoundSystem.surround10_2_9_3;
  for (final s in SoundSystem.values) {
    if (s.label == soundSystem) return s;
  }
  return null;
}

/// The loudness_info the file stores for one layout of one sub-mix.
class QcShippedLoudness {
  final double integratedLufs;

  /// Null when the full probe was unavailable.
  final double? digitalPeakDbfs;

  /// Null when the file's `info_type` omits true peak.
  final double? truePeakDbtp;

  const QcShippedLoudness({
    required this.integratedLufs,
    required this.digitalPeakDbfs,
    required this.truePeakDbtp,
  });
}

/// One row of the QC report: one sub-mix of one mix presentation at one
/// layout.
class QcLoudnessRow {
  /// Index into `IamfProbeReport.mixPresentations`.
  final int mixIndex;
  final int mixId;
  final String mixLabel;
  final int subMixIndex;

  /// Index of the layout in the sub-mix's loudness layout list; -1 for
  /// the monitoring row.
  final int layoutIndex;

  /// The layout to render at; null when [notMeasurableReason] says the
  /// renderer cannot target it.
  final SoundSystem? soundSystem;

  /// Display label of the layout: the [SoundSystem]'s, or the probe's
  /// own string for a layout without one.
  final String layoutLabel;

  /// True when the file declares loudness for this layout; false for
  /// the monitoring layout added on top of the file's list.
  final bool taggedInFile;

  /// The stored loudness_info for a tagged row; null for the monitoring
  /// row.
  final QcShippedLoudness? shipped;

  /// Sentence-case reason the row cannot be measured, or null.
  final String? notMeasurableReason;

  /// True when an element mix gain or the output mix gain of the
  /// sub-mix has `param_definition_mode` 0, which implies gain values
  /// carried in the stream that can change over time (see
  /// [IamfMixElementGain.paramDefinitionMode]). The measurement applies
  /// the default gains only.
  final bool gainsMayVary;

  const QcLoudnessRow({
    required this.mixIndex,
    required this.mixId,
    required this.mixLabel,
    required this.subMixIndex,
    required this.layoutIndex,
    required this.soundSystem,
    required this.layoutLabel,
    required this.taggedInFile,
    required this.shipped,
    this.notMeasurableReason,
    this.gainsMayVary = false,
  });

  bool get measurable => notMeasurableReason == null;

  /// Stable identity across a plan and its results; distinct even when
  /// a sub-mix lists one layout twice.
  String get key => '$mixId/$subMixIndex/$layoutIndex';
}

/// A measured row.
class QcMeasuredRow {
  final QcLoudnessRow row;
  final MixMeasureResult scalars;
  final MixMeasureTraces? traces;

  const QcMeasuredRow({required this.row, required this.scalars, this.traces});

  /// Stored minus measured integrated loudness, in LU; null for an
  /// untagged row, and null when either value is at the -120 floor that
  /// stands for silence, where a difference has no meaning.
  double? get deltaIntegratedLu {
    final shipped = row.shipped;
    if (shipped == null) return null;
    if (shipped.integratedLufs <= -120 || scalars.integratedLufs <= -120) {
      return null;
    }
    return shipped.integratedLufs - scalars.integratedLufs;
  }
}

/// The rows to measure for [report]: every sub-mix of every mix
/// presentation at each of its declared loudness layouts, plus
/// [monitoringLayout] (untagged) where the sub-mix does not declare it.
/// A row whose layout the renderer cannot target, or whose sub-mix
/// includes an audio element the file's probe marks not renderable, is
/// kept with a [QcLoudnessRow.notMeasurableReason] so the report can
/// show why instead of measuring the wrong thing.
List<QcLoudnessRow> planQcLoudnessRows(
  IamfProbeReport report, {
  SoundSystem? monitoringLayout,
}) {
  final aesById = {for (final ae in report.audioElements) ae.id: ae};
  final rows = <QcLoudnessRow>[];
  for (
    var mixIndex = 0;
    mixIndex < report.mixPresentations.length;
    mixIndex++
  ) {
    final mix = report.mixPresentations[mixIndex];
    final mixLabel = mix.name ?? 'Mix presentation ${mix.id}';
    for (var subIdx = 0; subIdx < mix.subMixes.length; subIdx++) {
      final sub = mix.subMixes[subIdx];
      // An element the renderer cannot render makes every row of the
      // sub-mix unmeasurable: the render would be missing it.
      String? elementReason;
      for (final el in sub.elements) {
        final ae = aesById[el.audioElementId];
        if (ae == null) {
          elementReason =
              'Audio element ${el.audioElementId} is not in the file.';
          break;
        }
        if (!ae.renderable) {
          elementReason =
              'Audio element ${ae.id} cannot be rendered: '
              '${ae.skipReason.label}.';
          break;
        }
      }

      final gainsMayVary =
          sub.outputGainParamDefinitionMode == 0 ||
          sub.elements.any((el) => el.paramDefinitionMode == 0);

      final declared = <SoundSystem>{};
      for (var li = 0; li < sub.layouts.length; li++) {
        final layout = sub.layouts[li];
        final ss = soundSystemForProbeLayout(
          layoutType: layout.layoutType,
          soundSystem: layout.soundSystem,
        );
        if (ss != null) declared.add(ss);
        final label = ss?.uiLabel ?? layout.soundSystem ?? layout.layoutType;
        rows.add(
          QcLoudnessRow(
            mixIndex: mixIndex,
            mixId: mix.id,
            mixLabel: mixLabel,
            subMixIndex: subIdx,
            layoutIndex: li,
            soundSystem: ss,
            layoutLabel: label,
            taggedInFile: true,
            shipped: layout.integratedLoudnessLufs == null
                ? null
                : QcShippedLoudness(
                    integratedLufs: layout.integratedLoudnessLufs!,
                    digitalPeakDbfs: layout.digitalPeakDbfs,
                    truePeakDbtp: layout.truePeakDbtp,
                  ),
            notMeasurableReason: ss == null
                ? 'The renderer cannot render $label.'
                : elementReason,
            gainsMayVary: gainsMayVary,
          ),
        );
      }
      if (monitoringLayout != null && !declared.contains(monitoringLayout)) {
        rows.add(
          QcLoudnessRow(
            mixIndex: mixIndex,
            mixId: mix.id,
            mixLabel: mixLabel,
            subMixIndex: subIdx,
            layoutIndex: -1,
            soundSystem: monitoringLayout,
            layoutLabel: monitoringLayout.uiLabel,
            taggedInFile: false,
            shipped: null,
            notMeasurableReason: elementReason,
            gainsMayVary: gainsMayVary,
          ),
        );
      }
    }
  }
  return rows;
}

/// Result of [measureQcLoudness]. [results] holds every row measured
/// before a cancel or failure, so partial progress is usable.
class QcLoudnessOutcome {
  final LoudnessPassStatus status;

  /// Label of the row whose measurement failed (status == failed), and
  /// the measurer's reason when it gave one.
  final String? failedRowLabel;
  final String? failedReason;

  final List<QcMeasuredRow> results;

  const QcLoudnessOutcome._(
    this.status,
    this.results, {
    this.failedRowLabel,
    this.failedReason,
  });
}

/// Runs one decoded-IAMF render and measure. Defaults to
/// [runIamfMeasureOnIsolate]; injectable so the plan-to-pass mapping is
/// testable without the engine dylib.
typedef IamfMeasureRunner =
    Future<IamfMeasureOutcome> Function({
      required String path,
      required int bufferSize,
      required int oarLayout,
      required double outputMixGainDb,
      required List<IamfMeasureElement> elements,
      bool withTraces,
    });

/// Measures [rows] of the file at [path] on a bounded pool of worker
/// isolates. Each row renders its sub-mix's audio elements at their
/// stored default mix gains and rendering configs, with the sub-mix's
/// output mix gain, at the row's layout. Rows that are not measurable
/// are skipped and count toward progress. Cancel and failure semantics
/// are those of [runMeasurePool].
Future<QcLoudnessOutcome> measureQcLoudness({
  required String path,
  required IamfProbeReport report,
  required List<QcLoudnessRow> rows,
  int bufferSize = 1024,
  bool withTraces = false,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  int? maxConcurrency,
  IamfMeasureRunner runPass = runIamfMeasureOnIsolate,
}) async {
  Log.i(
    LogCat.export,
    'Measuring loudness of the loaded file for ${rows.length} row(s)',
  );

  // The reason of the lowest failed row, kept beside the pool's failed
  // index. Turn-atomic writes; no locking needed.
  final failedReasons = <int, String>{};

  Future<QcMeasuredRow?> measureRow(int i) async {
    final row = rows[i];
    final sub = report.mixPresentations[row.mixIndex].subMixes[row.subMixIndex];
    if (row.gainsMayVary) {
      Log.w(
        LogCat.export,
        'Measuring ${row.mixLabel}/${row.layoutLabel} with the default mix '
        'gains: the sub-mix has a gain with param_definition_mode 0, whose '
        'stream-carried values the measurement does not apply',
      );
    }
    final elements = [
      for (final el in sub.elements)
        IamfMeasureElement(
          audioElementId: el.audioElementId,
          mixGainDb: el.defaultGainDb,
          headphonesMode:
              headphonesModeSpecValue(el.headphonesRenderingMode) ?? 1,
          binauralProfile:
              binauralProfileSpecValue(el.binauralFilterProfile) ?? 0,
        ),
    ];
    final pass = await runPass(
      path: path,
      bufferSize: bufferSize,
      oarLayout: soundSystemToOarLayout(row.soundSystem!)!,
      outputMixGainDb: sub.outputMixGainDb,
      elements: elements,
      withTraces: withTraces,
    );
    final outcome = pass.outcome;
    if (outcome == null) {
      Log.w(
        LogCat.export,
        'Measuring ${row.mixLabel}/${row.layoutLabel} failed: '
        '${pass.error ?? 'no message from the measurer; see the engine log'}',
      );
      if (pass.error case final reason?) failedReasons[i] = reason;
      return null;
    }
    final scalars = outcome.scalars;
    Log.i(
      LogCat.export,
      'Measured ${row.mixLabel}/${row.layoutLabel}: '
      'I=${scalars.integratedLufs.toStringAsFixed(2)} LUFS '
      'peak=${scalars.digitalPeakDbfs.toStringAsFixed(2)} dBFS '
      'truePeak=${scalars.truePeakDbtp.toStringAsFixed(2)} dBTP'
      '${row.shipped == null ? '' : ' (stored I='
                '${row.shipped!.integratedLufs.toStringAsFixed(2)} LUFS)'}',
    );
    return QcMeasuredRow(row: row, scalars: scalars, traces: outcome.traces);
  }

  final pool = await runMeasurePool<QcMeasuredRow>(
    planLength: rows.length,
    measure: measureRow,
    isSkipped: (i) => !rows[i].measurable,
    onProgress: onProgress,
    isCancelled: isCancelled,
    maxConcurrency: maxConcurrency,
  );
  return QcLoudnessOutcome._(
    pool.status,
    pool.results,
    failedRowLabel: pool.failedIndex >= 0
        ? '${rows[pool.failedIndex].mixLabel} / '
              '${rows[pool.failedIndex].layoutLabel}'
        : null,
    failedReason: failedReasons[pool.failedIndex],
  );
}
