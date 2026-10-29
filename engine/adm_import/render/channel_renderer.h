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

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

#include "absl/status/status.h"
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
// `progress`, when non-null, is reported once per chunk of 65536 frames and
// polled for cancellation (returns `absl::CancelledError` if cancelled
// mid-render). Runs RenderChannelBedStreamed, so it uses the same threads.
absl::StatusOr<std::vector<std::vector<float>>> RenderChannelBed(
    const Scene& scene, const Layout& layout,
    const std::vector<std::vector<float>>& input_tracks, uint32_t sample_rate,
    int importance_threshold = 0, RenderStats* stats = nullptr,
    const RenderProgress* progress = nullptr);

// Supplies frames [begin, begin + count) of every input track, planar:
// tracks[t] is resized to `count` floats of track t (0-based). The reader
// pads a track that ends before begin + count with silence; the render fails
// when any track of a chunk holds fewer than `count` frames.
//
// RenderChannelBedStreamed calls it on a helper thread, a different one for
// each chunk, while the render works on the previous chunk. Calls never
// overlap, each starts after the previous one has returned, and the render
// returns only after the last call has finished. A reader that shares state
// with other threads must synchronize it.
using ReadTracksFn = std::function<absl::Status(
    uint64_t begin, uint64_t count, std::vector<std::vector<float>>& tracks)>;

// RenderChannelBed over `frames` frames of `num_tracks` tracks that
// `read_tracks` supplies a chunk at a time, in ascending order, so the whole
// input never has to be in memory. Progress counts frames rendered, one
// report per chunk of 65536 frames. The OLR passes run on up to `threads`
// threads and at most one per pass, the calling thread included, plus the
// reader's helper thread; `threads` 0 uses min(hardware_concurrency() - 1, 8).
// The output is the same for any thread count. `progress` is called on the
// calling thread only.
absl::StatusOr<std::vector<std::vector<float>>> RenderChannelBedStreamed(
    const Scene& scene, const Layout& layout, size_t num_tracks,
    uint64_t frames, const ReadTracksFn& read_tracks, uint32_t sample_rate,
    int importance_threshold = 0, RenderStats* stats = nullptr,
    const RenderProgress* progress = nullptr, unsigned threads = 0);

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
