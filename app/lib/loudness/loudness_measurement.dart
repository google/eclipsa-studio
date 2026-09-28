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

/// Shared offline loudness-measurement orchestration.
///
/// One pipeline drives both the IAMF export dialog's measure phase and
/// the Loudness Report window (ES-195): render each mix × layout through
/// a standalone [OfflineMixRenderer] and measure BS.1770-4 loudness
/// (optionally with the recorded time series). Each element streams
/// straight from its session source WAV — the renderer applies the
/// same gain → routing → resample → pad pipeline the IAMF push export
/// uses (ES-484), so no scratch WAVs are staged anywhere.
///
/// Invariants owned here (established by the export path, see ES-44):
/// - The live OAR must be **paused** for the whole pass (the caller
///   holds `setExportPaused(true)`; live-vs-offline concurrent OAR use
///   corrupts the heap).
/// - Renders run on a **bounded pool** of worker isolates. Offline
///   renderer instances are independent (each owns a private OAR/OBR
///   instance — verified by the engine's offline_mix_concurrency_test
///   under the TSan/ASan CI sweeps), so passes may overlap each other;
///   only overlap with the *live* renderer is forbidden.
///
/// The pass yields to the event loop after every progress callback so
/// a progress bar driven by `setState` in the callback actually paints
/// between the multi-second awaits.
library;

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../export/element_clip_stats.dart';
import '../export/iamf_format_maps.dart';
import '../export/iamf_measure_isolate.dart';
import '../logging/log.dart';
import '../state.dart';

/// Terminal status of a measure pass.
enum LoudnessPassStatus { completed, cancelled, failed }

/// One layout to measure for a sub-mix. [taggedInMix] is false for
/// layouts measured on top of the mix's own list (e.g. the current
/// monitoring layout in the Loudness Report) — their results are never
/// written back into [MixLayout.loudness] / the IAMF bitstream.
class LoudnessMeasureTarget {
  final SoundSystem soundSystem;
  final bool taggedInMix;

  const LoudnessMeasureTarget({
    required this.soundSystem,
    this.taggedInMix = true,
  });
}

/// Chooses which layouts to measure for a sub-mix. The default measures
/// exactly the sub-mix's own layout list.
typedef LoudnessMeasureTargets =
    List<LoudnessMeasureTarget> Function(Mix mix, int subMixIndex, SubMix sub);

/// Measurement of one mix × layout.
class MeasuredLayoutLoudness {
  final int mixId;
  final int subMixIndex;
  final SoundSystem soundSystem;
  final bool taggedInMix;
  final MixMeasureResult scalars;
  final MixMeasureTraces? traces;

  const MeasuredLayoutLoudness({
    required this.mixId,
    required this.subMixIndex,
    required this.soundSystem,
    required this.taggedInMix,
    required this.scalars,
    this.traces,
  });
}

/// Result of [measureMixLoudness]. [results] holds every layout
/// measured before a cancel/failure, so partial progress is usable.
class LoudnessMeasureOutcome {
  final LoudnessPassStatus status;

  /// Label of the layout whose measurement failed (status == failed).
  final String? failedLayoutLabel;

  final List<MeasuredLayoutLoudness> results;

  /// Per-element signal-overload stats aggregated (max-merged) across
  /// every completed render, keyed by element id (ES-470). Partial on
  /// cancel/failure, like [results]. An element included in no sub-mix
  /// is never streamed by the measure pass and has no entry here — the
  /// encode-side receipt still catches it.
  final Map<int, ElementClipStats> elementClipStats;

  const LoudnessMeasureOutcome._(
    this.status,
    this.results, {
    this.failedLayoutLabel,
    this.elementClipStats = const {},
  });
}

/// Hand control back to the event loop so a frame scheduled by a
/// `setState` in a progress callback can paint. A zero-duration timer
/// (macrotask) is required — a microtask would run before the next
/// render and the progress bar would freeze.
Future<void> _yieldToUi() => Future<void>.delayed(Duration.zero);

