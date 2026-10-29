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

#include "renderer/oar_renderer.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

#include "engine_log.h"

extern "C" {
#include "oar.h"
}

// channel_order.h repeats the value to stay free of the OAR dependency.
static_assert(eclipsa_studio::kOarLayout916 == ck_oar_layout_916);

// Map our element type ints to OAR's enum.
static audio_element_type_t to_oar_type(int type) {
  switch (type) {
    case 0:
      return ck_channel_based;
    case 1:
      return ck_scene_based;
    case 2:
      return ck_object_based;
    default:
      return ck_oar_element_type_none;
  }
}

OarRenderer::OarRenderer() = default;

OarRenderer::~OarRenderer() { shutdown(); }

bool OarRenderer::init(uint32_t sample_rate, uint32_t buffer_size,
                       uint32_t layout) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  shutdown_locked();

  sample_rate_ = sample_rate;
  buffer_size_.store(buffer_size, std::memory_order_relaxed);
  layout_ = layout;

  renderer_ = create_renderer(layout);
  if (!renderer_) return false;

  const uint32_t ch = oar_get_number_of_output_channels(renderer_);
  channel_count_.store(ch, std::memory_order_relaxed);
  rendered_layout_.store(layout, std::memory_order_relaxed);
  output_.resize(static_cast<size_t>(ch) * buffer_size, 0.0f);

  // Generous interleaved scratch buffer.
  interleaved_tmp_.resize(static_cast<size_t>(28) * buffer_size, 0.0f);

  {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "init: rate=%u buf=%u layout=%u ch=%u interleaved_tmp=%zu",
             sample_rate, buffer_size, layout, ch, interleaved_tmp_.size());
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
  }

  return true;
}

void OarRenderer::shutdown() {
  std::lock_guard<std::mutex> lock(control_mutex_);
  shutdown_locked();
}

void OarRenderer::shutdown_locked() {
  ReconfigGuard guard(reconfiguring_);
  // Both call sites (init() pre-device-start, destructor post
  // AudioThread::stop()) guarantee no audio thread, so destroying
  // without an ack is safe by call order. The short wait below is
  // belt-and-braces for a misuse we can't rule out statically; on
  // timeout — the normal case when no device is running — we proceed.
  if (renderer_ || !zombies_.empty()) {
    wait_for_audio_thread_ack(/*timeout_ms=*/50);
  }
  reap_zombies_locked();
  if (renderer_) {
    oar_destroy(renderer_);
    renderer_ = nullptr;
  }
  channel_count_.store(0, std::memory_order_relaxed);
  rendered_layout_.store(0, std::memory_order_relaxed);
  limiter_delay_.store(0, std::memory_order_relaxed);
  output_.clear();
  interleaved_tmp_.clear();
  elements_.clear();
}

void OarRenderer::reap_zombies_locked() {
  if (zombies_.empty()) return;
  for (auto& z : zombies_) {
    if (z.renderer) oar_destroy(z.renderer);
  }
  char buf[96];
  snprintf(buf, sizeof(buf), "reaped %zu deferred renderer teardown(s)",
           zombies_.size());
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
  zombies_.clear();
}

