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
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <exception>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
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

// Each OLR pass drives one object and writes
// object_positions.polar_positions[0] (see OlrPass::Render). Assert OAR's
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

// One OLR pass: a persistent oar_t rendering one mono source with a
// per-block (position, gain). The instance lives for the whole render, so
// rendering it chunk by chunk carries OLR's gain-interpolation state across
// chunk boundaries exactly as one uninterrupted pass would.
class OlrPass {
 public:
  OlrPass(int track, PosGainFn pos_gain)
      : track_(track), pos_gain_(std::move(pos_gain)) {}
  OlrPass(const OlrPass&) = delete;
  OlrPass& operator=(const OlrPass&) = delete;
  ~OlrPass() {
    if (oar_ != nullptr) oar_destroy(oar_);
  }

  int track() const { return track_; }

  absl::Status Init(const Layout& layout, uint32_t sample_rate) {
    num_out_ = layout.num_channels();
    oar_config_t cfg = {};
    cfg.target_layout = layout.oar_layout;
    cfg.samples_per_channel = kBlock;
    cfg.sampling_rate = sample_rate;
    oar_ = oar_create(&cfg);
    if (oar_ == nullptr) return absl::InternalError("oar_create failed.");
    const int gid = oar_add_audio_group(oar_);
    if (gid < 0) return absl::InternalError("oar_add_audio_group failed.");
    oar_audio_element_config_t ecfg;
    std::memset(&ecfg, 0, sizeof(ecfg));
    ecfg.type = ck_object_based;
    ecfg.obc.num_objects = 1;
    if (oar_add_audio_element(oar_, static_cast<uint32_t>(gid), kElemId,
                              &ecfg) != 0) {
      return absl::InternalError("oar_add_audio_element failed.");
    }
    if (oar_get_number_of_audio_element_channels(oar_, kElemId) != 1 ||
        static_cast<int>(oar_get_number_of_output_channels(oar_)) != num_out_) {
      return absl::InternalError("unexpected OAR channel counts.");
    }
    in_.assign(kBlock, 0.0f);
    return absl::OkStatus();
  }

