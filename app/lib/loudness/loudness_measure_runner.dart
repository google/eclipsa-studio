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

/// The programme loudness pass behind the Loudness Report (ES-195, ES-615).
///
/// Two surfaces start it: the Loudness Report dialog (on open when no
/// current report exists, and its Re-measure button) and the Mix view's
/// LAYOUTS bar (its Measure Loudness button, which measures without
/// opening the report). One pass runs at a time for the whole app; its
/// progress and outcome live in [loudnessMeasureProvider] so both
/// surfaces, the status bar and the transport show the same state, and
/// a finished pass writes the report into [loudnessReportProvider] and
/// the scalar figures into the mixes.
///
/// The pass is not modal. While it runs the live renderer is held
/// offline-exclusive, so the device output is silent and transport must
/// not start ([transportBlockedProvider] in state.dart). The session
/// stays editable: the pass measures the elements and mixes it started
/// with and stamps the report with their fingerprint, so an edit made
/// during the pass leaves the report stale, as an edit after it would.
/// Replacing the session or leaving Creator calls [LoudnessMeasureRunner
/// .discard], which cancels the pass and drops its results.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../export/iamf_export_config.dart' show kIamfTargetSampleRate;
import '../export/iamf_format_maps.dart';
import '../logging/log.dart';
import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import '../session/session_provider.dart';
import '../state.dart';
import '../workspace/workspace_mode.dart';
import 'loudness_measurement.dart';
import 'loudness_report_provider.dart';

/// Progress of the running pass, or the outcome of the last one.
class LoudnessMeasureState {
  /// A pass is in flight.
  final bool running;

  /// Layouts measured so far by the running pass.
  final int done;

  /// Layouts the running pass measures in total; 0 until it reports.
  final int total;

  /// [LoudnessMeasureRunner.cancel] was called and the pass has not
  /// stopped yet.
  final bool cancelRequested;

  /// Why the last pass produced no report. Null after a completed or
  /// cancelled pass; cleared when the next pass starts or by
  /// [LoudnessMeasureRunner.clearError].
  final String? error;

  const LoudnessMeasureState({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.cancelRequested = false,
    this.error,
  });
}

class LoudnessMeasureRunner extends Notifier<LoudnessMeasureState> {
  /// Bumped by [discard]; a pass whose generation no longer matches
  /// drops its results when it stops.
  int _generation = 0;

  @override
  LoudnessMeasureState build() => const LoudnessMeasureState();

  /// Asks the running pass to stop after the layouts it is on. No effect
  /// when nothing runs.
  void cancel() {
    if (!state.running || state.cancelRequested) return;
    state = LoudnessMeasureState(
      running: true,
      done: state.done,
      total: state.total,
      cancelRequested: true,
    );
  }

  void clearError() {
    if (state.error != null && !state.running) {
      state = const LoudnessMeasureState();
    }
  }

  /// Drops the pass and the report along with the session they belong
  /// to. Called when a session is replaced or closed and when the
  /// workspace leaves Creator: a running pass is cancelled and its
  /// results are discarded when it stops, and the stored report and any
  /// error are cleared, so the next session starts without figures.
  void discard() {
    _generation++;
    ref.read(loudnessReportProvider.notifier).clear();
    if (state.running) {
      cancel();
    } else {
      state = const LoudnessMeasureState();
    }
  }

  /// Measures every sub-mix's tagged layouts plus the monitoring layout,
  /// then stores the report. Returns when the pass has completed, been
  /// cancelled, or failed; [state] says which. Returns at once when a
  /// pass is already running.
  Future<void> run() async {
    // Synchronous re-entrancy guard, same as the export dialog's
    // _exportInvoked: a Measure button stays armed until the next
    // rebuild, and a second pass would render every layout again and
    // write the report twice. The engine itself takes nested
    // offline-exclusive holds by refcount (ES-495), so two passes would
    // not corrupt the renderer; the guard avoids the duplicate work.
    if (state.running) return;

    final elements = ref.read(elementsProvider);
    final mixes = ref.read(mixesNotifierProvider);
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) {
      state = const LoudnessMeasureState(error: 'Audio engine not available.');
      return;
    }
    if (mixes.isEmpty || elements.every((e) => e.wavPath == null)) {
      state = const LoudnessMeasureState(
        error:
            'Nothing to measure: no mix presentations '
            'or no elements with audio.',
      );
      return;
    }
    // The fingerprint of what this pass measures, taken before the pass
    // so an edit made while it runs marks the report stale.
    final fingerprint = ref.read(currentLoudnessFingerprintProvider);
    final generation = _generation;