oar_t* OarRenderer::create_renderer(uint32_t layout) {
  if (fail_create_for_testing_.load(std::memory_order_relaxed)) return nullptr;

  oar_config_t cfg{};
  cfg.target_layout = static_cast<oar_layout_t>(layout);
  cfg.samples_per_channel = buffer_size_.load(std::memory_order_relaxed);
  cfg.sampling_rate = sample_rate_;

  oar_t* r = oar_create(&cfg);
  if (!r) return nullptr;

  // Create the default audio group (gid=0) — required before adding elements.
  oar_add_audio_group(r);

  // Disable OAR's internal loudness normalisation — Eclipsa Studio
  // handles that.
  oar_enable_loudness_processor(r, 0);
  // The -1 dBFS peak limiter is on in live monitoring and in the app's
  // offline measurement; the app has no off switch (ES-491/ES-492 decision;
  // the exported bitstream is still unlimited). set_limiter_enabled()
  // turns it off for the measure CLI's unlimited render only.
  const bool limiter_on = limiter_enabled_.load(std::memory_order_relaxed);
  oar_enable_limiter(r, limiter_on ? 1 : 0);
  // The delay cache follows the instance: create_renderer() is the
  // only place a new OAR instance is built, so rebuilds (layout /
  // device switches) refresh it by construction. A disabled limiter
  // does not delay the block.
  limiter_delay_.store(
      limiter_on ? static_cast<uint32_t>(std::max(0, oar_get_limiter_delay(r)))
                 : 0u,
      std::memory_order_relaxed);
  instance_generation_.fetch_add(1, std::memory_order_relaxed);

  // Add all currently tracked elements.
  for (const auto& el : elements_) {
    oar_audio_element_config_t aecfg{};
    aecfg.type = to_oar_type(el.type);
    switch (el.type) {
      case 0:  // channel-based
        aecfg.cbc.layout = static_cast<oar_layout_t>(el.sub_type);
        break;
      case 1:  // scene-based
        aecfg.sbc.order = static_cast<oar_hoa_t>(el.sub_type);
        break;
      case 2:  // object-based
        aecfg.obc.num_objects = el.sub_type;
        break;
      default:
        break;
    }
    // Forward the per-element IAMF rendering config to OAR. Setting the
    // flag bit is what makes OAR actually consume these fields — without
    // it, the library falls back to ck_binaural_filter_profile_default
    // and skips the headphones_rendering_mode / head-locked branches
    // (see audio_element_renderer.c:187 / audio_renderer_base.c:65).
    aecfg.parameters.flags |=
        def_parameter_set_flag_iamf_element_rendering_config;
    aecfg.parameters.element_rendering_config.headphones_rendering_mode =
        static_cast<oar_headphones_rendering_mode_t>(el.headphones_mode);
    aecfg.parameters.element_rendering_config.binaural_filter_profile =
        static_cast<oar_binaural_filter_profile_t>(el.binaural_profile);
    if (oar_add_audio_element(r, /*gid=*/0, el.id, &aecfg) != ck_oar_ok) {
      char buf[96];
      snprintf(buf, sizeof(buf),
               "create_renderer: oar_add_audio_element failed for id=%u",
               el.id);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "oar", buf);
      continue;
    }

    // OAR creates an element's gain queue, and reserves its storage, on
    // the first gain push for the element's id. The audio thread pushes
    // a gain every callback (set_element_mix_gain), so push one here on
    // the control thread: a zero-duration gain covers no sample and is
    // dropped, without a log, at the first render in which an element has
    // data.
    oar_metadata_t gain{};
    gain.type = ck_metadata_gain;
    gain.gain.id = el.id;
    gain.gain.param_type = ck_param_constant;
    gain.duration = 0;
    if (oar_update_audio_element_metadata(r, el.id, &gain) != ck_oar_ok) {
      char buf[128];
      snprintf(buf, sizeof(buf),
               "create_renderer: no gain queue for id=%u; the first "
               "callback creates it",
               el.id);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "oar", buf);
    }
  }

  return r;
}

bool OarRenderer::add_element(uint32_t element_id, int type, int sub_type,
                              uint32_t channels) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "add_element: id=%u type=%d sub=%d channels=%u buffer_size=%u",
             element_id, type, sub_type, channels,
             buffer_size_.load(std::memory_order_relaxed));
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
  }

  // Remove any existing entry with the same ID (type change on an
  // already-tracked element) before re-adding.
  elements_.erase(std::remove_if(elements_.begin(), elements_.end(),
                                 [element_id](const ElementInfo& e) {
                                   return e.id == element_id;
                                 }),
                  elements_.end());

  // Track it, then rebuild the renderer with the full element set
  // (OAR requires all elements at creation time).
  elements_.push_back({element_id, type, sub_type, channels});
  return rebuild();
}

void OarRenderer::remove_element(uint32_t element_id) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  elements_.erase(std::remove_if(elements_.begin(), elements_.end(),
                                 [element_id](const ElementInfo& e) {
                                   return e.id == element_id;
                                 }),
                  elements_.end());
  rebuild();
}

