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

import 'dart:math' as math;

/// Per-element signal-overload statistics from an engine stream run
/// (the offline measure pass or the IAMF encode pass).
///
/// A sample counts as clipped when |x| is strictly above 1.0 — past
/// what the encoder's ±1.0 clamp preserves losslessly; exactly ±1.0 is
/// legitimate full-scale integer content. Plain finals only, so
/// instances cross isolate boundaries.
class ElementClipStats {
  const ElementClipStats({
    required this.clippedSamples,
    required this.peakLinear,
  });

  /// Count of delivered samples with |x| > 1.0.
  final int clippedSamples;

  /// Largest |sample| delivered, linear magnitude (0 for silence).
  final double peakLinear;

  bool get clipped => clippedSamples > 0;

  /// Peak in dBFS (20·log10); negative infinity for silence.
  double get peakDbfs => peakLinear > 0
      ? 20 * math.log(peakLinear) / math.ln10
      : double.negativeInfinity;
}

/// Max-merges two per-element-id stats maps. Renders of the same
/// element share an identical stream config (source, gain, routing,
/// pad, rate), so counts should agree across renders; taking the max
/// is defensive against pad-length differences between layout cells.
Map<int, ElementClipStats> mergeElementClipStats(
  Map<int, ElementClipStats> a,
  Map<int, ElementClipStats> b,
) {
  final merged = Map<int, ElementClipStats>.of(a);
  for (final entry in b.entries) {
    final prev = merged[entry.key];
    if (prev == null) {
      merged[entry.key] = entry.value;
    } else {
      merged[entry.key] = ElementClipStats(
        clippedSamples: math.max(
          prev.clippedSamples,
          entry.value.clippedSamples,
        ),
        peakLinear: math.max(prev.peakLinear, entry.value.peakLinear),
      );
    }
  }
  return merged;
}

/// Formats a dBFS peak as a signed one-decimal label, e.g. '+2.3 dBFS'.
String formatPeakDbfs(double dbfs) {
  if (dbfs.isInfinite || dbfs.isNaN) return 'silent';
  // isNegative (not >= 0): -0.0 stringifies as "-0.0" and would render
  // "+-0.0 dBFS" under a >= comparison.
  final sign = dbfs.isNegative ? '' : '+';
  return '$sign${dbfs.toStringAsFixed(1)} dBFS';
}
