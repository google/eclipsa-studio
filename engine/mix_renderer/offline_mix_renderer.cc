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

#include "mix_renderer/offline_mix_renderer.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <map>
#include <memory>
#include <vector>

#include "bounce/element_stream.h"
#include "engine_log.h"
#include "graph/audio_buffer.h"
#include "mix_renderer/loudness_analysis_sink.h"
#include "renderer/channel_order.h"
#include "renderer/oar_renderer.h"

namespace eclipsa_studio {

// ── Impl ────────────────────────────────────────────────────────────────

struct OfflineMixRenderer::Impl {
  uint32_t sample_rate = 48000;
  uint32_t buffer_size = 1024;
  uint32_t layout = 2;  // stereo
  float output_mix_gain_db = 0.0f;
  std::vector<MixElementConfig> elements;
  OarRenderer oar;
  // Measurement side of the render: analyzer, digital peak, traces
  // and LRA. Stays queryable after RenderAndMeasure() until the next
  // run resets it.
  LoudnessAnalysisSink sink;
  // Per-element signal-overload stats from the last successful run,
  // keyed by element_id. Same keep-alive/reset lifecycle as the sink's
  // traces above.
  struct ElementClipStats {
    uint64_t clipped_samples = 0;
    float peak_linear = 0.0f;
  };
  std::map<uint32_t, ElementClipStats> element_clip_stats;
  bool measured = false;
};

// ── Lifecycle ───────────────────────────────────────────────────────────

OfflineMixRenderer::OfflineMixRenderer() : impl_(std::make_unique<Impl>()) {
  // Offline instance: no audio thread will ever drive it, so OAR's
  // fade/ack waits must short-circuit — otherwise every AddElement
  // rebuild spins ~0.55 s to their timeouts (ES-515). Marked here rather
  // than in Init(): SetLimiterEnabled() may come first, and the renderer
  // accepts the switch only on an instance marked so.
  impl_->oar.set_no_audio_thread();
}

OfflineMixRenderer::~OfflineMixRenderer() = default;

bool OfflineMixRenderer::Init(uint32_t sample_rate, uint32_t buffer_size,
                              uint32_t layout) {
  // Reject absurd sample rates up front — reachable from the C ABI.
  // Below 10 Hz the sink's GR-trace step (sr * kTraceStepMs / 1000)
  // truncates to zero frames and its bucket-advance loop never
  // terminates; no real program sits below phone-band rates anyway.
  if (sample_rate < 8000) {
    char buf[96];
    snprintf(buf, sizeof(buf),
             "Rejecting offline render sample rate %u (< 8000 Hz)",
             sample_rate);
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer", buf);
    return false;
  }

  impl_->sample_rate = sample_rate;
  impl_->buffer_size = buffer_size;
  impl_->layout = layout;

  if (!impl_->oar.init(sample_rate, buffer_size, layout)) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "Failed to initialize OAR for offline render");
    return false;
  }

  // The -1 dBFS peak limiter is on unless SetLimiterEnabled(false) turned
  // it off (create_renderer() in renderer/oar_renderer.cc), so by default
  // this measurement is post-limiter while the encoded file ships
  // unlimited.
  return true;
}

bool OfflineMixRenderer::AddElement(const MixElementConfig& config) {
  if (!impl_->oar.add_element(config.element_id, config.element_type,
                              config.element_sub_type, config.channels)) {
    char buf[128];
    snprintf(buf, sizeof(buf), "Failed to add element %u to offline renderer",
             config.element_id);
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer", buf);
    return false;
  }

  // Set rendering config (headphones mode + binaural profile).
  impl_->oar.set_element_rendering_config(
      config.element_id, config.headphones_mode, config.binaural_profile);
  impl_->oar.commit_rendering_config();

  // Replace on duplicate id, mirroring OarRenderer::add_element's own
  // de-dupe. Two entries with one id would double every per-block
  // metadata push against a single OAR element — the gain queue then
  // grows by one stale entry per block for the whole render.
  const auto dup = std::find_if(impl_->elements.begin(), impl_->elements.end(),
                                [&](const MixElementConfig& e) {
                                  return e.element_id == config.element_id;
                                });
  if (dup != impl_->elements.end()) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "Duplicate element id %u in offline renderer; replacing",
             config.element_id);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "mix_renderer", buf);
    *dup = config;
  } else {
    impl_->elements.push_back(config);
  }
  return true;
}

bool OfflineMixRenderer::SetObjectPosition(uint32_t element_id, uint32_t count,
                                           const float* az_deg,
                                           const float* el_deg,
                                           const float* dist) {
  for (auto& elem : impl_->elements) {
    if (elem.element_id != element_id) continue;
    const uint32_t n = count < 1 ? 1 : (count > 2 ? 2 : count);
    elem.num_objects = n;
    for (uint32_t i = 0; i < n; ++i) {
      elem.azimuth_deg[i] = az_deg[i];
      elem.elevation_deg[i] = el_deg[i];
      elem.distance[i] = dist[i];
    }
    return true;
  }
  return false;
}