bool OarRenderer::set_element_rendering_config(uint32_t element_id,
                                               uint32_t mode,
                                               uint32_t profile) {
  enum class Result { kNoOp, kStaged, kUnknown };
  Result result = Result::kUnknown;
  {
    std::lock_guard<std::mutex> lock(control_mutex_);
    for (auto& el : elements_) {
      if (el.id != element_id) continue;
      if (el.headphones_mode == mode && el.binaural_profile == profile) {
        result = Result::kNoOp;
        break;
      }
      el.headphones_mode = mode;
      el.binaural_profile = profile;
      rendering_config_dirty_ = true;
      result = Result::kStaged;
      break;
    }
  }
  // Log outside the critical section — no need to hold the lock while
  // formatting and staging the message.
  switch (result) {
    case Result::kNoOp:
      return true;
    case Result::kStaged: {
      char buf[160];
      snprintf(buf, sizeof(buf),
               "stage rendering_config: id=%u mode=%u profile=%u", element_id,
               mode, profile);
      engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
      return true;
    }
    case Result::kUnknown: {
      char buf[96];
      snprintf(buf, sizeof(buf),
               "set_element_rendering_config: unknown element id=%u",
               element_id);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "oar", buf);
      return false;
    }
  }
  return false;
}

bool OarRenderer::commit_rendering_config() {
  bool ok = true;
  bool did_rebuild = false;
  {
    std::lock_guard<std::mutex> lock(control_mutex_);
    if (rendering_config_dirty_) {
      ok = rebuild();
      rendering_config_dirty_ = false;
      did_rebuild = true;
    }
  }
  if (did_rebuild) {
    char buf[96];
    snprintf(buf, sizeof(buf), "commit rendering_config: rebuilt ok=%d",
             ok ? 1 : 0);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
  }
  return ok;
}

void OarRenderer::update_element_data(
    uint32_t element_id, const float* data, uint32_t channels, uint32_t frames,
    uint32_t stride, const eclipsa_studio::ChannelOrder* input_order) {
  // OAR expects planar float data (ch0[0..N], ch1[0..N], ...).
  // Our AudioBuffer is planar with `stride` (capacity_frames) between channels.
  const size_t total = static_cast<size_t>(channels) * frames;
  const uint32_t buf_size = buffer_size_.load(std::memory_order_relaxed);
  // Never resize on the audio thread — buffer was pre-allocated at init.
  if (total > interleaved_tmp_.size()) {
    if (update_drop_log_count_.load(std::memory_order_relaxed) < 5) {
      char buf[192];
      snprintf(buf, sizeof(buf),
               "update_element_data: DROPPING id=%u — "
               "total=%zu > interleaved_tmp=%zu "
               "(ch=%u, frames=%u, buf_size=%u)",
               element_id, total, interleaved_tmp_.size(), channels, frames,
               buf_size);
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "oar", buf);
      update_drop_log_count_.fetch_add(1, std::memory_order_relaxed);
    }
    return;
  }

  // Warn if frames don't match OAR's configured samples_per_channel.
  if (frames != buf_size &&
      mismatch_log_count_.load(std::memory_order_relaxed) < 5) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "update_element_data: frame mismatch — "
             "frames=%u, oar_buf=%u, id=%u",
             frames, buf_size, element_id);
    engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "oar", buf);
    mismatch_log_count_.fetch_add(1, std::memory_order_relaxed);
  }

  // Compact planar data: our AudioBuffer uses `stride` (capacity_frames)
  // between channels, but OAR expects contiguous planar (frames between
  // channels). When stride == frames and the channels are fed as they
  // are, the data is already contiguous. An input order is applied in
  // the same copy: OAR channel c takes source channel
  // input_order->source[c]. A table whose channel count differs from
  // `channels` is ignored, so every source index stays below
  // `channels` (a table's entries are below its own count).
  const uint8_t* source =
      input_order != nullptr && input_order->channels == channels
          ? input_order->source
          : nullptr;
  const float* planar = data;
  if (stride != frames || source != nullptr) {
    for (uint32_t c = 0; c < channels; ++c) {
      const uint32_t s = source != nullptr ? source[c] : c;
      std::memcpy(interleaved_tmp_.data() + c * frames,
                  data + static_cast<size_t>(s) * stride,
                  frames * sizeof(float));
    }
    planar = interleaved_tmp_.data();
  }

  oar_audio_block_t block{};
  block.data = const_cast<float*>(planar);
  block.channels = channels;
  block.samples_per_channel = frames;

  if (renderer_) oar_update_audio_element_data(renderer_, element_id, &block);
}

