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

// Shared enums and constants for audio element configuration.
//
// Mirrors the C++ types defined in:
//   src/common/models/audio_element_types.h
//   src/common/models/loudspeaker_layouts.h

import 'layout_916.dart';

// ---------------------------------------------------------------------------
// Loudspeaker layouts
// ---------------------------------------------------------------------------

/// Loudspeaker layout for channel-based audio elements.
///
/// Based on ITU-R BS.2051-3 configurations. Channel counts match the
/// plugin's loudspeaker_layouts.h. A [k9_1_6] WAV is in the app's 9.1.6
/// order, OBR's alt order; see `layout_916.dart`.
enum LoudspeakerLayout {
  mono,
  stereo,
  k3_1_2,
  k5_1,
  k5_1_2,
  k5_1_4,
  k7_1,
  k7_1_2,
  k7_1_4,
  k9_1_6,
  k7_1_5_4,
  k10_2_9_3,
  binaural;

  /// Human-readable name shown in the UI.
  String get displayName {
    switch (this) {
      case LoudspeakerLayout.mono:
        return 'Mono';
      case LoudspeakerLayout.stereo:
        return 'Stereo';
      case LoudspeakerLayout.k3_1_2:
        return '3.1.2';
      case LoudspeakerLayout.k5_1:
        return '5.1';
      case LoudspeakerLayout.k5_1_2:
        return '5.1.2';
      case LoudspeakerLayout.k5_1_4:
        return '5.1.4';
      case LoudspeakerLayout.k7_1:
        return '7.1';
      case LoudspeakerLayout.k7_1_2:
        return '7.1.2';
      case LoudspeakerLayout.k7_1_4:
        return '7.1.4';
      case LoudspeakerLayout.k9_1_6:
        return kLayout916;
      case LoudspeakerLayout.k7_1_5_4:
        return '7.1.5.4';
      case LoudspeakerLayout.k10_2_9_3:
        return '10.2.9.3';
      case LoudspeakerLayout.binaural:
        return 'Binaural';
    }
  }

  /// Number of audio channels for this layout.
  int get channelCount {
    switch (this) {
      case LoudspeakerLayout.mono:
        return 1;
      case LoudspeakerLayout.stereo:
        return 2;
      case LoudspeakerLayout.k3_1_2:
        return 6;
      case LoudspeakerLayout.k5_1:
        return 6;
      case LoudspeakerLayout.k5_1_2:
        return 8;
      case LoudspeakerLayout.k5_1_4:
        return 10;
      case LoudspeakerLayout.k7_1:
        return 8;
      case LoudspeakerLayout.k7_1_2:
        return 10;
      case LoudspeakerLayout.k7_1_4:
        return 12;
      case LoudspeakerLayout.k9_1_6:
        return 16;
      case LoudspeakerLayout.k7_1_5_4:
        return 17;
      case LoudspeakerLayout.k10_2_9_3:
        return 24;
      case LoudspeakerLayout.binaural:
        return 2;
    }
  }

