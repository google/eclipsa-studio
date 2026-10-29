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

import '../models/audio_element_enums.dart' show BinauralProfile;
import '../state.dart' show HeadphonesRenderingMode, IamfProfile, SoundSystem;

/// Eclipsa Studio → iamf-tools enum / name mappings used by the textproto
/// builder. Isolated here so the builder stays focused on structure.
///
/// Names mirror the IAMF spec textproto constants exactly
/// (`SOUND_SYSTEM_A_0_2_0`, `LOUDSPEAKER_LAYOUT_STEREO`, etc.). If a
/// constant ever doesn't parse, fix it here — everywhere else in the
/// builder just concatenates the result into the output.

// ── Profile ─────────────────────────────────────────────────────────────

/// iamf-tools `ProfileVersion` enum name for a given Eclipsa Studio profile.
String iamfProfileName(IamfProfile p) {
  switch (p) {
    case IamfProfile.simple:
      return 'PROFILE_VERSION_SIMPLE';
    case IamfProfile.base:
      return 'PROFILE_VERSION_BASE';
    case IamfProfile.baseEnhanced:
      return 'PROFILE_VERSION_BASE_ENHANCED';
    case IamfProfile.baseAdvanced:
      return 'PROFILE_VERSION_BASE_ADVANCED';
    case IamfProfile.advanced1:
      return 'PROFILE_VERSION_ADVANCED1';
    case IamfProfile.advanced2:
      return 'PROFILE_VERSION_ADVANCED2';
  }
}

// ── Sound system ────────────────────────────────────────────────────────

/// iamf-tools `SoundSystem` enum name for a given Eclipsa Studio SoundSystem,
/// derived from the element's ITU notation. Returns null for layouts
/// that have no SS convention equivalent (e.g. binaural, which must be
/// emitted via `LAYOUT_TYPE_BINAURAL` instead).
String? iamfSoundSystemName(SoundSystem s) {
  // IAMF's SoundSystem enum follows "<letter>_<top>_<middle>_<bottom>"
  // naming (A_0_2_0 = stereo). Eclipsa Studio stores the
  // "<top>+<middle>+<bottom>" notation on the enum, which matches 1:1
  // for every SS-convention layout. Binaural is a layout type, not a sound system.
  switch (s) {
    case SoundSystem.stereo:
      return 'SOUND_SYSTEM_A_0_2_0';
    case SoundSystem.mono:
      return 'SOUND_SYSTEM_12_0_1_0';
    case SoundSystem.surround5_1:
      return 'SOUND_SYSTEM_B_0_5_0';
    case SoundSystem.surround5_1_2:
      return 'SOUND_SYSTEM_C_2_5_0';
    case SoundSystem.surround5_1_4:
      return 'SOUND_SYSTEM_D_4_5_0';
    case SoundSystem.surround7_1:
      return 'SOUND_SYSTEM_I_0_7_0';
    case SoundSystem.surround7_1_2:
      return 'SOUND_SYSTEM_10_2_7_0';
    case SoundSystem.surround7_1_4:
      return 'SOUND_SYSTEM_J_4_7_0';
    case SoundSystem.surround3_1_2:
      return 'SOUND_SYSTEM_11_2_3_0';
    case SoundSystem.surround9_1_6:
      return 'SOUND_SYSTEM_13_6_9_0';
    case SoundSystem.surround7_1_5_4:
      return 'SOUND_SYSTEM_14_5_7_4';
    case SoundSystem.surround10_2_9_3:
      return 'SOUND_SYSTEM_H_9_10_3';
    case SoundSystem.binaural:
      return null;
  }
}

// ── Loudspeaker layout (for channel-based audio_element) ────────────────

/// iamf-tools `LoudspeakerLayout` enum name for an Eclipsa Studio Channel
/// element's layout string. Returns null for layouts with no direct
/// mapping (expanded layouts like 9.1.6 that require `EXPANDED` +
/// `ExpandedLoudspeakerLayout`).
String? loudspeakerLayoutName(String layout) {
  switch (layout.toLowerCase()) {
    case 'mono':
      return 'LOUDSPEAKER_LAYOUT_MONO';
    case 'stereo':
      return 'LOUDSPEAKER_LAYOUT_STEREO';
    case '3.1.2':
      return 'LOUDSPEAKER_LAYOUT_3_1_2_CH';
    case '5.1':
      return 'LOUDSPEAKER_LAYOUT_5_1_CH';
    case '5.1.2':
      return 'LOUDSPEAKER_LAYOUT_5_1_2_CH';
    case '5.1.4':
      return 'LOUDSPEAKER_LAYOUT_5_1_4_CH';
    case '7.1':
      return 'LOUDSPEAKER_LAYOUT_7_1_CH';
    case '7.1.2':
      return 'LOUDSPEAKER_LAYOUT_7_1_2_CH';
    case '7.1.4':
      return 'LOUDSPEAKER_LAYOUT_7_1_4_CH';
    case 'binaural':
      return 'LOUDSPEAKER_LAYOUT_BINAURAL';
    default:
      // Expanded layouts (9.1.6, 7.1.5.4, 10.2.9.3) have no direct
      // LoudspeakerLayout enum — the caller emits LOUDSPEAKER_LAYOUT_EXPANDED
      // plus an ExpandedLoudspeakerLayout from expandedLoudspeakerLayoutName.
      return null;
  }
}

