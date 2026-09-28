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

/// Programme loudness for the Mix view (ES-615): the integrated loudness
/// and true peak that describe the programme, as opposed to the live
/// meters under the Renderer view, which describe whatever has played
/// since the last stop.
///
/// The source is the last Loudness Report for the active mix and
/// sub-mix, which is also what the export writes into the IAMF file.
/// The report measures each tagged layout separately, so the figures
/// are keyed by layout and shown per layout on the LAYOUTS bar; a
/// fingerprint mismatch marks them stale. The lookup is a pure function
/// so it is unit-testable; [programmeLoudnessByLayoutProvider] wires it
/// to the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import 'loudness_report_provider.dart';

/// A report scalar for display: one decimal with [unit], or an em dash
/// for the -120 floor the offline renderer returns for a silent
/// programme. The Loudness Report grid and the Mix view's layout chips
/// format the same measurement through this, so one reading cannot
/// show two ways.
String formatProgrammeScalar(double v, {required String unit}) =>
    v <= -120 ? '—' : '${v.toStringAsFixed(1)} $unit';

/// One programme-level reading, with what it describes.
class ProgrammeLoudness {
  const ProgrammeLoudness({
    required this.integratedLufs,
    required this.truePeakDbtp,
    required this.layoutLabel,
    required this.writtenToFile,
    required this.stale,
  });

  final double integratedLufs;
  final double truePeakDbtp;

  /// The layout the reading is for, for display.
  final String layoutLabel;

  /// True when this reading is written into the IAMF file: a layout
  /// tagged in the mix presentation. False for a monitoring-only row of
  /// the report, measured for reference.
  final bool writtenToFile;

  /// The session changed since the report was measured.
  final bool stale;
}

/// Every report row for [mixId] / [subMixIndex], keyed by layout, so
/// the Mix view's LAYOUTS bar can put each layout's own figures beside
/// it. Empty without a report or rows.
Map<SoundSystem, ProgrammeLoudness> programmeLoudnessByLayout({
  required LoudnessReportData? report,
  required bool stale,
  required int mixId,
  required int subMixIndex,
}) {
  if (report == null) return const {};
  return {
    for (final r in report.results)
      if (r.mixId == mixId && r.subMixIndex == subMixIndex)
        r.soundSystem: ProgrammeLoudness(
          integratedLufs: r.scalars.integratedLufs,
          truePeakDbtp: r.scalars.truePeakDbtp,
          layoutLabel: r.soundSystem.uiLabel,
          writtenToFile: r.taggedInMix,
          stale: stale,
        ),
  };
}

/// Per-layout state for the Mix view's LAYOUTS bar: null before the
/// first report; otherwise every measured layout of the active mix and
/// sub-mix, with whether the session changed since the measurement, so
/// each layout chip carries its own figures and the bar marks them
/// stale together. Recomputes only when its inputs change, never per
/// frame.
final programmeLoudnessByLayoutProvider =
    Provider<({Map<SoundSystem, ProgrammeLoudness> byLayout, bool stale})?>((
      ref,
    ) {
      final mixes = ref.watch(mixesNotifierProvider);
      if (mixes.isEmpty) return null;
      final mix =
          mixes[ref.watch(activeMixProvider).clamp(0, mixes.length - 1)];
      if (mix.subMixes.isEmpty) return null;
      final subIdx = ref
          .watch(activeSubMixProvider)
          .clamp(0, mix.subMixes.length - 1);
      final report = ref.watch(loudnessReportProvider);
      if (report == null) return null;
      final stale =
          report.fingerprint != ref.watch(currentLoudnessFingerprintProvider);
      return (
        byLayout: programmeLoudnessByLayout(
          report: report,
          stale: stale,
          mixId: mix.id,
          subMixIndex: subIdx,
        ),
        stale: stale,
      );
    });