  /// Find a layout by its display name string, or return null.
  static LoudspeakerLayout? fromDisplayName(String name) {
    for (final v in LoudspeakerLayout.values) {
      if (v.displayName == name) return v;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Binaural enums
// ---------------------------------------------------------------------------

/// Binaural filter profile applied during rendering.
///
/// Declaration order matches the IAMF spec's `binaural_filter_profile`
/// field (AMBIENT=0, DIRECT=1, REVERBERANT=2) so `.index` can be passed
/// straight through the FFI as the spec value. The UI display order is
/// Direct / Ambient / Reverberant — driven by an explicit item list in
/// the selector, not by `.values` iteration.
enum BinauralProfile {
  ambient, // IAMF spec value 0 — authoring default (OAR alias).
  direct, // IAMF spec value 1.
  reverberant; // IAMF spec value 2.

  String get displayName {
    switch (this) {
      case BinauralProfile.ambient:
        return 'Ambient';
      case BinauralProfile.direct:
        return 'Direct';
      case BinauralProfile.reverberant:
        return 'Reverberant';
    }
  }

  static BinauralProfile fromString(String s) {
    // Ambient is the fallback because it's the authoring default
    // (matches OAR's ck_binaural_filter_profile_default and the IAMF
    // spec value 0).
    switch (s) {
      case 'Ambient':
        return BinauralProfile.ambient;
      case 'Direct':
        return BinauralProfile.direct;
      case 'Reverberant':
        return BinauralProfile.reverberant;
      default:
        return BinauralProfile.ambient;
    }
  }
}

/// Binaural presentation mode.
enum BinauralMode {
  worldLocked,
  headLocked;

  String get displayName {
    switch (this) {
      case BinauralMode.worldLocked:
        return 'World-locked';
      case BinauralMode.headLocked:
        return 'Head-locked';
    }
  }

  static BinauralMode fromString(String s) {
    if (s == 'Head-locked') return BinauralMode.headLocked;
    return BinauralMode.worldLocked;
  }
}

// ---------------------------------------------------------------------------
// Ambisonics helpers
// ---------------------------------------------------------------------------

/// Returns the channel count for an ambisonics order: (order + 1)^2.
int ambisonicsChannelCount(int order) {
  final n = order.clamp(1, 4);
  return (n + 1) * (n + 1);
}

// ---------------------------------------------------------------------------
// Channel-count constraints
// ---------------------------------------------------------------------------

/// A valid audio element configuration for a given channel count.
typedef ElementConfig = ({
  String label,
  String type,
  String? layout,
  int? ambisonicsOrder,
  bool? isDual,
});

/// Returns all valid (type, subtype) configurations for [channels] input
/// channels. Each entry can be applied directly to an [AudioElement].
///
/// **Ordering contract:** entries are sorted most-likely-first, and index 0
/// is the recommended default ([defaultConfigForChannelCount] returns it).
/// Ubiquitous interpretations (Stereo, 5.1, 7.1) outrank IAMF-specific
/// vertical variants (3.1.2, 5.1.2, 7.1.2), and deliberate-intent choices
/// (Binaural, Object) sort last — they are never good guesses. The element
/// format dialog, the track-panel selector, and the silent default all
/// present this order, so keep it intentional (ES-152).
List<ElementConfig> validConfigsForChannelCount(int channels) {
  switch (channels) {
    case 1:
      return [
        (
          label: 'Channel · Mono',
          type: 'Channel',
          layout: 'Mono',
          ambisonicsOrder: null,
          isDual: null,
        ),
        (
          label: 'Object · Mono',
          type: 'Object',
          layout: 'Mono',
          ambisonicsOrder: null,
          isDual: false,
        ),
      ];
    case 2:
      return [
        (
          label: 'Channel · Stereo',
          type: 'Channel',
          layout: 'Stereo',
          ambisonicsOrder: null,
          isDual: null,
        ),
        (
          label: 'Channel · Binaural',
          type: 'Channel',
          layout: 'Binaural',
          ambisonicsOrder: null,
          isDual: null,
        ),
        (
          label: 'Object · Dual',
          type: 'Object',
          layout: 'Dual',
          ambisonicsOrder: null,
          isDual: true,
        ),
      ];
    case 4:
      return [
        (
          label: 'Scene · 1OA',
          type: 'Scene',
          layout: '1OA',
          ambisonicsOrder: 1,
          isDual: null,
        ),
      ];
    case 6:
      return [
        (
          label: 'Channel · 5.1',
          type: 'Channel',
          layout: '5.1',
          ambisonicsOrder: null,
          isDual: null,
        ),
        (
          label: 'Channel · 3.1.2',
          type: 'Channel',
          layout: '3.1.2',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 8:
      return [
        (
          label: 'Channel · 7.1',
          type: 'Channel',
          layout: '7.1',
          ambisonicsOrder: null,
          isDual: null,
        ),
        (
          label: 'Channel · 5.1.2',
          type: 'Channel',
          layout: '5.1.2',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 9:
      return [
        (
          label: 'Scene · 2OA',
          type: 'Scene',
          layout: '2OA',
          ambisonicsOrder: 2,
          isDual: null,
        ),
      ];
    case 10:
      return [
        (
          label: 'Channel · 5.1.4',
          type: 'Channel',
          layout: '5.1.4',
          ambisonicsOrder: null,
          isDual: null,
        ),
        (
          label: 'Channel · 7.1.2',
          type: 'Channel',
          layout: '7.1.2',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 12:
      return [
        (
          label: 'Channel · 7.1.4',
          type: 'Channel',
          layout: '7.1.4',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 16:
      return [
        (
          label: 'Scene · 3OA',
          type: 'Scene',
          layout: '3OA',
          ambisonicsOrder: 3,
          isDual: null,
        ),
        // A 9.1.6 WAV in the app's order, OBR's alt order (L R C LFE Lw
        // Rw Lss Rss Lrs Rrs Ltf Rtf Lts Rts Ltr Rtr; models/
        // layout_916.dart).
        (
          label: 'Channel · 9.1.6',
          type: 'Channel',
          layout: kLayout916,
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 17:
      return [
        (
          label: 'Channel · 7.1.5.4',
          type: 'Channel',
          layout: '7.1.5.4',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 24:
      return [
        (
          label: 'Channel · 10.2.9.3',
          type: 'Channel',
          layout: '10.2.9.3',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
    case 25:
      return [
        (
          label: 'Scene · 4OA',
          type: 'Scene',
          layout: '4OA',
          ambisonicsOrder: 4,
          isDual: null,
        ),
      ];
    default:
      return [
        (
          label: 'Channel · Custom (${channels}ch)',
          type: 'Channel',
          layout: 'Custom (${channels}ch)',
          ambisonicsOrder: null,
          isDual: null,
        ),
      ];
  }
}

/// Returns the default configuration for [channels] input channels: the
/// first (most likely) entry of [validConfigsForChannelCount], per that
/// function's ordering contract.
///
/// Used when auto-assigning type on WAV import for counts with a single
/// interpretation — ambiguous counts go through the element format dialog
/// instead of this silent guess (ES-152). Never object-based: 1- and
/// 2-channel files list their channel-based reading first because that's
/// valid in every IAMF profile, whereas objects are rejected by Simple and
/// Base (ES-132).
ElementConfig defaultConfigForChannelCount(int channels) =>
    validConfigsForChannelCount(channels).first;

/// Output channel count implied by [cfg]; [fallback] covers unknown
/// (custom) layouts, whose count can't be derived from the label.
int elementConfigChannelCount(ElementConfig cfg, int fallback) {
  switch (cfg.type) {
    case 'Scene':
      return ambisonicsChannelCount(cfg.ambisonicsOrder ?? 1);
    case 'Object':
      return (cfg.isDual ?? false) ? 2 : 1;
    default:
      final ls = cfg.layout == null
          ? null
          : LoudspeakerLayout.fromDisplayName(cfg.layout!);
      return ls?.channelCount ?? fallback;
  }
}

/// Every element config a [wavChannels]-channel WAV can be opened as when
/// the input routing matrix is allowed to down-map channels — the superset
/// behind the routing dialog's format picker (ES-152).
///
/// Rules:
/// * Exact-count interpretations ([validConfigsForChannelCount]) come
///   first, in their canonical order.
/// * Channel beds with fewer channels than the WAV are routable (a subset
///   of source channels feeds the bed), widest first; equal-or-wider beds
///   never appear — they would seed silent speakers.
/// * Ambisonics can only be routed DOWN in order, never up: scene targets
///   are offered only when the WAV itself is an ambisonic channel count
///   (order+1)², for orders below its own (an ACN truncation). Missing
///   higher-order components cannot be synthesized, and non-ambisonic
///   sources have no soundfield to truncate.
/// * Deliberate-intent targets (Binaural, Object) sort last.
List<ElementConfig> routableConfigsForChannelCount(int wavChannels) {
  final result = [...validConfigsForChannelCount(wavChannels)];
  final seen = result.map((c) => c.label).toSet();
  void add(ElementConfig c) {
    if (seen.add(c.label)) result.add(c);
  }

  // Smaller channel beds, widest first. The count list covers every
  // LoudspeakerLayout channel count; per-count order is canonical.
  const bedCounts = [24, 17, 16, 12, 10, 8, 6, 2, 1];
  for (final count in bedCounts) {
    if (count >= wavChannels) continue;
    for (final cfg in validConfigsForChannelCount(count)) {
      if (cfg.type == 'Channel' && cfg.layout != 'Binaural') add(cfg);
    }
  }

  // Lower ambisonic orders — only from an ambisonic source count.
  final srcOrders = ambisonicsOrdersForChannelCount(wavChannels);
  if (srcOrders.isNotEmpty) {
    for (var order = srcOrders.single - 1; order >= 1; order--) {
      add((
        label: 'Scene · ${order}OA',
        type: 'Scene',
        layout: '${order}OA',
        ambisonicsOrder: order,
        isDual: null,
      ));
    }
  }

  // Deliberate-intent targets last (dedup covers the 2-channel case,
  // whose exact-count list already carries Binaural and Object · Dual).
  if (wavChannels > 1) {
    add(
      validConfigsForChannelCount(2).firstWhere((c) => c.layout == 'Binaural'),
    );
    add(validConfigsForChannelCount(1).firstWhere((c) => c.type == 'Object'));
    add(validConfigsForChannelCount(2).firstWhere((c) => c.type == 'Object'));
  }
  return result;
}

/// The complete element-config universe: every channel bed, every
/// ambisonic order, and both object configs — regardless of source
/// channel count. Pickers that de-emphasize unnatural pairings (rather
/// than hiding them) append the universe after the routable set so
/// the option list stays stable and self-explanatory (ES-152).
///
/// Order: channel beds in [LoudspeakerLayout] declaration order
/// (roughly ascending width, Binaural last), scenes ascending, then
/// objects. Labels match [validConfigsForChannelCount] exactly so
/// dedup-by-label works.
List<ElementConfig> allElementConfigs() {
  return [
    for (final l in LoudspeakerLayout.values)
      (
        label: 'Channel · ${l.displayName}',
        type: 'Channel',
        layout: l.displayName,
        ambisonicsOrder: null,
        isDual: null,
      ),
    for (var order = 1; order <= 4; order++)
      (
        label: 'Scene · ${order}OA',
        type: 'Scene',
        layout: '${order}OA',
        ambisonicsOrder: order,
        isDual: null,
      ),
    (
      label: 'Object · Mono',
      type: 'Object',
      layout: 'Mono',
      ambisonicsOrder: null,
      isDual: false,
    ),
    (
      label: 'Object · Dual',
      type: 'Object',
      layout: 'Dual',
      ambisonicsOrder: null,
      isDual: true,
    ),
  ];
}

/// Caveat for picking [cfg] over a [wavChannels]-channel source, or
/// null when the pairing is a natural fit (the config is in the
/// [routableConfigsForChannelCount] set).
///
/// Every format is *selectable* (the matrix represents any pairing —
/// missing sources become silent rows); this explains what the
/// unnatural pairings actually do, so pickers can surface it as a
/// tooltip on de-emphasized options instead of hard-gating them. Scene
/// targets consume routed channels as ambisonic components (ACN
/// ordering); wider beds and objects leave unrouted channels silent.
String? configMismatchCaveat(ElementConfig cfg, int wavChannels) {
  final routable = routableConfigsForChannelCount(
    wavChannels,
  ).any((c) => c.label == cfg.label);
  if (routable) return null;
  if (cfg.type == 'Scene') {
    return 'Routed source channels are used as ambisonic components in '
        'ACN/SN3D (ACN 0, ACN 1, …). This type is intended for ambisonic '
        'sources.';
  }
  return 'Wider than the ${wavChannels}ch source, so unrouted channels '
      'stay silent.';
}

/// Returns valid ambisonics orders for [channels].
List<int> ambisonicsOrdersForChannelCount(int channels) {
  return [
    1,
    2,
    3,
    4,
  ].where((o) => ambisonicsChannelCount(o) == channels).toList();
}