/// iamf-tools `ExpandedLoudspeakerLayout` enum name for an expanded channel
/// layout (the ones [loudspeakerLayoutName] returns null for). Emitted in
/// `expanded_loudspeaker_layout` alongside
/// `loudspeaker_layout: LOUDSPEAKER_LAYOUT_EXPANDED`.
///
/// Returns null for expanded layouts not yet wired for export — only 9.1.6 is
/// fully supported end-to-end (substream grouping + channel labels) today.
/// 7.1.5.4 and 10.2.9.3 have valid enum names but are not yet rendered/labelled
/// for export, so they stay null until that work lands (the builder raises a
/// clear error rather than emit an unencodable bitstream).
String? expandedLoudspeakerLayoutName(String layout) {
  switch (layout.toLowerCase()) {
    case '9.1.6':
      return 'EXPANDED_LOUDSPEAKER_LAYOUT_9_1_6_CH';
    default:
      return null;
  }
}

// ── Headphones rendering mode ───────────────────────────────────────────

/// iamf-tools `HeadPhonesRenderingMode` enum name.
String headphonesRenderingModeName(HeadphonesRenderingMode m) {
  switch (m) {
    case HeadphonesRenderingMode.stereo:
      return 'HEADPHONES_RENDERING_MODE_STEREO';
    case HeadphonesRenderingMode.binauralWorldLocked:
      return 'HEADPHONES_RENDERING_MODE_BINAURAL_WORLD_LOCKED';
    case HeadphonesRenderingMode.binauralHeadLocked:
      return 'HEADPHONES_RENDERING_MODE_BINAURAL_HEAD_LOCKED';
  }
}

/// iamf-tools `BinauralFilterProfile` enum name.
String binauralFilterProfileName(BinauralProfile p) {
  switch (p) {
    case BinauralProfile.ambient:
      return 'BINAURAL_FILTER_PROFILE_AMBIENT';
    case BinauralProfile.direct:
      return 'BINAURAL_FILTER_PROFILE_DIRECT';
    case BinauralProfile.reverberant:
      return 'BINAURAL_FILTER_PROFILE_REVERBERANT';
  }
}

// ── SoundSystem → oar_layout_t ──────────────────────────────────────

/// Maps an Eclipsa Studio SoundSystem to an `oar_layout_t` value for offline
/// rendering. Values must match `oar_layout_t` in oar.h — they are declared
/// in ascending order below so a gap is visible on sight. Null is reserved
/// for a future SoundSystem OAR cannot render as a target; every layout we
/// ship today maps (pinned by iamf_format_maps_test.dart).
int? soundSystemToOarLayout(SoundSystem s) {
  switch (s) {
    case SoundSystem.mono:
      return 1;
    case SoundSystem.stereo:
      return 2;
    case SoundSystem.surround5_1:
      return 3;
    case SoundSystem.surround5_1_2:
      return 4;
    case SoundSystem.surround5_1_4:
      return 5;
    case SoundSystem.surround7_1:
      return 6;
    case SoundSystem.surround7_1_2:
      return 7;
    case SoundSystem.surround7_1_4:
      return 8;
    case SoundSystem.surround3_1_2:
      return 9;
    case SoundSystem.surround9_1_6:
      return 10;
    case SoundSystem.surround10_2_9_3:
      // ck_oar_layout_a293, aliased ck_oar_layout_sound_system_h_9a3 — a
      // combined element/target layout, not one of the target-only
      // systems (E/F/G at 0x81+).
      return 11;
    case SoundSystem.surround7_1_5_4:
      return 12;
    case SoundSystem.binaural:
      return 0xFF;
  }
}

/// Inverse of [soundSystemToOarLayout]: the [SoundSystem] rendered by an
/// `oar_layout_t` value, or null for values without a SoundSystem
/// equivalent. Used to fold the monitoring target (an `OarLayout`) into
/// SoundSystem-keyed measurement plans.
SoundSystem? soundSystemForOarValue(int oarValue) {
  for (final s in SoundSystem.values) {
    if (soundSystemToOarLayout(s) == oarValue) return s;
  }
  return null;
}
