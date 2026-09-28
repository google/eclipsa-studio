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
#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <vector>

#include "bounce/element_stream.h"
#include "engine_log.h"
#include "graph/audio_buffer.h"
#include "include/ebur128_analyzer.h"
#include "meters/bs1770_weights.h"
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
  // Kept alive after RenderAndMeasure() so the recorded time series
  // (momentary/short-term traces, LRA) stay queryable. Reset at the
  // start of each measurement run.
  std::unique_ptr<loudness::EbuR128Analyzer> analyzer;
  // Per-element signal-overload stats from the last successful run,
  // keyed by element_id. Same keep-alive/reset lifecycle as the
  // analyzer traces above.
  struct ElementClipStats {
    uint64_t clipped_samples = 0;
    float peak_linear = 0.0f;
  };
  std::map<uint32_t, ElementClipStats> element_clip_stats;
  // Limiter gain reduction (dB, >= 0) per kTraceStepMs step of the
  // last successful run — kTraceLimiterGrDb. The envelope is sampled
  // once per render block (its end-of-block value), so sustained
  // limiting reads accurately while isolated transients read low —
  // resolution is bounded by the render block size (ES-541). Same
  // keep-alive/reset lifecycle as the analyzer traces above.
  std::vector<float> limiter_gr_db;
  bool measured = false;
};

// ── Lifecycle ───────────────────────────────────────────────────────────

OfflineMixRenderer::OfflineMixRenderer() : impl_(std::make_unique<Impl>()) {}

OfflineMixRenderer::~OfflineMixRenderer() = default;

bool OfflineMixRenderer::Init(uint32_t sample_rate, uint32_t buffer_size,
                              uint32_t layout) {
  // Reject absurd sample rates up front — reachable from the C ABI.
  // Below 10 Hz the GR-trace step (sr * kTraceStepMs / 1000) truncates
  // to zero frames and the bucket-advance loop never terminates; no
  // real program sits below phone-band rates anyway.
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

  // Offline instance: no audio thread will ever drive it, so OAR's
  // fade/ack waits must short-circuit — otherwise every AddElement
  // rebuild spins ~0.55 s to their timeouts (ES-515).
  impl_->oar.set_no_audio_thread();

  if (!impl_->oar.init(sample_rate, buffer_size, layout)) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "Failed to initialize OAR for offline render");
    return false;
  }

  // The -1 dBFS peak limiter is unconditionally on for every OAR
  // instance (create_renderer() in renderer/oar_renderer.cc), so this
  // measurement is post-limiter while the encoded file ships
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

void OfflineMixRenderer::SetOutputMixGain(float gain_db) {
  impl_->output_mix_gain_db = gain_db;
}

// ── Render + measure ────────────────────────────────────────────────────