/// Runs one mix × layout render+measure. Defaults to
/// [runMixMeasureOnIsolate]; injectable so the orchestration (cancel
/// between layouts, partial results, progress) is testable without the
/// engine dylib.
typedef MixMeasureRunner =
    Future<MixMeasureOutcome?> Function({
      required int sampleRate,
      required int bufferSize,
      required int oarLayout,
      required double outputMixGainDb,
      required List<MixMeasureElement> elements,
      bool withTraces,
    });

/// Unique basename per element (keyed by element id), disambiguating
/// duplicate basenames with the element id. The export uses these as
/// the `audio_frame_metadata.wav_filename` join key
/// ([IamfExportConfig.basenameFor]), and the key must be unique per
/// ELEMENT, not per source WAV: two session elements may reference
/// different files with one basename (`stems/drums.wav` vs
/// `alt/drums.wav`) — or the very same file — and each element still
/// needs its own metadata entry and audio_element_id. Keying by path
/// used to collapse same-path elements onto one basename, which the
/// engine rejects as a duplicate-id join (-12).
Map<int, String> uniqueWavBasenames(List<AudioElement> elements) {
  final wavBasenames = <int, String>{};
  final usedBasenames = <String>{};
  for (final e in elements) {
    final wavPath = e.wavPath;
    if (wavPath == null) continue;
    var base = p.basename(wavPath);
    if (usedBasenames.contains(base)) {
      final dot = base.lastIndexOf('.');
      final ext = dot > 0 ? base.substring(dot) : '';
      final name = dot > 0 ? base.substring(0, dot) : base;
      base = '${name}_${e.id}$ext';
    }
    usedBasenames.add(base);
    wavBasenames[e.id] = base;
  }
  return wavBasenames;
}

/// Default number of concurrent measure renders. Each job is a full
/// element-stream set (SINC resampler state per element) plus an
/// OAR/OBR instance on its own isolate, so the cap bounds peak native
/// memory; the live audio device is paused for the pass, so there is
/// no real-time budget to protect.
int _defaultMeasureConcurrency() =>
    min(4, max(1, Platform.numberOfProcessors ~/ 2));