void OarRenderer::set_element_mix_gain(uint32_t element_id, float start_db,
                                       float end_db, uint32_t frames) {
  if (!renderer_) return;
  oar_metadata_t meta{};
  meta.type = ck_metadata_gain;
  meta.gain.id = element_id;
  meta.gain.param_type = ck_param_animated;
  meta.gain.animated_gains.animation_type = ck_animation_type_linear;
  meta.gain.animated_gains.data.start = start_db;
  meta.gain.animated_gains.data.end = end_db;
  meta.duration = static_cast<int>(frames);
  oar_update_audio_element_metadata(renderer_, element_id, &meta);
}

void OarRenderer::set_element_object_positions(
    uint32_t element_id, uint32_t count, const float* az_deg,
    const float* el_deg, const float* dist, uint32_t frames) {
  if (!renderer_) return;
  const uint32_t n =
      count < 1 ? 1
                : (count > def_max_number_of_objects ? def_max_number_of_objects
                                                     : count);
  oar_metadata_t meta{};
  meta.type = ck_metadata_object_positions;
  meta.object_positions.param_type = ck_param_constant;
  meta.object_positions.position_type = ck_polar;
  meta.object_positions.num_objects = n;
  for (uint32_t i = 0; i < n; ++i) {
    meta.object_positions.polar_positions[i].azimuth = az_deg[i];
    meta.object_positions.polar_positions[i].elevation = el_deg[i];
    meta.object_positions.polar_positions[i].distance = dist[i];
  }
  meta.duration = static_cast<int>(frames);
  oar_update_audio_element_metadata(renderer_, element_id, &meta);
}

void OarRenderer::set_output_mix_gain(float start_db, float end_db,
                                      uint32_t frames, uint32_t gid) {
  if (!renderer_) return;
  oar_metadata_t meta{};
  meta.type = ck_metadata_gain;
  meta.gain.id = gid;
  meta.gain.param_type = ck_param_animated;
  meta.gain.animated_gains.animation_type = ck_animation_type_linear;
  meta.gain.animated_gains.data.start = start_db;
  meta.gain.animated_gains.data.end = end_db;
  meta.duration = static_cast<int>(frames);
  oar_update_metadata(renderer_, gid, &meta);
}

const float* OarRenderer::render(uint32_t frames) {
  if (!renderer_) return nullptr;

  // The cached count matches what output_ was sized for at rebuild —
  // one fewer OAR call per callback, and consistent with the buffer.
  const uint32_t ch = channel_count_.load(std::memory_order_relaxed);
  const size_t total = static_cast<size_t>(ch) * frames;
  // Never resize on the audio thread — buffer was pre-allocated at init.
  if (total > output_.size()) {
    if (render_drop_log_count_.load(std::memory_order_relaxed) < 5) {
      char buf[192];
      snprintf(buf, sizeof(buf),
               "render: DROPPING — total=%zu > buf=%zu "
               "(ch=%u, frames=%u, buf_size=%u)",
               total, output_.size(), ch, frames,
               buffer_size_.load(std::memory_order_relaxed));
      engine_log_rt(ECLIPSA_STUDIO_LOG_WARN, "oar", buf);
      render_drop_log_count_.fetch_add(1, std::memory_order_relaxed);
    }
    return nullptr;
  }

  oar_audio_block_t out{};
  out.data = output_.data();
  out.channels = ch;
  out.samples_per_channel = frames;

  oar_render(renderer_, &out);
  return output_.data();
}