std::optional<LoudnessResult> OfflineMixRenderer::RenderAndMeasure() {
  LoudnessResult result;

  // Drop any previous run's series before re-measuring.
  impl_->analyzer.reset();
  impl_->element_clip_stats.clear();
  impl_->limiter_gr_db.clear();
  impl_->measured = false;

  if (impl_->elements.empty()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "No elements to render");
    return std::nullopt;
  }

  const uint32_t sr = impl_->sample_rate;
  const uint32_t bs = impl_->buffer_size;
  const uint32_t out_ch = impl_->oar.channel_count();

  if (out_ch == 0) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "OAR reports 0 output channels");
    return std::nullopt;
  }

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

  // ── Create loudness analyzer ──────────────────────────────────────
  // Channel weights mirror iamf-tools' BS.1770 per-layout tables
  // (meters/bs1770_weights.cc). If the layout isn't in the table or the
  // channel count disagrees with the renderer, fall back to uniform 1.0 and
  // warn — the measurement will then not match BS.1770-5 for layouts above
  // stereo.
  std::vector<float> weights = Bs1770WeightsForLayout(impl_->layout);
  if (weights.size() != out_ch) {
    char buf[160];
    snprintf(buf, sizeof(buf),
             "No BS.1770 weights for layout=%u (out_ch=%u, table=%zu); "
             "using uniform 1.0 — result will not match broadcast tools",
             impl_->layout, out_ch, weights.size());
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "mix_renderer", buf);
    weights.assign(out_ch, 1.0f);
  }
  impl_->analyzer = std::make_unique<loudness::EbuR128Analyzer>(
      static_cast<int32_t>(out_ch), weights, static_cast<int32_t>(sr),
      /*enable_true_peak_measurement=*/true);
  loudness::EbuR128Analyzer* analyzer = impl_->analyzer.get();

  // ── Allocate per-element read buffers ─────────────────────────────
  // Size each buffer to the element's own channel count — OAR ignores
  // anything beyond `channels`, so there's no reason to reserve the
  // kMaxCh worst case per element.
  std::vector<std::vector<float>> elem_storage(readers.size());
  for (size_t i = 0; i < readers.size(); ++i) {
    const uint32_t ch = readers[i]->config.channels;
    elem_storage[i].assign(static_cast<size_t>(ch) * bs, 0.0f);
  }

  // Double-precision scratch for loudness analyzer input.
  std::vector<std::vector<double>> double_buf(out_ch);
  for (auto& v : double_buf) v.resize(bs, 0.0);
  // Pointer table the analyzer consumes. Hoisted out of the render
  // loop so we don't reallocate every block.
  std::vector<const double*> ch_ptrs(out_ch);
  for (uint32_t ch = 0; ch < out_ch; ++ch) {
    ch_ptrs[ch] = double_buf[ch].data();
  }

  // ── Process loop ──────────────────────────────────────────────────
  const auto render_start = std::chrono::steady_clock::now();
  float digital_peak_linear = 0.0f;

  // The limiter delays its output by `delay` frames (5 ms): output
  // frame o carries program frame o - delay, and the first `delay`
  // output frames are zero priming. The loop renders `delay` extra
  // frames past the program (inputs zero-fed) and hands the analyzer,
  // the peak and the GR trace only output frames [delay,
  // delay + max_frames), so every result is on the program timeline.
  const uint64_t delay = impl_->oar.limiter_delay();
  const uint64_t out_end = max_frames > 0 ? max_frames + delay : 0;
  uint64_t in_left = max_frames;
  uint64_t out_done = 0;

  // Limiter GR trace bookkeeping: one entry per kTraceStepMs, the max
  // gain reduction sampled at the end of each rendered block.
  const uint64_t step_frames = uint64_t{sr} * kTraceStepMs / 1000;
  uint64_t frames_done = 0;
  float gr_bucket_max = 0.0f;

  while (out_done < out_end) {
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

      impl_->oar.update_element_data(er.config.element_id, buf.data, ch, bs,
                                     bs);
    }

    // Group-level output mix gain: same per-block push semantics as the
    // element gains above.
    impl_->oar.set_output_mix_gain(impl_->output_mix_gain_db,
                                   impl_->output_mix_gain_db, bs);

    // Render the full block. It covers output frames [out_done,
    // out_done + bs); the program-aligned part is [lo, hi).
    const float* rendered = impl_->oar.render(bs);
    if (rendered == nullptr) {
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
                 "OAR render returned null");
      return std::nullopt;
    }
    const uint64_t lo = std::max(out_done, delay);
    const uint64_t hi = std::min(out_done + bs, out_end);
    const uint32_t count = hi > lo ? static_cast<uint32_t>(hi - lo) : 0;

    // Blocks wholly inside the priming window carry no program frames.
    // Skipping them also keeps `first` below `bs`: with a delay longer
    // than the block, lo - out_done would point past the channel.
    if (count > 0) {
      const uint32_t first = static_cast<uint32_t>(lo - out_done);

      // Track digital peak (sample peak, no upsampling). The rendered
      // output is planar with stride `bs` (the render call above always
      // uses the full block size); only frames [first, first + count)
      // of each channel are program material.
      for (uint32_t ch = 0; ch < out_ch; ++ch) {
        const float* ch_data = rendered + ch * bs + first;
        for (uint32_t f = 0; f < count; ++f) {
          const float abs_val = std::fabs(ch_data[f]);
          if (abs_val > digital_peak_linear) {
            digital_peak_linear = abs_val;
          }
        }
      }

      // Convert float → double for loudness analyzer.
      for (uint32_t ch = 0; ch < out_ch; ++ch) {
        const float* ch_data = rendered + ch * bs + first;
        for (uint32_t f = 0; f < count; ++f) {
          double_buf[ch][f] = static_cast<double>(ch_data[f]);
        }
      }
      analyzer->Process(ch_ptrs.data(), static_cast<int64_t>(count),
                        loudness::EbuR128Analyzer::DOUBLE,
                        loudness::EbuR128Analyzer::PLANAR_NON_CONTIGUOUS);
    }

    // Sample the limiter envelope at block end and fold it into the
    // 100 ms GR trace. gr_bucket_max carries across blocks that span a
    // bucket boundary; the current sample seeds the next bucket so the
    // release tail stays visible. Calling snapshot here is legal: this
    // loop IS the render thread of this offline OAR instance. On the
    // final block the render runs up to `bs - 1` frames past the
    // program end, so the last bucket's sample includes up to ~21 ms of
    // release over that padding. Blocks inside the priming window fold
    // their look-ahead attack into the first bucket.
    impl_->oar.snapshot_limiter_env();
    const double env = impl_->oar.limiter_env();
    const float gr_db = (env > 0.0 && env < 1.0)
                            ? static_cast<float>(-20.0 * std::log10(env))
                            : 0.0f;
    gr_bucket_max = std::max(gr_bucket_max, gr_db);
    frames_done += count;
    while (frames_done >= (impl_->limiter_gr_db.size() + 1) * step_frames) {
      impl_->limiter_gr_db.push_back(gr_bucket_max);
      gr_bucket_max = gr_db;
    }

    in_left -= block;
    out_done += bs;
  }

  // Flush the trailing partial bucket so the series covers
  // ceil(program/step) entries.
  if (frames_done % step_frames != 0) {
    impl_->limiter_gr_db.push_back(gr_bucket_max);
  }

  // ── Read results ──────────────────────────────────────────────────
  const auto integrated = analyzer->GetRelativeGatedIntegratedLoudness();
  result.integrated_lufs =
      integrated.has_value() ? static_cast<float>(integrated.value()) : -120.0f;

  result.true_peak_dbtp = static_cast<float>(analyzer->true_peak_dbfs());

  result.digital_peak_dbfs = (digital_peak_linear > 0.0f)
                                 ? 20.0f * std::log10(digital_peak_linear)
                                 : -120.0f;

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