/// Renders each mix × layout through OAR and measures loudness on a
/// bounded pool of worker isolates, with per-completion [onProgress].
/// Results come back in plan order regardless of completion order.
/// Layouts OAR cannot render (e.g. 22.2) are skipped with a warning and
/// count toward progress. Every element streams from its source WAV
/// padded/truncated to [paddedFrames] (in [sampleRate] frames), so all
/// streams agree on length. [targetsFor] widens/narrows the layout set
/// per sub-mix (defaults to the sub-mix's own layouts); [withTraces]
/// additionally returns the recorded time series per layout.
/// [maxConcurrency] overrides the pool size (escape hatch and test
/// hook; 1 reproduces the historical strictly-sequential pass).
///
/// Cancel is observed before each dispatch: in-flight renders drain and
/// their results are kept, so up to pool-size renders may complete
/// after the cancel. On cancel/failure the partial [results] are the
/// completed *set* in plan order (not necessarily a prefix of the
/// plan); consumers match results by (mixId, subMixIndex, soundSystem),
/// never by position.
Future<LoudnessMeasureOutcome> measureMixLoudness({
  required List<Mix> mixes,
  required List<AudioElement> elements,
  required int paddedFrames,
  required int sampleRate,
  int bufferSize = 1024,
  bool withTraces = false,
  LoudnessMeasureTargets? targetsFor,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  int? maxConcurrency,
  MixMeasureRunner runPass = runMixMeasureOnIsolate,
}) async {
  final plan = <(Mix, int, SubMix, LoudnessMeasureTarget)>[];
  for (final mix in mixes) {
    for (var subIdx = 0; subIdx < mix.subMixes.length; subIdx++) {
      final sub = mix.subMixes[subIdx];
      final targets =
          targetsFor?.call(mix, subIdx, sub) ??
          [
            for (final layout in sub.layouts)
              LoudnessMeasureTarget(soundSystem: layout.soundSystem),
          ];
      for (final target in targets) {
        plan.add((mix, subIdx, sub, target));
      }
    }
  }
  Log.i(LogCat.export, 'Measuring loudness for ${plan.length} layout(s)');
  if (plan.isEmpty) {
    return const LoudnessMeasureOutcome._(LoudnessPassStatus.completed, []);
  }

  // Slot per plan entry so completion order never reorders results.
  final results = List<MeasuredLayoutLoudness?>.filled(plan.length, null);
  // Aggregated per-element overload stats; merged turn-atomically (no
  // await between read and write), commutative so worker completion
  // order does not matter.
  var clipStats = <int, ElementClipStats>{};
  var next = 0; // shared dispatch cursor
  var done = 0; // monotonic progress counter
  var failedIndex = -1; // lowest plan index whose pass failed
  var sawCancel = false;
  Object? firstError;
  StackTrace? firstErrorStack;

  // Single-isolate Dart: reads and writes of the shared counters above
  // are turn-atomic (no await between read and write), so the workers
  // need no locking.
  bool shouldStop() {
    if (failedIndex >= 0 || firstError != null || sawCancel) return true;
    if (isCancelled?.call() ?? false) {
      sawCancel = true;
      return true;
    }
    return false;
  }

  Future<void> worker() async {
    while (!shouldStop()) {
      final i = next++;
      if (i >= plan.length) return;
      final (mix, subIdx, sub, target) = plan[i];
      final oarLayout = soundSystemToOarLayout(target.soundSystem);
      if (oarLayout == null) {
        Log.w(
          LogCat.export,
          'Skipping loudness for unsupported layout: '
          '${target.soundSystem.label}',
        );
        done++;
        onProgress?.call(done, plan.length);
        continue;
      }

      // Gather the elements included in this sub-mix.
      final measureElements = <MixMeasureElement>[];
      for (final settings in sub.elementSettings) {
        if (!settings.included) continue;
        final elem = elements
            .where((e) => e.id == settings.elementId)
            .firstOrNull;
        if (elem == null) continue;

        final wavPath = elem.wavPath;
        if (wavPath == null) continue;

        final (oarType, oarSubType, oarCh) = elementToOarType(elem);
        final pos = elementObjectPolarPositions(elem);
        measureElements.add(
          MixMeasureElement(
            sourceWavPath: wavPath,
            gainDb: elem.gain,
            routing: elem.inputRouting ?? const [],
            padToFrames: paddedFrames,
            outputSampleRate: sampleRate,
            elementId: elem.id,
            elementType: oarType,
            elementSubType: oarSubType,
            channels: oarCh,
            mixGainDb: settings.mixGain,
            headphonesMode: settings.headphonesMode.index,
            binauralProfile: settings.binauralProfile.index,
            numObjects: pos.count,
            azimuth: pos.az,
            elevation: pos.el,
            distance: pos.dist,
            azimuth2: pos.az2,
            elevation2: pos.el2,
            distance2: pos.dist2,
          ),
        );
      }

      // Render + measure on this worker's own isolate. Instances are
      // independent (see the library doc); overlap with the paused
      // live renderer is what remains forbidden (ES-44).
      final MixMeasureOutcome? outcome;
      try {
        outcome = await runPass(
          sampleRate: sampleRate,
          bufferSize: bufferSize,
          oarLayout: oarLayout,
          outputMixGainDb: sub.outputMixGain,
          elements: measureElements,
          withTraces: withTraces,
        );
      } catch (e, st) {
        // Stop dispatching, let in-flight workers drain, rethrow after
        // the pool settles (preserves the sequential pass's contract of
        // surfacing the exception to the caller).
        firstError ??= e;
        firstErrorStack ??= st;
        return;
      }
      if (outcome == null) {
        if (failedIndex < 0 || i < failedIndex) failedIndex = i;
        return;
      }

      final scalars = outcome.scalars;
      Log.i(
        LogCat.export,
        'Measured ${mix.name}/${target.soundSystem.label}: '
        'I=${scalars.integratedLufs.toStringAsFixed(2)} LUFS '
        'peak=${scalars.digitalPeakDbfs.toStringAsFixed(2)} dBFS '
        'truePeak=${scalars.truePeakDbtp.toStringAsFixed(2)} dBTP',
      );

      results[i] = MeasuredLayoutLoudness(
        mixId: mix.id,
        subMixIndex: subIdx,
        soundSystem: target.soundSystem,
        taggedInMix: target.taggedInMix,
        scalars: scalars,
        traces: outcome.traces,
      );
      // Every element added to a successful render should have stats;
      // a missing entry means the engine getter failed unexpectedly
      // and the overload gate could silently miss that element.
      for (final e in measureElements) {
        if (!outcome.elementClipStats.containsKey(e.elementId)) {
          Log.w(
            LogCat.export,
            'No clip stats for element ${e.elementId} in '
            '${mix.name}/${target.soundSystem.label}',
          );
        }
      }
      clipStats = mergeElementClipStats(clipStats, outcome.elementClipStats);

      done++;
      onProgress?.call(done, plan.length);
      await _yieldToUi();
    }
  }

  final poolSize = max(
    1,
    min(maxConcurrency ?? _defaultMeasureConcurrency(), plan.length),
  );
  await Future.wait([for (var w = 0; w < poolSize; w++) worker()]);

  final collected = [for (final r in results) ?r];
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstErrorStack!);
  }
  if (failedIndex >= 0) {
    return LoudnessMeasureOutcome._(
      LoudnessPassStatus.failed,
      collected,
      // uiLabel: this feeds user-facing failure strings in the export and
      // loudness-report dialogs, which show "10.2.9.3 (22.2)" elsewhere.
      // With concurrent workers the lowest failed plan index is
      // reported, so the label is deterministic.
      failedLayoutLabel: plan[failedIndex].$4.soundSystem.uiLabel,
      elementClipStats: clipStats,
    );
  }
  if (sawCancel) {
    return LoudnessMeasureOutcome._(
      LoudnessPassStatus.cancelled,
      collected,
      elementClipStats: clipStats,
    );
  }
  return LoudnessMeasureOutcome._(
    LoudnessPassStatus.completed,
    collected,
    elementClipStats: clipStats,
  );
}