bool OfflineMixRenderer::SetElementChannelOrder(uint32_t element_id,
                                                uint32_t order) {
  for (auto& elem : impl_->elements) {
    if (elem.element_id != element_id) continue;
    elem.channel_order = order;
    return true;
  }
  return false;
}

void OfflineMixRenderer::SetOutputMixGain(float gain_db) {
  impl_->output_mix_gain_db = gain_db;
}

bool OfflineMixRenderer::SetLimiterEnabled(bool enabled) {
  // The renderer keeps the setting across init() and rebuilds, and the
  // constructor marked it set_no_audio_thread(), so it accepts the
  // change before or after Init().
  return impl_->oar.set_limiter_enabled(enabled);
}

// ── Render + measure ────────────────────────────────────────────────────

std::optional<LoudnessResult> OfflineMixRenderer::RenderAndMeasure() {
  // Drop any previous run's series and stats before re-measuring, so a
  // run that fails below leaves nothing of the previous one readable.
  impl_->sink.Reset();
  impl_->element_clip_stats.clear();
  impl_->measured = false;

  if (impl_->elements.empty()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "No elements to render");
    return std::nullopt;
  }

  const uint32_t bs = impl_->buffer_size;

  // ── Open all element streams ──────────────────────────────────────
  // One single-use ElementStream per element per call: the same
  // gain → routing → resample → pad pipeline that feeds the IAMF push
  // encoder, pulled straight from the source WAV.
  struct ElementReader {
    ElementStream stream;
    MixElementConfig config;
  };
  std::vector<std::unique_ptr<ElementReader>> readers;
  readers.reserve(impl_->elements.size());

  // Longest stream drives the loop; shorter streams end early and their
  // blocks stay zeroed. Callers that want a common length pass a shared
  // stream.pad_to_frames (the CLI passes 0 and measures ragged sources).
  uint64_t max_frames = 0;
  for (const auto& elem : impl_->elements) {
    auto er = std::make_unique<ElementReader>();
    er->config = elem;
    if (!er->stream.Open(elem.stream)) {
      char buf[256];
      snprintf(buf, sizeof(buf), "Cannot open stream for element %u: %s",
               elem.element_id, elem.stream.input_wav_path.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer", buf);
      return std::nullopt;
    }
    if (er->stream.channels() != elem.channels) {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "Element %u stream delivers %u channels, declared %u: %s",
               elem.element_id, er->stream.channels(), elem.channels,
               elem.stream.input_wav_path.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer", buf);
      return std::nullopt;
    }
    max_frames = std::max(max_frames, er->stream.total_frames());
    readers.push_back(std::move(er));
  }

  // ── Start the measurement sink ────────────────────────────────────
  // The sink owns the analyzer, the digital peak and the trace series,
  // and extends the pass by the limiter delay so every result lands on
  // the program timeline (see LoudnessAnalysisSink).
  if (!impl_->sink.Begin(&impl_->oar, impl_->sample_rate, bs, impl_->layout,
                         max_frames)) {
    return std::nullopt;
  }

  // ── Allocate per-element read buffers ─────────────────────────────
  // Size each buffer to the element's own channel count — OAR ignores
  // anything beyond `channels`, so there's no reason to reserve the
  // kMaxCh worst case per element.
  std::vector<std::vector<float>> elem_storage(readers.size());
  for (size_t i = 0; i < readers.size(); ++i) {
    const uint32_t ch = readers[i]->config.channels;
    elem_storage[i].assign(static_cast<size_t>(ch) * bs, 0.0f);
  }

  // ── Process loop ──────────────────────────────────────────────────
  const auto render_start = std::chrono::steady_clock::now();
  // Program frames still to feed; once the sources are consumed the loop
  // keeps rendering zero-fed blocks until the sink has drained the
  // limiter delay.
  uint64_t in_left = max_frames;

  while (impl_->sink.has_more()) {
    // Program frames fed this block; 0 once the sources are consumed
    // and the loop is only draining the limiter delay.
    const uint32_t block =
        static_cast<uint32_t>(std::min<uint64_t>(in_left, bs));

    // Feed each element's PCM to OAR. `buf.zero()` pre-silences the
    // full block, so elements whose source is shorter than the longest
    // element continue to play silence through to the end. OAR only
    // accepts blocks of its configured samples_per_channel, so we always
    // hand it the full `bs` frames — on the final partial block the tail
    // past `block` is the zeroed padding — and consume only the first
    // `block` frames of the rendered output below.
    for (size_t i = 0; i < readers.size(); ++i) {
      auto& er = *readers[i];
      const uint32_t ch = er.config.channels;

      AudioBuffer buf;
      buf.data = elem_storage[i].data();
      buf.channels = ch;
      buf.frames = block;
      buf.capacity_frames = bs;
      buf.zero();

      // Pull() caps a single request at kMaxPullFrames, so blocks larger
      // than that fill through an offset view into the same planar
      // storage (stride stays bs). Relies on Pull() writing only the
      // delivered span via out.channel() and never zeroing the view —
      // the full-block zero above is the only clear.
      uint32_t filled = 0;
      while (filled < block) {
        AudioBuffer view;
        view.data = elem_storage[i].data() + filled;
        view.channels = ch;
        view.frames = block - filled;
        view.capacity_frames = bs;
        const uint32_t want =
            std::min(block - filled, ElementStream::kMaxPullFrames);
        const uint32_t got = er.stream.Pull(view, want);
        if (got == 0) break;  // stream exhausted; remainder stays zeroed
        filled += got;
      }

      // Push the IAMF element mix gain before every block, exactly as
      // the live audio thread does: OAR's gain metadata is an animated
      // segment covering `frames`, after which the element reverts to
      // its default (0 dB) — a one-shot push before the loop applies
      // to the first block only, silently dropping the mix fader from
      // the remaining ~99% of the measurement (found by
      // iamf_loudness_agreement_test, ES-492).
      impl_->oar.set_element_mix_gain(er.config.element_id,
                                      er.config.mix_gain_db,
                                      er.config.mix_gain_db, bs);

      // Object elements: push positions before every block, exactly as
      // the live audio thread does — OLR's position timeline must stay
      // in lockstep with its render offset from the first block, and a
      // late or one-shot push does not recover (see
      // oar_object_position_test.cc).
      if (er.config.element_type == 2) {
        impl_->oar.set_element_object_positions(
            er.config.element_id, er.config.num_objects, er.config.azimuth_deg,
            er.config.elevation_deg, er.config.distance, bs);
      }

      // A 9.1.6 element in OBR's alt order is permuted into OAR's order
      // here, as on the live audio thread (renderer/channel_order.h).
      impl_->oar.update_element_data(
          er.config.element_id, buf.data, ch, bs, bs,
          ElementInputOrder(er.config.channel_order, ch));
    }

    // Group-level output mix gain: same per-block push semantics as the
    // element gains above.
    impl_->oar.set_output_mix_gain(impl_->output_mix_gain_db,
                                   impl_->output_mix_gain_db, bs);

    // Render the full block and hand it to the sink, which measures only
    // its program-aligned frames.
    const float* rendered = impl_->oar.render(bs);
    if (rendered == nullptr) {
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
                 "OAR render returned null");
      return std::nullopt;
    }
    impl_->sink.Consume(rendered);

    in_left -= block;
  }

  // ── Read results ──────────────────────────────────────────────────
  const LoudnessResult result = impl_->sink.Finish();

  // Snapshot per-element overload stats from the streams. These are
  // pre-mix, pre-limiter numbers — the element PCM as the IAMF export
  // would encode it — so they survive even though the rendered mix
  // above is limited.
  for (const auto& er : readers) {
    impl_->element_clip_stats[er->config.element_id] = {
        er->stream.clipped_samples(), er->stream.peak_linear()};
  }

  impl_->measured = true;

  const auto render_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - render_start)
                             .count();
  char buf[320];
  snprintf(buf, sizeof(buf),
           "Loudness measured: integrated=%.1f LUFS, "
           "true_peak=%.1f dBTP, digital_peak=%.1f dBFS "
           "(layout=%u elements=%zu frames=%llu render_ms=%lld)",
           result.integrated_lufs, result.true_peak_dbtp,
           result.digital_peak_dbfs, impl_->layout, impl_->elements.size(),
           static_cast<unsigned long long>(max_frames),
           static_cast<long long>(render_ms));
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "mix_renderer", buf);

  return result;
}

// ── Post-measurement traces ─────────────────────────────────────────────

uint32_t OfflineMixRenderer::TraceLength(uint32_t series) const {
  return impl_->sink.TraceLength(series);
}

uint32_t OfflineMixRenderer::CopyTrace(uint32_t series, float* out,
                                       uint32_t cap) const {
  return impl_->sink.CopyTrace(series, out, cap);
}

bool OfflineMixRenderer::GetElementClipStats(uint32_t element_id,
                                             uint64_t* out_clipped_samples,
                                             float* out_peak_linear) const {
  if (!impl_->measured) return false;
  const auto it = impl_->element_clip_stats.find(element_id);
  if (it == impl_->element_clip_stats.end()) return false;
  if (out_clipped_samples) *out_clipped_samples = it->second.clipped_samples;
  if (out_peak_linear) *out_peak_linear = it->second.peak_linear;
  return true;
}

bool OfflineMixRenderer::GetLoudnessRange(float* lra_lu,
                                          bool* is_stable) const {
  return impl_->sink.GetLoudnessRange(lra_lu, is_stable);
}

}  // namespace eclipsa_studio
