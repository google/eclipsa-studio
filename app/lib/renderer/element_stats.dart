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

import 'dart:typed_data';

import '../ffi_bridge.dart' show kStatsCorrMaxChannels, statsCorrIndex;

/// Renderer-agnostic snapshot of one channel-based element's channel stats.
///
/// Populated once per frame from [EclipsaStudioMeterData.stats_*] via
/// [EclipsaStudioEngine.readElementStats]. Visualizer modules consume this
/// instead of touching the FFI directly — keeps the scene-building
/// pipeline library-agnostic and testable with synthetic data.
class ElementStats {
  /// Number of active channels for this element (<= 28). Mutated in
  /// place each frame by [EclipsaStudioEngine.readElementStats] when the
  /// entry is pool-reused, so callers must not cache across frames.
  int channelCount;

  /// Short-window linear power per channel (EMA-smoothed). Buffer length
  /// is fixed at the FFI max (28) for pool reuse; only [channelCount]
  /// entries are valid — consumers must clamp to that.
  final Float32List energy;

  /// Coherence against the element sum, per channel, per band (|γ|², 0..1).
  /// Same length convention as [energy].
  final Float32List cohLo;
  final Float32List cohMid;
  final Float32List cohHi;

  /// 1 if a transient onset was detected within the last hold window.
  final Uint8List onset;

  /// Packed upper-triangular correlation, NxN with N = [kStatsCorrMaxChannels].
  /// Use [correlation] to read by (i, j) without worrying about packing.
  /// Length is always [kStatsCorrPairs].
  final Float32List corr;

  ElementStats({
    required this.channelCount,
    required this.energy,
    required this.cohLo,
    required this.cohMid,
    required this.cohHi,
    required this.onset,
    required this.corr,
  });

  /// Empty placeholder — used when an element is missing or inactive.
  factory ElementStats.empty() {
    final empty = Float32List(0);
    return ElementStats(
      channelCount: 0,
      energy: empty,
      cohLo: empty,
      cohMid: empty,
      cohHi: empty,
      onset: Uint8List(0),
      corr: empty,
    );
  }

  /// Returns true when the stats block has no usable data.
  bool get isEmpty => channelCount == 0;

  /// Correlation between channels [i] and [j]. Returns 0 when either
  /// index is outside the correlation-tracked range
  /// ([kStatsCorrMaxChannels]) — callers should treat that as "unknown"
  /// rather than "uncorrelated."
  double correlation(int i, int j) {
    if (i == j) return 1.0;
    final idx = statsCorrIndex(i, j);
    if (idx < 0 || idx >= corr.length) return 0.0;
    return corr[idx];
  }
}