/// Returns [mixes] with [MixLayout.loudness] updated from [results].
/// Only tagged results are applied — monitoring-only measurements never
/// reach the session model or the IAMF bitstream.
List<Mix> mixesWithMeasuredLoudness(
  List<Mix> mixes,
  List<MeasuredLayoutLoudness> results,
) {
  return [
    for (final mix in mixes)
      mix.copyWith(
        subMixes: [
          for (var subIdx = 0; subIdx < mix.subMixes.length; subIdx++)
            mix.subMixes[subIdx].copyWith(
              layouts: [
                for (final layout in mix.subMixes[subIdx].layouts)
                  _layoutWithResult(mix.id, subIdx, layout, results),
              ],
            ),
        ],
      ),
  ];
}

MixLayout _layoutWithResult(
  int mixId,
  int subMixIndex,
  MixLayout layout,
  List<MeasuredLayoutLoudness> results,
) {
  final result = results
      .where(
        (r) =>
            r.taggedInMix &&
            r.mixId == mixId &&
            r.subMixIndex == subMixIndex &&
            r.soundSystem == layout.soundSystem,
      )
      .firstOrNull;
  if (result == null) return layout;
  return layout.copyWith(
    loudness: LoudnessInfo(
      integratedLoudness: result.scalars.integratedLufs,
      digitalPeak: result.scalars.digitalPeakDbfs,
      truePeak: result.scalars.truePeakDbtp,
    ),
  );
}