bool OarRenderer::set_limiter_enabled(bool enabled) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  // The audio thread renders without control_mutex_, OAR must not see
  // overlapping calls, and turning the limiter back on resets its delay
  // line mid-stream, so only an instance no audio thread drives
  // changes. Refusing an unbuilt one too keeps the setting off every
  // instance the live renderer's init() and rebuilds create.
  if (!no_audio_thread_) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "oar",
               "set_limiter_enabled refused: the instance is not marked "
               "set_no_audio_thread()");
    return false;
  }
  limiter_enabled_.store(enabled, std::memory_order_relaxed);
  // A disabled OAR limiter returns before updating its envelope, so its
  // last value would read as reduction in every later block.
  if (!enabled) limiter_env_.store(1.0, std::memory_order_relaxed);
  if (renderer_ == nullptr) return true;
  oar_enable_limiter(renderer_, enabled ? 1 : 0);
  // oar_get_limiter_delay() reports the delay line's size whether or not
  // the limiter runs.
  limiter_delay_.store(enabled ? static_cast<uint32_t>(std::max(
                                     0, oar_get_limiter_delay(renderer_)))
                               : 0u,
                       std::memory_order_relaxed);
  return true;
}

double OarRenderer::limiter_env() const {
  return limiter_env_.load(std::memory_order_relaxed);
}

void OarRenderer::snapshot_limiter_env() {
  // While the limiter is off OAR's envelope keeps its last value, and
  // set_limiter_enabled(false) left the cache at 1.0.
  if (renderer_ && limiter_enabled_.load(std::memory_order_relaxed)) {
    limiter_env_.store(oar_get_limiter_env(renderer_),
                       std::memory_order_relaxed);
  }
}

bool OarRenderer::set_layout(uint32_t layout) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  const uint32_t prev = layout_;
  // The current instance already renders this layout with every tracked
  // element (or, while offline-exclusive mode is held, the deferred
  // rebuild will build it), so a rebuild would only cut the output
  // while it runs. Playback sets the monitoring layout on every mix
  // switch (ES-987).
  if (layout == prev && renderer_ != nullptr) {
    char buf[64];
    snprintf(buf, sizeof(buf), "set_layout: %u unchanged, no rebuild", layout);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
    return true;
  }
  layout_ = layout;
  bool ok = rebuild();
  {
    char buf[128];
    snprintf(buf, sizeof(buf), "set_layout: %u -> %u, ch=%u, ok=%d", prev,
             layout, channel_count(), ok ? 1 : 0);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
  }
  return ok;
}

bool OarRenderer::reinit_for_format(uint32_t new_sample_rate,
                                    uint32_t new_buffer_size) {
  std::lock_guard<std::mutex> lock(control_mutex_);
  sample_rate_ = new_sample_rate;
  buffer_size_.store(new_buffer_size, std::memory_order_relaxed);
  bool ok = rebuild();
  {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "reinit_for_format: rate=%u buf=%u layout=%u ch=%u elements=%zu",
             new_sample_rate, new_buffer_size, layout_, channel_count(),
             elements_.size());
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
  }
  return ok;
}

bool OarRenderer::fade_out_and_wait(int timeout_ms) {
  // No audio thread ever renders this instance: nothing is audible, so
  // there is nothing to fade — and nothing would ever advance the gain
  // (ES-515). Don't touch fade_target_: the fade state stays at unity.
  if (no_audio_thread_) return true;
  // Always fade OUT at the short default, even if a stretched
  // fade-in (device-switch reopen) is mid-ramp — a 100 ms fade-out
  // would stall every rebuild/reconfigure behind an audible tail.
  fade_seconds_.store(kFadeSeconds, std::memory_order_relaxed);
  fade_target_.store(0.0f, std::memory_order_release);
  if (fade_gain_.load(std::memory_order_acquire) <= 0.0f) return true;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (fade_gain_.load(std::memory_order_acquire) > 0.0f) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::yield();
  }
  return true;
}

