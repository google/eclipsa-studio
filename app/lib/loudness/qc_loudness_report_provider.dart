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

/// The Loudness Report pass and store for a loaded IAMF file (ES-520).
///
/// The QC counterpart of [loudnessMeasureProvider] and
/// [loudnessReportProvider]. It measures the file open in Playback mode
/// ([playbackSessionProvider]) and keeps the result in memory until
/// the workspace leaves Playback or another file opens, which calls
/// [QcLoudnessMeasureRunner.discard]. The report also carries the
/// file's path, and [currentQcLoudnessReportProvider] hands it out only
/// while that path is open. Nothing is written back:
/// the file is read-only and the creator report's export reuse
/// ([canReuseLoudnessReport]) never sees these results.
///
/// While the pass runs the live renderer is held offline-exclusive, so
/// the device output is silent and transport must not start
/// ([transportBlockedProvider] in state.dart).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../export/iamf_format_maps.dart';
import '../logging/log.dart';
import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import '../playback/playback_session.dart';
import '../state.dart';
import '../workspace/workspace_mode.dart';
import 'loudness_measure_runner.dart';
import 'loudness_measurement.dart';
import 'qc_loudness_measurement.dart';

/// One completed QC report.
class QcLoudnessReportData {
  /// The measured file.
  final String path;

  /// The plan, including rows that could not be measured.
  final List<QcLoudnessRow> rows;

  /// The measured rows, in plan order.
  final List<QcMeasuredRow> results;
  final DateTime measuredAt;

  const QcLoudnessReportData({
    required this.path,
    required this.rows,
    required this.results,
    required this.measuredAt,
  });
}

class QcLoudnessReportNotifier extends Notifier<QcLoudnessReportData?> {
  @override
  QcLoudnessReportData? build() => null;

  void set(QcLoudnessReportData data) => state = data;

  void clear() => state = null;
}

/// The last completed QC report, or null before the first run.
final qcLoudnessReportProvider =
    NotifierProvider<QcLoudnessReportNotifier, QcLoudnessReportData?>(
      QcLoudnessReportNotifier.new,
    );

/// The QC report for the file open in Playback mode, or null when there
/// is none or the stored one is for another path.
final currentQcLoudnessReportProvider = Provider<QcLoudnessReportData?>((ref) {
  final report = ref.watch(qcLoudnessReportProvider);
  final path = ref.watch(playbackSessionProvider.select((s) => s?.path));
  if (report == null || path == null || report.path != path) return null;
  return report;
});

class QcLoudnessMeasureRunner extends Notifier<LoudnessMeasureState> {
  /// Bumped by [discard]; a pass whose generation no longer matches
  /// drops its results when it stops.
  int _generation = 0;

  @override
  LoudnessMeasureState build() => const LoudnessMeasureState();

  /// Asks the running pass to stop after the rows it is on. No effect
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

  /// Drops the pass and the report. Called when the workspace leaves
  /// Playback: a running pass is cancelled and its results discarded
  /// when it stops, and the stored report and any error are cleared.
  void discard() {
    _generation++;
    ref.read(qcLoudnessReportProvider.notifier).clear();
    if (state.running) {
      cancel();
    } else {
      state = const LoudnessMeasureState();
    }
  }

  /// Measures every sub-mix of the loaded file at its declared layouts
  /// plus the monitoring layout, then stores the report. Returns when
  /// the pass has completed, been cancelled, or failed; [state] says
  /// which. Returns at once when a pass is already running.
  Future<void> run() async {
    if (state.running) return;

    final session = ref.read(playbackSessionProvider);
    final engine = ref.read(eclipsaStudioEngineProvider);
    if (engine == null) {
      state = const LoudnessMeasureState(error: 'Audio engine not available.');
      return;
    }
    if (session == null) {
      state = const LoudnessMeasureState(error: 'No IAMF file is open.');
      return;
    }
    final monitoringSs = soundSystemForOarValue(
      ref.read(monitoringConfigProvider).activeLayout.oarValue,
    );
    final rows = planQcLoudnessRows(
      session.report,
      monitoringLayout: monitoringSs,
    );
    if (rows.isEmpty) {
      state = const LoudnessMeasureState(
        error: 'Nothing to measure: the file has no mix presentations.',
      );
      return;
    }
    if (rows.every((r) => !r.measurable)) {
      final reason = rows.first.notMeasurableReason!;
      state = LoudnessMeasureState(
        error:
            'Nothing to measure: '
            '${reason[0].toLowerCase()}${reason.substring(1)}',
      );
      return;
    }
    final generation = _generation;

    // Stop transport and pause the live OAR for the duration of the
    // pass; the offline measurers' OAR instances must not overlap the
    // live one (ES-44, same discipline as the creator report).
    ref.read(playingProvider.notifier).set(false);
    engine.setExportPaused(true);
    state = const LoudnessMeasureState(running: true);

    try {
      final outcome = await measureQcLoudness(
        path: session.path,
        report: session.report,
        rows: rows,
        withTraces: true,
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
      // discard() ran, or the workspace left Playback: the results
      // belong to no open file now.
      if (generation != _generation ||
          ref.read(workspaceModeProvider) != WorkspaceMode.playback) {
        state = const LoudnessMeasureState();
        return;
      }
      switch (outcome.status) {
        case LoudnessPassStatus.cancelled:
          state = const LoudnessMeasureState();
          return;
        case LoudnessPassStatus.failed:
          state = LoudnessMeasureState(
            error: outcome.failedReason == null
                ? 'Loudness measurement failed for '
                      '${outcome.failedRowLabel}. Check the log for details.'
                : 'Loudness measurement failed for '
                      '${outcome.failedRowLabel}: ${outcome.failedReason}.',
          );
          return;
        case LoudnessPassStatus.completed:
          break;
      }
      ref
          .read(qcLoudnessReportProvider.notifier)
          .set(
            QcLoudnessReportData(
              path: session.path,
              rows: rows,
              results: outcome.results,
              measuredAt: DateTime.now(),
            ),
          );
      state = const LoudnessMeasureState();
    } catch (e, st) {
      Log.e(LogCat.export, 'QC Loudness Report exception: $e\n$st');
      state = generation == _generation
          ? LoudnessMeasureState(error: 'Measurement failed: $e')
          : const LoudnessMeasureState();
    } finally {
      engine.setExportPaused(false);
    }
  }
}

/// The one QC loudness pass the app runs at a time.
final qcLoudnessMeasureProvider =
    NotifierProvider<QcLoudnessMeasureRunner, LoudnessMeasureState>(
      QcLoudnessMeasureRunner.new,
    );

/// The running Loudness Report pass, QC or creator, or null when
/// neither runs. The status bar shows it in every workspace mode: a QC
/// pass keeps running after its dialog closes, and a pass discarded on
/// leaving Playback finishes its in-flight rows in the next workspace,
/// with transport blocked until it does.
final runningLoudnessMeasureProvider = Provider<LoudnessMeasureState?>((ref) {
  final qc = ref.watch(qcLoudnessMeasureProvider);
  final creator = ref.watch(loudnessMeasureProvider);
  if (qc.running) return qc;
  if (creator.running) return creator;
  return null;
});
