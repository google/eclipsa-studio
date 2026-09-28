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

#include "adm_import/render/channel_renderer.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
extern "C" {
#include "oar.h"
}
#include "adm_import/render/object_motion.h"
#include "adm_import/render/render_progress.h"
#include "adm_import/scene/layouts.h"
#include "adm_import/scene/scene.h"

namespace adm2iamf {
namespace {

constexpr uint32_t kBlock = 1024;     // OLR samples per render call.
constexpr float kAngleTolDeg = 1.0f;  // "Coincident" threshold.

// We drive OLR one object at a time and write
// object_positions.polar_positions[0] (see RenderViaOlr). Assert OAR's
// fixed-size array can hold it, so a change to def_max_number_of_objects fails
// the build rather than silently writing out of bounds.
static_assert(def_max_number_of_objects >= 1,
              "OAR object_positions array must hold at least one object.");

// Per-render-block position + linear gain for a source.
using PosGainFn =
    std::function<std::pair<ObjectPosition, float>(uint64_t block_start)>;

float AngleDiff(float a, float b) {
  float d = std::fmod(a - b + 540.0f, 360.0f) - 180.0f;
  return std::fabs(d);
}

int CoincidentSpeaker(const Layout& layout, const Polar& p) {
  for (int i = 0; i < layout.num_channels(); ++i) {
    const Speaker& s = layout.speakers[i];
    if (s.is_lfe) continue;
    if (AngleDiff(s.azimuth, p.azimuth) <= kAngleTolDeg &&
        AngleDiff(s.elevation, p.elevation) <= kAngleTolDeg) {
      return i;
    }
  }
  return -1;
}

// Drives one OLR pass over `signal`, pulling the (position, gain) for each
// render block from `pos_gain`, and sums the result into `out` (planar).
// `work_done`/`work_total` track cumulative render frames across all of this
// renderer's OLR passes so `progress` reports one smooth 0..1 ratio; the pass
// aborts with `absl::CancelledError` if `progress` reports cancellation.
absl::Status RenderViaOlr(const Layout& layout,
                          const oar_position_anchors_t* anchors,
                          const std::vector<float>& signal,
                          uint32_t sample_rate, const PosGainFn& pos_gain,
                          std::vector<std::vector<float>>& out,
                          const RenderProgress* progress, uint64_t work_total,
                          uint64_t& work_done) {
  const int num_out = layout.num_channels();
  const uint64_t frames = signal.size();

  oar_config_t cfg = {};
  cfg.target_layout = layout.oar_layout;
  cfg.samples_per_channel = kBlock;
  cfg.sampling_rate = sample_rate;
  oar_t* oar = oar_create(&cfg);
  if (oar == nullptr) return absl::InternalError("oar_create failed.");
  auto cleanup = [&](absl::Status s) {
    oar_destroy(oar);
    return s;
  };

  int gid = oar_add_audio_group(oar);
  if (gid < 0)
    return cleanup(absl::InternalError("oar_add_audio_group failed."));

  oar_audio_element_config_t ecfg;
  std::memset(&ecfg, 0, sizeof(ecfg));
  ecfg.type = ck_object_based;
  ecfg.obc.num_objects = 1;
  constexpr uint32_t kElemId = 1;
  if (oar_add_audio_element(oar, static_cast<uint32_t>(gid), kElemId, &ecfg) !=
      0) {
    return cleanup(absl::InternalError("oar_add_audio_element failed."));
  }
  if (oar_get_number_of_audio_element_channels(oar, kElemId) != 1 ||
      static_cast<int>(oar_get_number_of_output_channels(oar)) != num_out) {
    return cleanup(absl::InternalError("unexpected OAR channel counts."));
  }

  std::vector<float> in(kBlock);
  std::vector<float> rendered(static_cast<size_t>(num_out) * kBlock);

  for (uint64_t pos = 0; pos < frames; pos += kBlock) {
    const uint32_t valid =
        static_cast<uint32_t>(std::min<uint64_t>(kBlock, frames - pos));
    const std::pair<ObjectPosition, float> pg = pos_gain(pos);
    const Polar p = ConvertObjectPosition(pg.first, anchors);
    const float gain = pg.second;

    for (uint32_t n = 0; n < kBlock; ++n) {
      in[n] = (n < valid) ? signal[pos + n] * gain : 0.0f;
    }
    oar_audio_block_t ib = {in.data(), 1, kBlock};
    if (oar_update_audio_element_data(oar, kElemId, &ib) != 0) {
      return cleanup(
          absl::InternalError("oar_update_audio_element_data failed."));
    }

    oar_metadata_t md;
    std::memset(&md, 0, sizeof(md));
    md.type = ck_metadata_object_positions;
    md.duration = static_cast<int>(kBlock);
    md.object_positions.param_type = ck_param_constant;
    md.object_positions.position_type = ck_polar;
    md.object_positions.num_objects = 1;
    md.object_positions.polar_positions[0].azimuth = p.azimuth;
    md.object_positions.polar_positions[0].elevation = p.elevation;
    md.object_positions.polar_positions[0].distance = p.distance;
    if (oar_update_audio_element_metadata(oar, kElemId, &md) != 0) {
      return cleanup(
          absl::InternalError("oar_update_audio_element_metadata failed."));
    }

    std::fill(rendered.begin(), rendered.end(), 0.0f);
    oar_audio_block_t ob = {rendered.data(), static_cast<uint32_t>(num_out),
                            kBlock};
    if (oar_render(oar, &ob) != 0) {
      return cleanup(absl::InternalError("oar_render failed."));
    }
    for (int ch = 0; ch < num_out; ++ch) {
      const float* col = rendered.data() + static_cast<size_t>(ch) * kBlock;
      for (uint32_t n = 0; n < valid; ++n) out[ch][pos + n] += col[n];
    }

    work_done += valid;
    if (progress != nullptr) {
      progress->Report(work_done, work_total);
      if (progress->ShouldCancel()) {
        return cleanup(absl::CancelledError("render cancelled"));
      }
    }
  }
  return cleanup(absl::OkStatus());
}

}  // namespace

AnchorsHandle MakeAnchors(const Layout& layout) {
  return AnchorsHandle(oar_position_anchors_create(layout.oar_layout),
                       &oar_position_anchors_destroy);
}

Polar ConvertObjectPosition(const ObjectPosition& p,
                            const oar_position_anchors_t* anchors) {
  if (!p.cartesian) return p.polar;
  // A NULL handle deliberately selects the sector map, NOT layout mode with
  // NULL anchors — oar.h warns that the latter silently becomes the balloon
  // conversion, while the sector map is the fallback an oar_t itself applies
  // when its own anchor derivation fails.
  const oar_position_conversion_t mode =
      anchors != nullptr ? ck_oar_pos_conv_layout : ck_oar_pos_conv_sector;
  const polar_t s =
      oar_cartesian_to_polar(anchors, mode, {p.cube.x, p.cube.y, p.cube.z});
  return {s.azimuth, s.elevation, s.distance};
}

absl::StatusOr<std::vector<std::vector<float>>> RenderChannelBed(
    const Scene& scene, const Layout& layout,
    const std::vector<std::vector<float>>& input_tracks, uint32_t sample_rate,
    int importance_threshold, RenderStats* stats,
    const RenderProgress* progress) {
  const int num_out = layout.num_channels();

  auto signal_for =
      [&](int track_index,
          const char* label) -> absl::StatusOr<const std::vector<float>*> {
    const int idx = track_index - 1;
    if (idx < 0 || idx >= static_cast<int>(input_tracks.size())) {
      return absl::InvalidArgumentError(
          absl::StrCat("'", label, "' has out-of-range track index ",
                       track_index, " (", input_tracks.size(), " tracks)."));
    }
    return &input_tracks[idx];
  };

  uint64_t frames = 0;
  for (const Source& s : scene.sources) {
    auto sig = signal_for(s.track_index, s.label.c_str());
    if (!sig.ok()) return sig.status();
    frames = std::max<uint64_t>(frames, (*sig)->size());
  }
  for (const ObjectSource& o : scene.objects) {
    auto sig = signal_for(o.track_index, o.label.c_str());
    if (!sig.ok()) return sig.status();
    frames = std::max<uint64_t>(frames, (*sig)->size());
  }

  std::vector<std::vector<float>> out(
      num_out, std::vector<float>(static_cast<size_t>(frames), 0.0f));
  RenderStats local;

  // One anchor set per target layout, shared by every OLR pass below: the
  // layout-anchored cartesian->polar conversion pins room-cube walls and
  // corners to this layout's real speakers. The probe derives the same
  // handle, so preview and bake agree; without one the render would fall
  // back to the sector map and diverge from the preview, so fail instead.
  const AnchorsHandle anchors = MakeAnchors(layout);
  if (anchors == nullptr) {
    return absl::InternalError(absl::StrCat(
        "position conversion anchors unavailable for ", layout.name, "."));
  }

  // Total render work = one pass over `frames` per OLR pass we are about to run
  // (one per non-coincident bed source, one per kept object). Passthrough/LFE
  // copies are cheap and not counted; `work_done` accumulates as passes run.
  uint64_t olr_passes = 0;
  for (const Source& src : scene.sources) {
    if (!src.is_lfe && CoincidentSpeaker(layout, src.position) < 0)
      ++olr_passes;
  }
  for (const ObjectSource& obj : scene.objects) {
    if (obj.importance >= importance_threshold) ++olr_passes;
  }
  const uint64_t work_total = olr_passes * frames;
  uint64_t work_done = 0;

  // Bed channels: passthrough / LFE / OLR phantom.
  for (const Source& src : scene.sources) {
    const std::vector<float>& signal = input_tracks[src.track_index - 1];
    if (src.is_lfe) {
      const int lfe = layout.lfe_index();
      for (size_t n = 0; n < signal.size(); ++n)
        out[lfe][n] += signal[n] * src.gain;
      ++local.lfe;
      continue;
    }
    const int coincident = CoincidentSpeaker(layout, src.position);
    if (coincident >= 0) {
      for (size_t n = 0; n < signal.size(); ++n) {
        out[coincident][n] += signal[n] * src.gain;
      }
      ++local.passthrough;
      continue;
    }
    ObjectPosition pos;
    pos.polar = src.position;
    const float gain = src.gain;
    absl::Status s = RenderViaOlr(
        layout, anchors.get(), signal, sample_rate,
        [&](uint64_t) { return std::pair<ObjectPosition, float>{pos, gain}; },
        out, progress, work_total, work_done);
    if (!s.ok()) return s;
    ++local.olr;
  }

  // Dynamic objects: always OLR, with time-varying position/gain.
  for (const ObjectSource& obj : scene.objects) {
    if (obj.importance < importance_threshold) {
      ++local.objects_dropped;
      continue;
    }
    const std::vector<float>& signal = input_tracks[obj.track_index - 1];
    const std::vector<uint64_t> start_frame =
        KeyframeStartFrames(obj.timeline, sample_rate);
    absl::Status s = RenderViaOlr(
        layout, anchors.get(), signal, sample_rate,
        [&](uint64_t block_start) -> std::pair<ObjectPosition, float> {
          const size_t cur = ActiveKeyframe(start_frame, block_start);
          const PosGain pg = EvalObjectTimeline(obj.timeline, start_frame, cur,
                                                block_start, sample_rate);
          return {pg.position, pg.gain};
        },
        out, progress, work_total, work_done);
    if (!s.ok()) return s;
    ++local.objects;
  }

  if (stats != nullptr) *stats = local;
  return out;
}

}  // namespace adm2iamf