void OarRenderer::fade_block(uint32_t frames, uint32_t sample_rate, float* g0,
                             float* g1) {
  const float target = fade_target_.load(std::memory_order_acquire);
  const float start = fade_gain_.load(std::memory_order_relaxed);
  if (start == target) {
    *g0 = *g1 = target;
    return;
  }
  // Linear ramp toward the target; a block longer than the fade
  // stretches the ramp across the whole block (still click-free).
  //
  // Load AFTER fade_target_: the acquire load above is what publishes
  // this value (both writers store it before their release store on
  // the target). Hoisting this load beside the other two breaks that
  // pairing — a stale stretched length paired with a fresh fade-out
  // target would overrun kFadeWaitTimeoutMs and click.
  const float fade_seconds = fade_seconds_.load(std::memory_order_relaxed);
  const float step = (sample_rate > 0)
                         ? static_cast<float>(frames) /
                               (fade_seconds * static_cast<float>(sample_rate))
                         : 1.0f;
  float end = (target > start) ? start + step : start - step;
  if ((target > start) ? (end > target) : (end < target)) end = target;
  fade_gain_.store(end, std::memory_order_release);
  *g0 = start;
  *g1 = end;
}

bool OarRenderer::wait_for_audio_thread_ack(int timeout_ms) {
  // With no audio thread by construction there is no in-flight OAR
  // access to drain — report success immediately so rebuild() and
  // shutdown() tear down without spinning to the timeout (ES-515).
  if (no_audio_thread_) return true;

  // Spin-wait until the audio thread acknowledges it has seen the flag
  // (via acknowledge_reconfiguring() in AudioGraph::process).
  //
  // The ack is posted at the end of a process() call, AFTER the feed
  // loop and any in-flight OAR calls have completed. Callers rely on
  // this so subsequent oar_destroy() / oar_create() calls don't race a
  // concurrent feed loop.
  //
  // The timeout is an escape hatch for when the audio device isn't
  // actually running (init / device swap). Default 500 ms is generous
  // relative to any plausible callback duration (~10 ms at 48 k/512)
  // so that under any realistic load the ack arrives first.
  const uint64_t prev_ack = ack_counter_.load(std::memory_order_acquire);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (ack_counter_.load(std::memory_order_acquire) == prev_ack) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::yield();
  }
  return true;
}

bool OarRenderer::rebuild() {
  // Offline-exclusive mode (ES-158): no live oar_create/oar_destroy at
  // all while the offline renderers run — the requested configuration
  // is already staged in elements_/layout_/buffer_size_, so just mark
  // it for replay on end_offline_exclusive().
  if (offline_exclusive_depth_.load(std::memory_order_relaxed) > 0) {
    rebuild_deferred_ = true;
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar",
               "rebuild deferred: offline-exclusive mode held "
               "(replayed on exit)");
    return true;
  }

  // Each configuration gets a fresh warning budget — see the throttle
  // members in the header.
  update_drop_log_count_.store(0, std::memory_order_relaxed);
  mismatch_log_count_.store(0, std::memory_order_relaxed);
  render_drop_log_count_.store(0, std::memory_order_relaxed);

  // Fade the old configuration's output to silence BEFORE setting the
  // reconfiguring flag — the audio thread keeps rendering during the
  // fade (the renderer stays alive until the ack below), so the
  // silence gap starts from zero instead of a hard cut (issue ES-73).
  // Skipped when nothing is rendering; returns immediately when the
  // gain is already zero (nested rebuild during a device reconfigure).
  if (renderer_ != nullptr && !fade_out_and_wait()) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "oar",
               "rebuild: fade-out timeout — audio thread may not be "
               "running; proceeding (output may click)");
  }

  // Set the flag so the audio thread skips OAR on its next iteration,
  // then wait for the ack so any in-flight oar_render() has completed
  // before we tear the instance down.
  reconfiguring_.store(true, std::memory_order_release);
  const bool acked = wait_for_audio_thread_ack();
  if (acked) {
    // A successful ack proves no OAR access is in flight — anything
    // deferred by an earlier timed-out rebuild is dead too.
    reap_zombies_locked();
  } else {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "oar",
               "rebuild: ack timeout — audio thread may be stalled or "
               "not running; deferring old renderer teardown");
  }

  if (renderer_) {
    if (acked) {
      oar_destroy(renderer_);
    } else {
      // The audio thread may still be inside oar_render() on this
      // instance, writing into output_ — stash the instance AND its
      // buffers until a later successful ack (or shutdown) proves the
      // access has drained. Destroying here was the old behaviour and
      // a use-after-free window.
      Zombie z;
      z.renderer = renderer_;
      z.output.swap(output_);
      z.interleaved_tmp.swap(interleaved_tmp_);
      zombies_.push_back(std::move(z));
    }
    renderer_ = nullptr;
  }

  const uint32_t buf_size = buffer_size_.load(std::memory_order_relaxed);

  if (elements_.empty() && layout_ == 0) {
    channel_count_.store(0, std::memory_order_relaxed);
    rendered_layout_.store(0, std::memory_order_relaxed);
    reconfiguring_.store(false, std::memory_order_release);
    fade_in();
    return true;
  }

  renderer_ = create_renderer(layout_);
  if (!renderer_) {
    channel_count_.store(0, std::memory_order_relaxed);
    rendered_layout_.store(0, std::memory_order_relaxed);
    reconfiguring_.store(false, std::memory_order_release);
    fade_in();
    return false;
  }

  const uint32_t ch = oar_get_number_of_output_channels(renderer_);
  channel_count_.store(ch, std::memory_order_relaxed);
  rendered_layout_.store(layout_, std::memory_order_relaxed);
  output_.assign(static_cast<size_t>(ch) * buf_size, 0.0f);
  interleaved_tmp_.assign(static_cast<size_t>(28) * buf_size, 0.0f);

  reconfiguring_.store(false, std::memory_order_release);
  // Ramp back up on the new configuration's first rendered blocks.
  fade_in();
  return true;
}