namespace {

// The analyzer stores short-term peaks as linear magnitudes; every other
// series is already in dB. Convert on the way out so all series reach
// the caller in dB.
float LinearToDbfs(float v) {
  return (v > 0.0f) ? 20.0f * std::log10(v) : -120.0f;
}

const std::vector<float>* SeriesFor(const loudness::EbuR128Analyzer& a,
                                    uint32_t series) {
  switch (series) {
    case kTraceMomentaryLufs:
      return &a.ungated_momentary_lkfs();
    case kTraceShortTermLufs:
      return &a.ungated_short_term_lkfs();
    case kTraceShortTermPeakDbfs:
      return &a.short_term_peaks();
    case kTraceShortTermPsrDb:
      return &a.short_term_psr();
    default:
      return nullptr;
  }
}

}  // namespace

uint32_t OfflineMixRenderer::TraceLength(uint32_t series) const {
  if (!impl_->measured) return 0;
  if (series == kTraceLimiterGrDb) {
    return static_cast<uint32_t>(impl_->limiter_gr_db.size());
  }
  const auto* values = SeriesFor(*impl_->analyzer, series);
  return values ? static_cast<uint32_t>(values->size()) : 0;
}

uint32_t OfflineMixRenderer::CopyTrace(uint32_t series, float* out,
                                       uint32_t cap) const {
  if (!impl_->measured || out == nullptr) return 0;
  if (series == kTraceLimiterGrDb) {
    const uint32_t n =
        std::min(cap, static_cast<uint32_t>(impl_->limiter_gr_db.size()));
    std::copy_n(impl_->limiter_gr_db.begin(), n, out);
    return n;
  }
  const auto* values = SeriesFor(*impl_->analyzer, series);
  if (values == nullptr) return 0;
  const uint32_t n = std::min(cap, static_cast<uint32_t>(values->size()));
  const bool linear = series == kTraceShortTermPeakDbfs;
  for (uint32_t i = 0; i < n; ++i) {
    const float v = linear ? LinearToDbfs((*values)[i]) : (*values)[i];
    // The analyzer emits non-finite entries over digital silence (NaN
    // momentary in a padded silence tail, +inf PSR over leading
    // silence). Clamp to the -120 floor so the copied series is always
    // finite: <= -120 uniformly means silence / no data.
    out[i] = std::isfinite(v) ? v : -120.0f;
  }
  return n;
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
  if (!impl_->measured) return false;
  bool stable = false;
  const auto stats = impl_->analyzer->GetLoudnessRangeStats(&stable);
  if (!stats.has_value()) return false;
  if (lra_lu) *lra_lu = stats->loudness_range_lu;
  if (is_stable) *is_stable = stable;
  return true;
}

}  // namespace eclipsa_studio