  // Renders frames [begin, end) (begin a multiple of kBlock). `signal` holds
  // those frames of this pass's track. The output is block-major: block b's
  // planar output (num_out x kBlock) starts at out + b * num_out * kBlock,
  // and oar_render writes it in place.
  absl::Status Render(const oar_position_anchors_t* anchors, uint64_t begin,
                      uint64_t end, const float* signal, float* out) {
    for (uint64_t pos = begin; pos < end; pos += kBlock) {
      const uint32_t valid =
          static_cast<uint32_t>(std::min<uint64_t>(kBlock, end - pos));
      const std::pair<ObjectPosition, float> pg = pos_gain_(pos);
      const Polar p = ConvertObjectPosition(pg.first, anchors);
      const float gain = pg.second;
      const float* x = signal + (pos - begin);
      for (uint32_t n = 0; n < kBlock; ++n) {
        in_[n] = (n < valid) ? x[n] * gain : 0.0f;
      }
      oar_audio_block_t ib = {in_.data(), 1, kBlock};
      if (oar_update_audio_element_data(oar_, kElemId, &ib) != 0) {
        return absl::InternalError("oar_update_audio_element_data failed.");
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
      if (oar_update_audio_element_metadata(oar_, kElemId, &md) != 0) {
        return absl::InternalError("oar_update_audio_element_metadata failed.");
      }
      float* dst = out + (pos - begin) * static_cast<size_t>(num_out_);
      oar_audio_block_t ob = {dst, static_cast<uint32_t>(num_out_), kBlock};
      if (oar_render(oar_, &ob) != 0) {
        return absl::InternalError("oar_render failed.");
      }
    }
    return absl::OkStatus();
  }

 private:
  static constexpr uint32_t kElemId = 1;
  int track_;
  PosGainFn pos_gain_;
  oar_t* oar_ = nullptr;
  int num_out_ = 0;
  std::vector<float> in_;
};

// Runs fn(0) .. fn(count - 1) on up to `threads` threads, the caller's
// included, and returns once every call has finished. When a thread cannot
// be started, the threads that did start and the caller share the work. The
// first exception thrown by `fn` stops further calls and is rethrown here
// once all threads have joined.
template <typename Fn>
void RunParallel(unsigned threads, size_t count, const Fn& fn) {
  std::atomic<size_t> next{0};
  std::mutex error_mu;
  std::exception_ptr error;
  const auto worker = [&] {
    try {
      for (size_t i = next.fetch_add(1); i < count; i = next.fetch_add(1)) {
        fn(i);
      }
    } catch (...) {
      next.store(count);
      const std::lock_guard<std::mutex> lock(error_mu);
      if (error == nullptr) error = std::current_exception();
    }
  };
  const size_t n = std::min<size_t>(threads, count);
  std::vector<std::thread> pool;
  pool.reserve(n);
  for (size_t t = 1; t < n; ++t) {
    try {
      pool.emplace_back(worker);
    } catch (...) {  // std::system_error, or std::bad_alloc from libc++.
      break;
    }
  }
  worker();
  for (std::thread& t : pool) t.join();
  if (error != nullptr) std::rethrow_exception(error);
}

// Threads for the OLR passes: the hardware thread count minus one, at most
// 8. The chunk reader runs on one more thread beside them. On a 54-track,
// 337 s master (44 objects) on an 18-core Apple M5 Pro, 8 threads render in
// 5.2 s and 17 in 4.5 s, while the system time grows from 4.2 s to 20.3 s.
unsigned RenderThreads() {
  constexpr unsigned kMaxThreads = 8;
  const unsigned hw = std::thread::hardware_concurrency();
  return std::clamp(hw > 1 ? hw - 1 : 1, 1u, kMaxThreads);
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

absl::StatusOr<std::vector<std::vector<float>>> RenderChannelBedStreamed(
    const Scene& scene, const Layout& layout, size_t num_tracks,
    uint64_t frames, const ReadTracksFn& read_tracks, uint32_t sample_rate,
    int importance_threshold, RenderStats* stats,
    const RenderProgress* progress, unsigned threads) {
  const int num_out = layout.num_channels();

  const auto check_track = [&](int track_index,
                               const std::string& label) -> absl::Status {
    if (track_index < 1 || static_cast<size_t>(track_index) > num_tracks) {
      return absl::InvalidArgumentError(
          absl::StrCat("'", label, "' has out-of-range track index ",
                       track_index, " (", num_tracks, " tracks)."));
    }
    return absl::OkStatus();
  };
  for (const Source& s : scene.sources) {
    if (absl::Status st = check_track(s.track_index, s.label); !st.ok()) {
      return st;
    }
  }
  for (const ObjectSource& o : scene.objects) {
    if (absl::Status st = check_track(o.track_index, o.label); !st.ok()) {
      return st;
    }
  }

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

  // Every source's contribution, in scene order (bed sources, then kept
  // objects). The output is summed in this order, so the result does not
  // depend on how the passes are spread across threads.
  struct Contribution {
    int track = 0;     // 0-based input track.
    int channel = -1;  // >= 0: direct copy into this channel with `gain`.
    float gain = 1.0f;
    int pass = -1;  // >= 0: index into `passes`.
  };
  RenderStats local;
  std::vector<Contribution> contributions;
  std::vector<std::unique_ptr<OlrPass>> passes;

  for (const Source& src : scene.sources) {
    const int track = src.track_index - 1;
    if (src.is_lfe) {
      contributions.push_back({track, layout.lfe_index(), src.gain, -1});
      ++local.lfe;
      continue;
    }
    const int coincident = CoincidentSpeaker(layout, src.position);
    if (coincident >= 0) {
      contributions.push_back({track, coincident, src.gain, -1});
      ++local.passthrough;
      continue;
    }
    ObjectPosition pos;
    pos.polar = src.position;
    const float gain = src.gain;
    passes.push_back(std::make_unique<OlrPass>(track, [pos, gain](uint64_t) {
      return std::pair<ObjectPosition, float>{pos, gain};
    }));
    contributions.push_back(
        {track, -1, 1.0f, static_cast<int>(passes.size()) - 1});
    ++local.olr;
  }
  for (const ObjectSource& obj : scene.objects) {
    if (obj.importance < importance_threshold) {
      ++local.objects_dropped;
      continue;
    }
    const int track = obj.track_index - 1;
    // `scene` outlives the render, so the pass may point into it.
    passes.push_back(std::make_unique<OlrPass>(
        track,
        [o = &obj, start = KeyframeStartFrames(obj.timeline, sample_rate),
         sample_rate](
            uint64_t block_start) -> std::pair<ObjectPosition, float> {
          const size_t cur = ActiveKeyframe(start, block_start);
          const PosGain pg = EvalObjectTimeline(o->timeline, start, cur,
                                                block_start, sample_rate);
          return {pg.position, pg.gain};
        }));
    contributions.push_back(
        {track, -1, 1.0f, static_cast<int>(passes.size()) - 1});
    ++local.objects;
  }
  for (auto& pass : passes) {
    if (absl::Status s = pass->Init(layout, sample_rate); !s.ok()) return s;
  }

  std::vector<std::vector<float>> out(
      num_out, std::vector<float>(static_cast<size_t>(frames), 0.0f));

  // Render in chunks of kChunkBlocks blocks. The next chunk's PCM is read on
  // its own thread while the current one renders. Within a chunk the passes
  // run in parallel, each into its own buffer; the summation then runs in
  // parallel across output channels, each adding contributions in scene
  // order.
  constexpr uint64_t kChunkBlocks = 64;
  constexpr uint64_t kChunk = kChunkBlocks * kBlock;
  const unsigned render_threads = threads > 0 ? threads : RenderThreads();
  std::vector<std::vector<float>> pass_buf(
      passes.size(), std::vector<float>(static_cast<size_t>(num_out) * kChunk));
  std::vector<absl::Status> pass_status(passes.size());
  std::vector<std::vector<float>> tracks[2];
  const auto read_chunk = [&](int slot, uint64_t begin) -> absl::Status {
    const uint64_t count = std::min<uint64_t>(kChunk, frames - begin);
    std::vector<std::vector<float>>& chunk = tracks[slot];
    if (absl::Status s = read_tracks(begin, count, chunk); !s.ok()) return s;
    if (chunk.size() < num_tracks) {
      return absl::InternalError("track reader returned too few tracks.");
    }
    for (size_t t = 0; t < num_tracks; ++t) {
      if (chunk[t].size() < count) {
        return absl::InternalError("track reader returned a short chunk.");
      }
    }
    return absl::OkStatus();
  };
  // A future from std::async waits for its task in its destructor, so every
  // exit below, by return or by exception, waits for an in-flight read
  // before `tracks` is destroyed. `pending` must stay declared after
  // `tracks` and `read_chunk`.
  std::future<absl::Status> pending;
  if (frames > 0) pending = std::async(std::launch::async, read_chunk, 0, 0);

  int slot = 0;
  for (uint64_t begin = 0; begin < frames; begin += kChunk, slot ^= 1) {
    const uint64_t end = std::min<uint64_t>(frames, begin + kChunk);
    if (absl::Status s = pending.get(); !s.ok()) return s;
    if (end < frames) {
      pending = std::async(std::launch::async, read_chunk, slot ^ 1, end);
    }
    const std::vector<std::vector<float>>& chunk = tracks[slot];
    RunParallel(render_threads, passes.size(), [&](size_t p) {
      pass_status[p] = passes[p]->Render(anchors.get(), begin, end,
                                         chunk[passes[p]->track()].data(),
                                         pass_buf[p].data());
    });
    // Returning destroys `pending`, which waits for the next chunk's read and
    // drops its status; the first error is the one reported.
    for (const absl::Status& s : pass_status) {
      if (!s.ok()) return s;
    }
    RunParallel(render_threads, static_cast<size_t>(num_out), [&](size_t ch) {
      float* dst = out[ch].data();
      for (const Contribution& c : contributions) {
        if (c.pass < 0) {
          if (static_cast<int>(ch) != c.channel) continue;
          const float* src = chunk[c.track].data();
          for (uint64_t n = begin; n < end; ++n) {
            dst[n] += src[n - begin] * c.gain;
          }
          continue;
        }
        const float* buf = pass_buf[c.pass].data();
        for (uint64_t b = begin; b < end; b += kBlock) {
          const float* src = buf + (b - begin) * static_cast<size_t>(num_out) +
                             static_cast<size_t>(ch) * kBlock;
          const uint64_t n_end = std::min<uint64_t>(end, b + kBlock);
          for (uint64_t n = b; n < n_end; ++n) dst[n] += src[n - b];
        }
      }
    });
    if (progress != nullptr) {
      progress->Report(end, frames);
      if (progress->ShouldCancel()) {
        return absl::CancelledError("render cancelled");
      }
    }
  }

  if (stats != nullptr) *stats = local;
  return out;
}

absl::StatusOr<std::vector<std::vector<float>>> RenderChannelBed(
    const Scene& scene, const Layout& layout,
    const std::vector<std::vector<float>>& input_tracks, uint32_t sample_rate,
    int importance_threshold, RenderStats* stats,
    const RenderProgress* progress) {
  // The output spans the longest track a source uses; shorter tracks read
  // as silence past their end.
  uint64_t frames = 0;
  const auto extend = [&](int track_index) {
    const int idx = track_index - 1;
    if (idx >= 0 && idx < static_cast<int>(input_tracks.size())) {
      frames = std::max<uint64_t>(frames, input_tracks[idx].size());
    }
  };
  for (const Source& s : scene.sources) extend(s.track_index);
  for (const ObjectSource& o : scene.objects) extend(o.track_index);
  const ReadTracksFn read = [&](uint64_t begin, uint64_t count,
                                std::vector<std::vector<float>>& tracks) {
    tracks.resize(input_tracks.size());
    for (size_t t = 0; t < input_tracks.size(); ++t) {
      const std::vector<float>& src = input_tracks[t];
      tracks[t].assign(static_cast<size_t>(count), 0.0f);
      if (begin < src.size()) {
        const uint64_t n = std::min<uint64_t>(count, src.size() - begin);
        std::copy_n(src.data() + begin, n, tracks[t].data());
      }
    }
    return absl::OkStatus();
  };
  return RenderChannelBedStreamed(scene, layout, input_tracks.size(), frames,
                                  read, sample_rate, importance_threshold,
                                  stats, progress);
}

}  // namespace adm2iamf
