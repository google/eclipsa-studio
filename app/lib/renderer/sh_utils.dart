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

/// Directivity patterns for SH decoding, matching
/// eclipsa-audio-plugins `DirectivityType`.
enum ShDirectivity {
  /// No directivity weighting — raw SH decode.
  basic('Basic'),

  /// Maximum energy concentration (sharper lobes).
  maxRe('Max rE'),

  /// In-phase decoding (no negative sidelobes).
  inPhase('In-phase');

  final String label;
  const ShDirectivity(this.label);

  static ShDirectivity byName(String name) =>
      values.firstWhere((v) => v.name == name, orElse: () => inPhase);
}

/// Minimal SH helpers — all heavy math (decode, encode, Legendre,
/// normalization) lives in the C++ engine via [NativeShDecoder].
class ShUtils {
  ShUtils._();

  /// Number of channels for a given ambisonic order: (order+1)^2.
  static int channelCount(int order) => (order + 1) * (order + 1);
}
