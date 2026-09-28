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

/// In-memory store for the last Loudness Report measurement (ES-195).
///
/// Results (scalars + traces) live for the app run only — traces are
/// never persisted to the session file. The scalar triplet additionally
/// flows into [MixLayout.loudness] when a report completes (same as an
/// export's measure phase), which IS session-persisted.
///
/// [LoudnessReportData.fingerprint] captures the measurement inputs via
/// `loudnessFingerprint()`; consumers compare it against the live
/// session's fingerprint to detect staleness (report shows a banner,
/// export decides whether it can skip its own measure phase).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../export/element_clip_stats.dart';
import '../export/iamf_export_config.dart' show kIamfTargetSampleRate;
import '../export/iamf_format_maps.dart';
import '../state.dart';
import 'loudness_fingerprint.dart';
import 'loudness_measurement.dart';

/// One completed report run.
class LoudnessReportData {
  final List<MeasuredLayoutLoudness> results;
  final String fingerprint;
  final DateTime measuredAt;
  final int sampleRate;

  /// Per-element signal-overload stats from the measure pass, keyed by
  /// element id (ES-470). Carried so an export that reuses this report
  /// (skipping its own measure phase) can still run the overload gate.
  /// Valid exactly as long as [fingerprint] matches — the fingerprint
  /// covers the measurement inputs (sources, gains). Surfacing these in
  /// the Loudness Report window itself is a follow-up.
  final Map<int, ElementClipStats> elementClipStats;

  const LoudnessReportData({
    required this.results,
    required this.fingerprint,
    required this.measuredAt,
    required this.sampleRate,
    required this.elementClipStats,
  });

  /// True when [results] contains a tagged measurement for every
  /// OAR-renderable layout of every sub-mix in [mixes] — the condition
  /// for an export to reuse this report instead of re-measuring.
  /// A layout OAR cannot render as a target is exempt: the export's own
  /// measure pass skips it identically. No shipped layout is exempt today.
  bool coversAllTaggedLayouts(List<Mix> mixes) {
    for (final mix in mixes) {
      for (var subIdx = 0; subIdx < mix.subMixes.length; subIdx++) {
        for (final layout in mix.subMixes[subIdx].layouts) {
          if (soundSystemToOarLayout(layout.soundSystem) == null) continue;
          final covered = results.any(
            (r) =>
                r.taggedInMix &&
                r.mixId == mix.id &&
                r.subMixIndex == subIdx &&
                r.soundSystem == layout.soundSystem,
          );
          if (!covered) return false;
        }
      }
    }
    return true;
  }
}

/// Whether [report] can substitute for an export's measure phase.
///
/// True only when every condition holds:
/// - the export renders the full timeline ([isPartialRange] false) —
///   cached measurements cover the whole session, and a clamped MP4
///   export must re-measure over what actually ships (R128);
/// - the report was measured at the export's [sampleRate];
/// - [currentFingerprint] (the live session's `loudnessFingerprint()`)
///   matches the report's — no measurement input changed since;
/// - the report has a tagged result for every renderable layout of
///   every sub-mix in [mixes].
bool canReuseLoudnessReport({
  required LoudnessReportData? report,
  required String currentFingerprint,
  required int sampleRate,
  required bool isPartialRange,
  required List<Mix> mixes,
}) {
  return !isPartialRange &&
      report != null &&
      report.sampleRate == sampleRate &&
      report.fingerprint == currentFingerprint &&
      report.coversAllTaggedLayouts(mixes);
}

class LoudnessReportNotifier extends Notifier<LoudnessReportData?> {
  @override
  LoudnessReportData? build() => null;

  void set(LoudnessReportData data) => state = data;

  void clear() => state = null;
}

/// The last completed report, or null before the first run.
final loudnessReportProvider =
    NotifierProvider<LoudnessReportNotifier, LoudnessReportData?>(
      LoudnessReportNotifier.new,
    );

/// The live session's loudness fingerprint: `loudnessFingerprint()` over
/// the current elements and mixes at the export sample rate. A report
/// whose [LoudnessReportData.fingerprint] equals it is current; any
/// other is stale. The one place the live value is computed, so the
/// runner that stamps a report, the surfaces that compare against it
/// and the export's reuse check cannot drift.
final currentLoudnessFingerprintProvider = Provider<String>(
  (ref) => loudnessFingerprint(
    elements: ref.watch(elementsProvider),
    mixes: ref.watch(mixesNotifierProvider),
    sampleRate: kIamfTargetSampleRate,
  ),
);
