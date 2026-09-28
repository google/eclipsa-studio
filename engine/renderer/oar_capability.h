/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef ECLIPSA_STUDIO_RENDERER_OAR_CAPABILITY_H_
#define ECLIPSA_STUDIO_RENDERER_OAR_CAPABILITY_H_

#include <cstdint>
#include <optional>

// Single authority for "does OAR have an element sub-renderer for this
// IAMF audio element?" (issue ES-330). Both the playback-open OAR
// registration (engine.cc) and the probe's per-AE `renderable` flag
// (iamf/iamf_probe_ffi.cc) answer through these helpers, so the two can
// never drift apart.
//
// Channel layouts are keyed on the RAW CODED values from the Audio
// Element OBU — `loudspeaker_layout` (0=Mono … 9=Binaural, 15=Expanded)
// and `expanded_loudspeaker_layout` (0=LFE … 19=Top-5ch) — as carried by
// both upstream vocabularies (`AudioElementDescriptor::
// loudspeaker_layout_raw` on the stream side, `AudioElementReport::
// channel_layout_raw` on the probe side). Raw coded values are
// spec-stable and, unlike `OutputLayout`, identify every Expanded
// sub-layout.

/// oar_layout_t value for an IAMF-coded channel layout, or nullopt when
/// OAR has no element sub-renderer for it (reserved values). Binaural
/// (coded 9) maps to OAR's stereo element layout — the same shape the
/// authoring path registers for channel-binaural beds: OBR renders a
/// stereo bed on loudspeaker targets and honours the element's
/// headphones_rendering_mode on the binaural target.
std::optional<int> OarSubTypeForCodedChannelLayout(
    int32_t loudspeaker_layout_raw, int32_t expanded_loudspeaker_layout_raw);

/// oar_hoa_t value for a scene AE of the given ambisonics order, or
/// nullopt outside OAR's 0–4 range (5OA and up cannot occur in a valid
/// v1.x file anyway — Base-Enhanced caps an AE at 28 channels).
std::optional<int> OarSubTypeForAmbisonicsOrder(int32_t order);

/// Kind-dispatching convenience over the two helpers above.
///   - kind 0 (channel): keyed on the raw coded layout pair.
///   - kind 1 (scene):   keyed on `ambisonics_order`.
///   - kind 2 (object) and anything else: nullopt — the pull graph has
///     no object feed path yet.
std::optional<int> OarSubTypeForElement(int32_t kind,
                                        int32_t loudspeaker_layout_raw,
                                        int32_t expanded_loudspeaker_layout_raw,
                                        int32_t ambisonics_order);

#endif  // ECLIPSA_STUDIO_RENDERER_OAR_CAPABILITY_H_