void OarRenderer::begin_offline_exclusive() {
  std::lock_guard<std::mutex> lock(control_mutex_);
  const uint32_t depth =
      offline_exclusive_depth_.load(std::memory_order_relaxed);
  if (depth > 0) {
    // Nested enter: another offline pass already holds the mode (the
    // export dialog and loudness report can overlap — the native menu
    // bar is not blocked by Flutter's modal barrier). Offline
    // instances are independent (ES-494), so just deepen the hold; the
    // live OAR is already silent and acked.
    offline_exclusive_depth_.store(depth + 1, std::memory_order_release);
    char buf[64];
    snprintf(buf, sizeof(buf), "offline-exclusive: nested enter (depth=%u)",
             depth + 1);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
    return;
  }
  // Fade the live output to silence first (click-free pause, ES-73);
  // skipped when nothing is rendering.
  if (renderer_ != nullptr && !fade_out_and_wait()) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "oar",
               "begin_offline_exclusive: fade-out timeout — audio "
               "thread may not be running");
  }
  offline_exclusive_depth_.store(1, std::memory_order_release);
  reconfiguring_.store(true, std::memory_order_release);
  const bool acked = wait_for_audio_thread_ack();
  if (acked) reap_zombies_locked();
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar",
             acked ? "offline-exclusive: entered (audio thread acked)"
                   : "offline-exclusive: entered (ack timeout — audio "
                     "device may not be running)");
}

bool OarRenderer::end_offline_exclusive() {
  std::lock_guard<std::mutex> lock(control_mutex_);
  const uint32_t depth =
      offline_exclusive_depth_.load(std::memory_order_relaxed);
  if (depth == 0) return false;
  offline_exclusive_depth_.store(depth - 1, std::memory_order_release);
  if (depth > 1) {
    // Another offline pass still holds the mode — the live OAR stays
    // paused and any deferred rebuild waits for the last exit.
    char buf[64];
    snprintf(buf, sizeof(buf), "offline-exclusive: nested exit (depth=%u)",
             depth - 1);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
    return false;
  }
  if (rebuild_deferred_) {
    rebuild_deferred_ = false;
    // Replays the staged element/layout/format state; clears
    // reconfiguring_ and fades back in itself.
    const bool ok = rebuild();
    char buf[96];
    snprintf(buf, sizeof(buf),
             "offline-exclusive: exited, deferred rebuild replayed ok=%d",
             ok ? 1 : 0);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", buf);
    return true;
  }
  reconfiguring_.store(false, std::memory_order_release);
  fade_in();
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "oar", "offline-exclusive: exited");
  return false;
}
