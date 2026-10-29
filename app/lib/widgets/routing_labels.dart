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

import '../waveform/multi_channel_waveform.dart' show standardChannelLabel;

/// Return per-channel labels for an IAMF channel layout.
///
/// [standardChannelLabel] disambiguates by channel count, which is
/// correct for most layouts but ambiguous for:
///   - 6-channel: 5.1 vs 3.1.2
///   - 8-channel: 7.1 vs 5.1.2
///   - 10-channel: 5.1.4 vs 7.1.2
///
/// This helper takes an explicit [layoutHint] (e.g. "3.1.2",
/// "7.1.2", "5.1.2") and overrides for those ambiguous cases;
/// everything else falls through to the count-based default.
///
/// Channel orders match OBR's authoritative layout map in
/// the `oar` Bazel module
/// (`obr_src/obr/renderer/loudspeaker_layouts.h`), and are pinned per
/// layout against `engine/renderer/channel_layouts.txt` in
/// `test/renderer/channel_layouts_test.dart` — passing a layout's
/// own id as [layoutHint] must return that layout's labels (ES-592).
List<String> iamfChannelLabels({
  required int channelCount,
  String? layoutHint,
}) {
  final hint = (layoutHint ?? '').toLowerCase();

  // Ambiguous-by-count overrides (order of checks matters — longer
  // strings like "5.1.2" must be tested before "5.1").
  if (hint.contains('3.1.2') && channelCount == 6) {
    // OBR: L30 R30 C LFE UL45 UR45.
    return const ['L', 'R', 'C', 'LFE', 'Ltf', 'Rtf'];
  }
  if (hint.contains('5.1.2') && channelCount == 8) {
    // OBR: L30 R30 C LFE L110 R110 UL30 UR30.
    return const ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Ltf', 'Rtf'];
  }
  if (hint.contains('7.1.2') && channelCount == 10) {
    // OBR: L30 R30 C LFE L90 R90 L135 R135 UL45 UR45.
    return const [
      'L', 'R', 'C', 'LFE', 'Lss', 'Rss', 'Lrs', 'Rrs', 'Ltf', 'Rtf', //
    ];
  }

  // Default: reuse the waveform widget's standard IAMF labels.
  return List.generate(
    channelCount,
    (i) => standardChannelLabel(i, channelCount),
  );
}

/// ACN labels for a scene element of the given ambisonics order.
List<String> ambisonicsOrderLabels(int order) {
  final n = (order + 1) * (order + 1);
  return List.generate(n, (i) => 'ACN $i');
}
