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

// Channel-bed renderer: canonical Scene -> loudspeaker-layout PCM.
//
// Implements the geometry-driven bed conversion of research §6.3 ("map what
// maps, render the rest"):
//   * a source coincident with a target speaker passes through bit-exact
//     (validated clean by the Phase 0 OLR spike);
//   * an LFE source routes straight to the target LFE channel;
//   * any other source is rendered as a static OLR object at its true (az, el),
//     phantom-split across the nearest target speakers;
//   * target speakers with no contributing source stay silent.
// The importer renders to one layout, ImportLayout() (7.1.4); the renderer
// itself is written against the Layout struct.
//
// Cartesian-authored object positions convert to polar here, per block, with
// OAR's layout-anchored conversion (oar_cartesian_to_polar + anchors derived
// from the target layout), so room-cube walls and corners pin to this
// layout's real speakers. OAR itself is always fed polar metadata (ES-567).

#ifndef ADM2IAMF_RENDER_CHANNEL_RENDERER_H_
#define ADM2IAMF_RENDER_CHANNEL_RENDERER_H_

#include <cstdint>
#include <memory>
#include <vector>

#include "absl/status/statusor.h"
#include "adm_import/render/render_progress.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"

namespace adm2iamf {

// How sources were handled (diagnostics / tests).
struct RenderStats {
  int passthrough = 0;      // Bed channel coincident with a target speaker.
  int lfe = 0;              // Bed channel routed to the target LFE.
  int olr = 0;              // Bed channel phantom-rendered through OLR.
  int objects = 0;          // Dynamic objects rendered through OLR.
  int objects_dropped = 0;  // Objects filtered out below the importance floor.
};

// Renders `scene` (bed + dynamic objects) to `layout`. `input_tracks` holds the
// planar PCM of the source WAV indexed by (track_index - 1). Objects with ADM
// importance < `importance_threshold` are skipped. Returns planar PCM in
// `layout`'s channel order (== OAR's order), all channels of equal length.
//
// `progress`, when non-null, is reported once per render block and polled for
// cancellation (returns `absl::CancelledError` if cancelled mid-render).
absl::StatusOr<std::vector<std::vector<float>>> RenderChannelBed(
    const Scene& scene, const Layout& layout,
    const std::vector<std::vector<float>>& input_tracks, uint32_t sample_rate,
    int importance_threshold = 0, RenderStats* stats = nullptr,
    const RenderProgress* progress = nullptr);

// Owning handle for a layout's cartesian->polar anchors. oar.h documents the
// handle as layout-only, immutable and thread-safe to share.
using AnchorsHandle = std::unique_ptr<oar_position_anchors_t,
                                      decltype(&oar_position_anchors_destroy)>;

// Derives `layout`'s anchors (oar_position_anchors_create: no oar_t, no
// audio state). NULL only on allocation failure or a layout the derivation
// does not know (none today). RenderChannelBed and the probe both derive
// their handle here and refuse to run without one, so preview and bake never
// silently convert with different maps (ES-607).
AnchorsHandle MakeAnchors(const Layout& layout);

// Converts an object position to egocentric polar. Polar positions pass
// through untouched. Cartesian positions convert through OAR's public helper:
// with `anchors`, the layout-anchored map; with NULL, the fixed BS.2127
// section 10 sector map — the fallback oar.h prescribes for a failed anchor
// derivation (kept for the helper's contract; production callers pass a
// handle from MakeAnchors).
//
// This is the ONE production cart->polar conversion path: Eclipsa Studio
// never passes cartesian-typed metadata into an oar_t or sets a conversion
// mode on one (ES-567; sole exception is the equivalence canary test).
Polar ConvertObjectPosition(const ObjectPosition& p,
                            const oar_position_anchors_t* anchors);

}  // namespace adm2iamf

#endif  // ADM2IAMF_RENDER_CHANNEL_RENDERER_H_