    // Stop transport and pause the live OAR for the duration of the
    // pass — the offline renderer's transient OAR instances race the
    // live one otherwise (ES-44, same discipline as export).
    ref.read(playingProvider.notifier).set(false);
    engine.setExportPaused(true);
    state = const LoudnessMeasureState(running: true);

    try {
      // Pad every element stream to the longest source (in target-rate
      // frames) so shorter elements trail in silence, exactly like
      // playback. No coded-frame alignment — the report never encodes.
      var longest = 0;
      for (final e in elements) {
        final wav = e.wavInfo;
        if (wav == null || wav.sampleRate <= 0) continue;
        final n = (wav.totalSamples * kIamfTargetSampleRate / wav.sampleRate)
            .round();
        if (n > longest) longest = n;
      }

      // Measure each sub-mix's tagged layouts plus the current
      // monitoring layout (badged, never written back).
      final monitoringSs = soundSystemForOarValue(
        ref.read(monitoringConfigProvider).activeLayout.oarValue,
      );
      final outcome = await measureMixLoudness(
        mixes: mixes,
        elements: elements,
        paddedFrames: longest,
        sampleRate: kIamfTargetSampleRate,
        withTraces: true,
        targetsFor: (mix, subIdx, sub) {
          final targets = [
            for (final layout in sub.layouts)
              LoudnessMeasureTarget(soundSystem: layout.soundSystem),
          ];
          if (monitoringSs != null &&
              !sub.layouts.any((l) => l.soundSystem == monitoringSs)) {
            targets.add(
              LoudnessMeasureTarget(
                soundSystem: monitoringSs,
                taggedInMix: false,
              ),
            );
          }
          return targets;
        },
        onProgress: (done, total) {
          state = LoudnessMeasureState(
            running: true,
            done: done,
            total: total,
            cancelRequested: state.cancelRequested,
          );
        },
        isCancelled: () => state.cancelRequested,
      );
      // The session the pass measured is gone: discard() ran, or the
      // workspace left Creator without it. Its results belong to no
      // session now.
      if (generation != _generation ||
          ref.read(workspaceModeProvider) != WorkspaceMode.creator) {
        state = const LoudnessMeasureState();
        return;
      }
      switch (outcome.status) {
        case LoudnessPassStatus.cancelled:
          state = const LoudnessMeasureState();
          return;
        case LoudnessPassStatus.failed:
          state = LoudnessMeasureState(
            error:
                'Loudness measurement failed for '
                '${outcome.failedLayoutLabel}. Check the log for details.',
          );
          return;
        case LoudnessPassStatus.completed:
          break;
      }

      final report = LoudnessReportData(
        results: outcome.results,
        fingerprint: fingerprint,
        measuredAt: DateTime.now(),
        sampleRate: kIamfTargetSampleRate,
        elementClipStats: outcome.elementClipStats,
      );
      ref.read(loudnessReportProvider.notifier).set(report);
      // Persist the scalar triplet into the session model (tagged rows
      // only) so mix/inspector views update and an export can reuse the
      // values — identical to the export measure phase's write-back.
      // Into the live mixes, matched by mix, sub-mix and layout: an
      // edit made during the pass stays, and the report reads as stale
      // beside it.
      final live = ref.read(mixesNotifierProvider);
      ref
          .read(mixesNotifierProvider.notifier)
          .set(mixesWithMeasuredLoudness(live, outcome.results));
      ref.read(sessionProvider.notifier).markDirty();
      state = const LoudnessMeasureState();
    } catch (e, st) {
      Log.e(LogCat.export, 'Loudness Report exception: $e\n$st');
      state = generation == _generation
          ? LoudnessMeasureState(error: 'Measurement failed: $e')
          : const LoudnessMeasureState();
    } finally {
      engine.setExportPaused(false);
    }
  }
}

/// The one programme loudness pass the app runs at a time.
final loudnessMeasureProvider =
    NotifierProvider<LoudnessMeasureRunner, LoudnessMeasureState>(
      LoudnessMeasureRunner.new,
    );
