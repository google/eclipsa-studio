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

#include "engine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <optional>

#include "audio_thread.h"
#include "graph/audio_graph.h"
#include "iamf/iamf_exporter.h"
#include "iamf/iamf_muxer.h"
#include "iamf/iamf_playback_session.h"
#include "io/device_manager.h"
#include "io/volume_info.h"
#include "mix_renderer/offline_iamf_measurer.h"
#include "mix_renderer/offline_mix_renderer.h"
#include "renderer/oar_capability.h"
#include "renderer/oar_renderer.h"
#include "video/still_video_encoder.h"

// Version stamped by build.sh / build.ps1 into the gitignored
// generated/engine_version.h so eclipsa_studio_version() reports the same
// version as the app. A bare `bazel build` without the build script
// has no such file and falls back to "dev".
#if __has_include("generated/engine_version.h")
#include "generated/engine_version.h"  // IWYU pragma: keep
#endif
#ifndef ECLIPSA_STUDIO_ENGINE_VERSION
#define ECLIPSA_STUDIO_ENGINE_VERSION "dev"
#endif

// ── Global engine state ────────────────────────────────────────────────────

namespace {

AudioGraph g_graph;
DeviceManager g_device;
AudioThread g_audio_thread;
eclipsa_studio::IamfExporter g_iamf_exporter;
// Guards concurrent entries into the IAMF export run. The exporter
// itself is not reentrant (shared progress/cancel state), so we reject
// overlapping calls at the FFI boundary rather than racing into
// iamf-tools' TestMain.
std::atomic<bool> g_iamf_export_busy{false};

eclipsa_studio::IamfMuxer g_iamf_muxer;
// Guards concurrent entries into eclipsa_studio_iamf_mux. libgpac's session/ISO
// state is not safe to drive from two muxes at once.
std::atomic<bool> g_iamf_mux_busy{false};

// Releases a busy flag on scope exit. The export/mux bodies can throw
// (std::bad_alloc, exceptions out of iamf-tools / libgpac); without RAII
// a throw would leave the flag latched and every later call rejected
// with "already running" for the rest of the process.
class BusyGuard {
 public:
  explicit BusyGuard(std::atomic<bool>& flag) : flag_(flag) {}
  ~BusyGuard() { flag_.store(false); }
  BusyGuard(const BusyGuard&) = delete;
  BusyGuard& operator=(const BusyGuard&) = delete;

 private:
  std::atomic<bool>& flag_;
};

uint32_t g_sample_rate = 48000;
uint32_t g_buffer_size = 512;
bool g_initialized = false;

// Transport loop state — control-thread only.
// Dart manages loop boundaries; the audio thread does not read these.
double g_loop_start_sec = 0.0;
double g_loop_end_sec = 0.0;
bool g_loop_enabled = false;

// Scope guard for chain-mutating barriers: disarms the paused OAR
// drain (ES-530) for the enclosing scope — including early error
// returns — and re-arms on exit. Construct BEFORE the quiescence
// wait, like disarm_paused_seek_hook(): paused callbacks keep firing
// during the mutation and the drain iterates the chain array. The
// underlying gate is a count, so nested barriers (playback_open's
// rollback runs the close barrier) compose.
struct PausedDrainDisarmScope {
  PausedDrainDisarmScope() { g_graph.disarm_paused_drain(); }
  ~PausedDrainDisarmScope() { g_graph.rearm_paused_drain(); }
};

// Converge the engine on the hardware's actual sample rate whenever it
// differs from the rate the engine was targeting. The backend never
// sets the device clock (ES-518) — it opens at whatever rate the device
// is running — so this adoption is the primary mechanism by which the
// engine ends up at the device's rate. A stream paced at one rate
// against a hardware clock ticking at another is a producer/consumer
// slip that starves the device by one buffer per slip period (issue
// ES-30's rhythmic stutter); retargeting the graph at the hardware rate
// makes the backend run conversion-free with callback pacing that
// matches the clock that is actually ticking.
//
// Call after a successful g_audio_thread.start(). Returns the rate in
// effect afterwards (== g_sample_rate). Single retry, no loop: a
// device honours its own hardware rate.
uint32_t AdoptHardwareSampleRate() {
  const uint32_t hw_rate = g_device.hardware_sample_rate();
  if (hw_rate == 0 || hw_rate == g_sample_rate) return g_sample_rate;

  {
    char buf[160];
    snprintf(buf, sizeof(buf),
             "device runs at %u Hz — adopting (engine was targeting %u Hz)",
             hw_rate, g_sample_rate);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  }

  // Retarget while the audio thread is stopped — process() reads the
  // chain resamplers without locking. Keep the playhead at the same
  // wall-clock time, retarget the graph (resamplers, meters), and
  // realign element cursors — the same recipe as a rate reconfigure.
  g_audio_thread.stop();
  const uint32_t prev_rate = g_sample_rate;
  const uint64_t prev_pos = g_audio_thread.position_frames();
  const uint64_t new_pos = (prev_pos * hw_rate + prev_rate / 2) / prev_rate;
  g_audio_thread.seek(new_pos);
  g_sample_rate = hw_rate;
  g_graph.set_sample_rate(hw_rate);
  g_graph.seek(new_pos);

  if (!g_audio_thread.start(g_graph, g_device, hw_rate, g_buffer_size)) {
    // Reopen at the hardware's own rate failed (unexpected) — roll
    // back to the original mismatched stream rather than going silent.
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "engine",
               "reopen at hardware rate failed — keeping mismatched "
               "stream");
    g_sample_rate = prev_rate;
    g_graph.set_sample_rate(prev_rate);
    g_audio_thread.seek(prev_pos);
    g_graph.seek(prev_pos);
    if (!g_audio_thread.start(g_graph, g_device, g_sample_rate,
                              g_buffer_size)) {
      engine_log(ECLIPSA_STUDIO_LOG_ERROR, "engine",
                 "rollback restart failed — engine is silent");
    }
  }
  return g_sample_rate;
}

}  // namespace

// ── Lifecycle ─────────────────────────────────────────────────────────────

extern "C" {

int32_t eclipsa_studio_engine_init(uint32_t sample_rate, uint32_t buffer_size) {
  if (g_initialized) return -1;

  g_sample_rate = sample_rate > 0 ? sample_rate : 48000;
  g_buffer_size = buffer_size > 0 ? buffer_size : 512;

  engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "engine", "Initializing audio graph...");

  if (!g_graph.init(g_sample_rate, g_buffer_size, 2)) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "engine", "Audio graph init failed");
    return -2;
  }

  {
    char buf[128];
    snprintf(buf, sizeof(buf), "Graph init: %u Hz, %u frames", g_sample_rate,
             g_buffer_size);
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "engine", buf);
  }

  // Device enumeration (non-fatal if it fails — engine still works without
  // a physical output device, e.g. in unit-test environments).
  if (!g_device.enumerate()) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine",
               "Audio device enumeration failed");
  } else {
    auto count = g_device.device_count();
    char buf[128];
    snprintf(buf, sizeof(buf), "Found %u audio device(s)", count);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
    for (uint32_t i = 0; i < count; ++i) {
      const auto& name = g_device.device_name(i);
      char dbuf[256];
      snprintf(dbuf, sizeof(dbuf), "  [%u] %s", i, name.c_str());
      engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "engine", dbuf);
    }
  }

  // Pre-emptively mark OAR as reconfiguring so the audio thread outputs
  // silence until we've verified (and possibly corrected) the buffer size.
  auto* oar_pre = g_graph.oar_renderer();
  if (oar_pre) oar_pre->set_reconfiguring(true);

  if (!g_audio_thread.start(g_graph, g_device, g_sample_rate, g_buffer_size)) {
    if (oar_pre) oar_pre->set_reconfiguring(false);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine",
               "Audio device failed to open — meters will not work");
  } else {
    // The hardware may have refused the requested rate, and the actual
    // device period size may differ from the requested size. Adopt
    // both realities, reiniting OAR when either changed.
    const uint32_t rate_before = g_sample_rate;
    AdoptHardwareSampleRate();
    const uint32_t actual_buf = g_device.current_buffer_size();
    if (g_sample_rate != rate_before || actual_buf != g_buffer_size) {
      auto* oar = g_graph.oar_renderer();
      if (oar) oar->reinit_for_format(g_sample_rate, actual_buf);
      g_graph.resync_loudness_meter_if_stale();
      g_buffer_size = actual_buf;
    }
    if (oar_pre) oar_pre->set_reconfiguring(false);

    char buf[128];
    snprintf(buf, sizeof(buf), "Audio thread started (%u Hz, %u frames)",
             g_sample_rate, g_buffer_size);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);

    snprintf(buf, sizeof(buf), "Device started: channels=%u",
             g_device.channel_count());
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "device", buf);
  }

  g_initialized = true;
  return 0;
}

void eclipsa_studio_engine_shutdown(void) {
  if (!g_initialized) return;
  g_audio_thread.stop();
  g_graph.shutdown();
  g_initialized = false;
}

// ── Transport ─────────────────────────────────────────────────────────────

void eclipsa_studio_transport_play(void) {
  engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "transport", "play");
  g_audio_thread.set_playing(true);
}

void eclipsa_studio_transport_pause(void) {
  engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "transport", "pause");
  // User-facing stop: one more callback renders and ramps to silence
  // before the transport parks (ES-530) — a hard set_playing(false)
  // here cut the program mid-waveform, an audible click. Teardown
  // paths keep the instant pause (see request_fade_stop()).
  g_audio_thread.request_fade_stop();
}

void eclipsa_studio_transport_seek(double seconds) {
  auto frame_pos = static_cast<uint64_t>(seconds * g_sample_rate);
  g_audio_thread.seek(frame_pos);
  g_graph.seek(frame_pos);
}

void eclipsa_studio_transport_set_loop(double start_sec, double end_sec) {
  g_loop_start_sec = start_sec;
  g_loop_end_sec = end_sec;
  g_loop_enabled = true;
}

void eclipsa_studio_transport_clear_loop(void) { g_loop_enabled = false; }

uint64_t eclipsa_studio_transport_get_position_frames(void) {
  if (!g_initialized) return 0;
  return g_audio_thread.position_frames();
}

uint8_t eclipsa_studio_transport_is_audio_thread_running(void) {
  return (g_initialized && g_audio_thread.is_running()) ? 1 : 0;
}

// ── Elements ──────────────────────────────────────────────────────────────

int32_t eclipsa_studio_element_add(const char* wav_path, uint32_t element_id) {
  if (!g_initialized || !wav_path) return -1;
  int32_t rc = g_graph.add_element(element_id, wav_path);
  {
    char buf[512];
    snprintf(buf, sizeof(buf), "element_add(id=%u, path=\"%s\") -> rc=%d",
             element_id, wav_path, rc);
    engine_log(ECLIPSA_STUDIO_LOG_DEBUG, "engine", buf);
  }
  return rc;
}

void eclipsa_studio_element_remove(uint32_t element_id) {
  if (!g_initialized) return;
  // remove_element frees the slot's DSP objects and compacts the array
  // while the audio thread's process() may be dereferencing them — the
  // element_count_ release/acquire only guards appends. Mirror the
  // playback_open/close barrier: pause, wait for the in-flight callback
  // to return, mutate, then restore the transport state.
  g_audio_thread.wait_fade_stop_parked();  // Let a user stop land first.
  const bool was_playing = g_audio_thread.is_logically_playing();
  PausedDrainDisarmScope drain_scope;
  g_audio_thread.set_playing(false);
  if (!g_audio_thread.wait_for_callback_quiescent() &&
      g_audio_thread.is_running()) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine",
               "element_remove: audio callback did not quiesce in time; "
               "proceeding");
  }
  g_graph.remove_element(element_id);
  auto* oar = g_graph.oar_renderer();
  if (oar) oar->remove_element(element_id);
  g_graph.resync_loudness_meter_if_stale();
  g_audio_thread.set_playing(was_playing);
}

uint32_t eclipsa_studio_element_ids(uint32_t* out_ids, uint32_t capacity) {
  if (!g_initialized) return 0;
  return g_graph.element_ids(out_ids, capacity);
}

void eclipsa_studio_element_set_gain(uint32_t element_id, float gain_db) {
  if (g_initialized) g_graph.set_element_gain(element_id, gain_db);
}

void eclipsa_studio_element_set_mute(uint32_t element_id, uint8_t muted) {
  if (g_initialized) g_graph.set_element_mute(element_id, muted != 0);
}

void eclipsa_studio_element_set_solo(uint32_t element_id, uint8_t solo) {
  if (g_initialized) g_graph.set_element_solo(element_id, solo != 0);
}

void eclipsa_studio_element_set_mix_excluded(uint32_t element_id,
                                             uint8_t excluded) {
  if (g_initialized) {
    g_graph.set_element_mix_excluded(element_id, excluded != 0);
  }
}

void eclipsa_studio_element_set_mix_gain(uint32_t element_id, float gain_db) {
  if (g_initialized) g_graph.set_element_mix_gain(element_id, gain_db);
}

void eclipsa_studio_element_set_object_position(
    uint32_t element_id, uint32_t num_objects, float azimuth_deg,
    float elevation_deg, float distance, float azimuth2_deg,
    float elevation2_deg, float distance2) {
  if (g_initialized) {
    g_graph.set_element_object_position(element_id, num_objects, azimuth_deg,
                                        elevation_deg, distance, azimuth2_deg,
                                        elevation2_deg, distance2);
  }
}

void eclipsa_studio_element_set_input_routing(uint32_t element_id,
                                              const int8_t* routing,
                                              uint32_t len) {
  if (g_initialized) g_graph.set_element_routing(element_id, routing, len);
}

void eclipsa_studio_element_set_channel_order(uint32_t element_id,
                                              uint32_t order) {
  if (g_initialized) g_graph.set_element_channel_order(element_id, order);
}

void eclipsa_studio_set_output_mix_gain(float gain_db) {
  if (g_initialized) g_graph.set_output_mix_gain(gain_db);
}

void eclipsa_studio_element_seed_mix_gain(uint32_t element_id, float gain_db) {
  if (g_initialized) g_graph.seed_element_mix_gain(element_id, gain_db);
}

void eclipsa_studio_seed_output_mix_gain(float gain_db) {
  if (g_initialized) g_graph.seed_output_mix_gain(gain_db);
}

void eclipsa_studio_set_monitor_dim(int32_t engaged) {
  if (g_initialized) g_graph.set_monitor_dim(engaged != 0);
}

void eclipsa_studio_set_output_solo_mute(uint64_t soloed, uint64_t muted) {
  if (g_initialized) g_graph.set_output_solo_mute(soloed, muted);
}

int32_t eclipsa_studio_element_set_type(uint32_t element_id, int32_t type,
                                        int32_t sub_type, uint32_t channels) {
  // type 1 = scene-based (ambisonics) — only scene elements need the
  // SH active-intensity snapshot on the audio thread.
  g_graph.set_element_scene(element_id, type == 1);
  // type 2 = object-based — the audio thread pushes position metadata
  // to OAR each callback for object chains (silent on loudspeaker
  // layouts otherwise; see eclipsa_studio_element_set_object_position).
  g_graph.set_element_object(element_id, type == 2);

  auto* oar = g_graph.oar_renderer();
  if (!oar) return -1;
  const bool ok = oar->add_element(element_id, type, sub_type, channels);
  g_graph.resync_loudness_meter_if_stale();
  return ok ? 0 : -1;
}

int32_t eclipsa_studio_element_set_rendering_config(uint32_t element_id,
                                                    uint32_t mode,
                                                    uint32_t profile) {
  auto* oar = g_graph.oar_renderer();
  if (!oar) return -1;
  return oar->set_element_rendering_config(element_id, mode, profile) ? 0 : -1;
}

int32_t eclipsa_studio_commit_rendering_config(void) {
  auto* oar = g_graph.oar_renderer();
  if (!oar) return -1;
  const bool ok = oar->commit_rendering_config();
  g_graph.resync_loudness_meter_if_stale();
  return ok ? 0 : -2;
}

// ── Playback (IAMF streaming) ─────────────────────────────────────────────

namespace {

char* DupCStr(const std::string& s) {
  if (s.empty()) return nullptr;
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

EclipsaStudioPlaybackOpenResult* AllocPlaybackResult() {
  auto* r = static_cast<EclipsaStudioPlaybackOpenResult*>(
      std::calloc(1, sizeof(EclipsaStudioPlaybackOpenResult)));
  return r;
}

EclipsaStudioPlaybackOpenResult* PlaybackErrorResult(int32_t status,
                                                     const std::string& msg) {
  auto* r = AllocPlaybackResult();
  if (r == nullptr) return nullptr;
  r->status = status;
  r->error_message = DupCStr(msg);
  return r;
}

}  // namespace

// Tear down the IAMF session with the ES-473 paused-seek-hook protocol:
// disarm the hook, drain the in-flight paused callback, then close.
// Required on every close_iamf() while the audio thread may be
// running — including playback_open's failure rollbacks, where
// open_iamf() has already re-armed the hook: paused callbacks keep
// firing during the teardown, and a hook already past the gate
// dereferences the session close_iamf() is about to reset.
static void ClosePlaybackWithHookBarrier() {
  PausedDrainDisarmScope drain_scope;
  g_graph.disarm_paused_seek_hook();
  g_audio_thread.wait_for_callback_quiescent();
  g_graph.close_iamf();
}

// Remove the IAMF session's elements from OAR. Must run before
// close_iamf(), which clears the chain ids this reads (ES-906).
static void RemovePlaybackElementsFromOar(OarRenderer& oar) {
  uint32_t ids[kEclipsaStudioMaxElements] = {};
  const uint32_t n = g_graph.iamf_element_ids(ids, kEclipsaStudioMaxElements);
  for (uint32_t i = 0; i < n; ++i) oar.remove_element(ids[i]);
  g_graph.resync_loudness_meter_if_stale();
}

EclipsaStudioPlaybackOpenResult* eclipsa_studio_playback_open(
    const char* path) {
  if (!g_initialized) {
    return PlaybackErrorResult(-1, "invalid_argument: engine not initialized");
  }
  if (path == nullptr || *path == '\0') {
    return PlaybackErrorResult(-1, "invalid_argument: empty path");
  }

  using clock = std::chrono::steady_clock;
  const auto t0 = clock::now();
  // Mirror the close-side barrier: if a previous session is still
  // attached, `open_iamf` will tear it down internally. Pause the
  // audio thread, disarm the paused seek hook (the paused callback
  // keeps firing during the swap and the hook dereferences the
  // session — ES-473), then wait for the in-flight callback to return
  // before any `unique_ptr` swap happens on the graph.
  g_audio_thread.wait_fade_stop_parked();  // Let a user stop land first.
  PausedDrainDisarmScope drain_scope;
  g_audio_thread.set_playing(false);
  g_graph.disarm_paused_seek_hook();
  g_audio_thread.wait_for_callback_quiescent();
  // open_iamf closes an attached session before it opens `path`, and
  // close_iamf clears the chain ids. Remove that session's elements from
  // OAR here, in the state playback_close removes them in, so neither a
  // failed open nor a file with other element ids leaves them registered
  // (ES-906).
  if (auto* oar = g_graph.oar_renderer(); oar != nullptr) {
    RemovePlaybackElementsFromOar(*oar);
  }
  const int32_t claimed = g_graph.open_iamf(path);
  const auto t_graph = clock::now();
  if (claimed < 0) {
    const std::string msg = g_graph.last_iamf_error().empty()
                                ? std::string("io: open_iamf failed")
                                : g_graph.last_iamf_error();
    return PlaybackErrorResult(claimed, msg);
  }

  // Rate-mismatched files are handled by per-chain resamplers created
  // in open_iamf (file rate -> engine rate); the session timeline stays
  // in file frames and graph.seek converts. The result still reports
  // the FILE's sample_rate/total_frames — the Dart side derives its
  // engine-rate timeline from them.

  // Register each claimed AE with OAR so the render path (feed +
  // render in AudioGraph::process) has something to produce.
  //
  // open_iamf has already gated on upstream's decode `supported` flag
  // (whole-file: pumping refuses files with any undecodable AE), so
  // registration only narrows further where OAR itself has no element
  // sub-renderer for the shape.
  auto* oar = g_graph.oar_renderer();
  auto* session = g_graph.iamf_session();
  if (oar == nullptr || session == nullptr) {
    ClosePlaybackWithHookBarrier();
    return PlaybackErrorResult(-4, "internal: renderer unavailable");
  }

  const uint32_t num_ae = session->num_audio_elements();
  auto* ae_array = static_cast<EclipsaStudioPlaybackAe*>(
      std::calloc(num_ae, sizeof(EclipsaStudioPlaybackAe)));
  if (ae_array == nullptr && num_ae > 0) {
    ClosePlaybackWithHookBarrier();
    return PlaybackErrorResult(-5, "io: out of memory");
  }

  // Bind each AE to an OAR sub-renderer through the single capability
  // mapping (renderer/oar_capability.h, issue ES-330): channel AEs key on
  // the raw coded layout pair, scene AEs on the ambisonics order.
  // Object AEs and reserved layouts get no mapping and skip
  // registration; the empty graph slot just produces zeros.
  for (uint32_t ae = 0; ae < num_ae; ++ae) {
    const auto info = session->ae_info(ae);
    // Mirror AudioGraph::open_iamf's chain-id fallback: an AE whose
    // audio_element_id is 0 claims chain id ae+1. Report and register
    // THAT id — the raw 0 would make every per-element FFI call (mix
    // gain, exclusion) and OAR metadata update miss the chain.
    ae_array[ae].audio_element_id =
        info.audio_element_id != 0 ? info.audio_element_id : ae + 1;
    ae_array[ae].kind = info.kind;
    ae_array[ae].num_channels = info.num_channels;
    ae_array[ae].layout_info = info.layout_info;

    const std::optional<int> oar_sub_type =
        OarSubTypeForElement(info.kind, info.loudspeaker_layout_raw,
                             info.expanded_loudspeaker_layout_raw,
                             info.kind == 1 ? info.layout_info : -1);
    const bool ae_supported_for_render =
        info.supported && oar_sub_type.has_value();

    if (!ae_supported_for_render) {
      char msg[160];
      std::snprintf(msg, sizeof(msg),
                    "playback_open: skipping OAR registration for "
                    "unsupported AE id=%u kind=%d layout_info=%d",
                    info.audio_element_id, info.kind, info.layout_info);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine", msg);
      continue;
    }
    if (!oar->add_element(ae_array[ae].audio_element_id, info.kind,
                          *oar_sub_type, info.num_channels)) {
      char msg[160];
      std::snprintf(msg, sizeof(msg),
                    "playback_open: oar->add_element failed for AE id=%u "
                    "kind=%d sub_type=%d ch=%u",
                    info.audio_element_id, info.kind, *oar_sub_type,
                    info.num_channels);
      engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine", msg);
    }
  }
  if (!oar->commit_rendering_config()) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "engine",
               "playback_open: oar->commit_rendering_config failed; "
               "rolling back");
    std::free(ae_array);
    RemovePlaybackElementsFromOar(*oar);
    ClosePlaybackWithHookBarrier();
    auto* err = AllocPlaybackResult();
    if (err == nullptr) return nullptr;
    err->status = -7;
    err->error_message = DupCStr("oar->commit_rendering_config failed");
    return err;
  }
  g_graph.resync_loudness_meter_if_stale();

  auto* r = AllocPlaybackResult();
  if (r == nullptr) {
    std::free(ae_array);
    RemovePlaybackElementsFromOar(*oar);
    ClosePlaybackWithHookBarrier();
    return nullptr;
  }
  r->status = 0;
  r->error_message = nullptr;
  r->sample_rate = session->sample_rate();
  r->total_frames = session->total_frames();
  r->num_audio_elements = num_ae;
  r->audio_elements = ae_array;

  {
    using ms = std::chrono::duration<double, std::milli>;
    const double d_graph = ms(t_graph - t0).count();
    const double d_oar = ms(clock::now() - t_graph).count();
    const double d_total = ms(clock::now() - t0).count();
    char buf[224];
    snprintf(buf, sizeof(buf),
             "playback_open: path=\"%s\" claimed=%d ae=%u rate=%u frames=%llu "
             "in %.1f ms (open_iamf=%.1f, oar_setup=%.1f)",
             path, claimed, num_ae, r->sample_rate,
             static_cast<unsigned long long>(r->total_frames), d_total, d_graph,
             d_oar);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  }

  return r;
}

void eclipsa_studio_playback_open_result_free(
    EclipsaStudioPlaybackOpenResult* result) {
  if (result == nullptr) return;
  std::free(const_cast<char*>(result->error_message));
  std::free(const_cast<EclipsaStudioPlaybackAe*>(result->audio_elements));
  std::free(result);
}

void eclipsa_studio_playback_use_stream_gains(uint8_t enabled) {
  if (!g_initialized) return;
  g_graph.set_iamf_stream_gains(enabled != 0);
  char buf[64];
  snprintf(buf, sizeof(buf), "playback_use_stream_gains(%u)", enabled);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
}

void eclipsa_studio_playback_close(void) {
  if (!g_initialized) return;

  // Pause the audio thread and wait for any in-flight callback to
  // return before tearing down the IAMF session. Without this barrier
  // the audio callback can be inside `AudioGraph::process()` (reading
  // `iamf_session_` / `chain.iamf_ring_source`) while `close_iamf()`
  // resets those `unique_ptr`s on the control thread, which is a
  // use-after-free under TSan. The paused seek hook must be disarmed
  // BEFORE the quiescence wait — paused callbacks keep firing during
  // the teardown and the hook dereferences the session (ES-473).
  g_audio_thread.wait_fade_stop_parked();  // Let a user stop land first.
  PausedDrainDisarmScope drain_scope;
  g_audio_thread.set_playing(false);
  g_graph.disarm_paused_seek_hook();
  if (!g_audio_thread.wait_for_callback_quiescent()) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine",
               "playback_close: audio callback did not quiesce in time; "
               "proceeding anyway");
  }

  // Unregister from OAR before AudioGraph resets the chain state.
  auto* oar = g_graph.oar_renderer();
  if (oar != nullptr) RemovePlaybackElementsFromOar(*oar);

  g_graph.close_iamf();

  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", "playback_close");
}

EclipsaStudioPlaybackStatus eclipsa_studio_playback_status(void) {
  EclipsaStudioPlaybackStatus status = {};
  if (!g_initialized) return status;
  auto* session = g_graph.iamf_session();
  if (session == nullptr || !session->is_open()) return status;

  status.session_open = 1;
  status.scan_complete = session->is_scan_complete() ? 1 : 0;
  status.total_samples_ready = session->is_total_samples_ready() ? 1 : 0;
  // refresh_total_frames updates the cached value once the scan
  // publishes a real total; before that it returns the existing 0.
  status.total_frames = session->refresh_total_frames();
  return status;
}

// ── Audio device ──────────────────────────────────────────────────────────

uint32_t eclipsa_studio_device_count(void) { return g_device.device_count(); }

const char* eclipsa_studio_device_name(uint32_t index) {
  // Caller owns the copy and releases it with eclipsa_studio_string_free().
  // Returning name.c_str() would aim into g_device's storage, which a
  // re-enumeration (refresh, reconfigure, hot-plug) can reallocate
  // before the caller finishes copying.
  const std::string& name = g_device.device_name(index);
  return name.empty() ? nullptr : DupCStr(name);
}

void eclipsa_studio_device_select(uint32_t index) {
  g_device.select_device(index);
}

uint32_t eclipsa_studio_device_channel_count(void) {
  return g_device.channel_count();
}

const char* eclipsa_studio_device_channel_name(uint32_t channel) {
  // Caller owns the copy and releases it with eclipsa_studio_string_free().
  return DupCStr(g_device.output_channel_name(channel));
}

void eclipsa_studio_string_free(const char* s) {
  std::free(const_cast<char*>(s));
}

uint32_t eclipsa_studio_devices_refresh(void) {
  if (!g_device.refresh()) {
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "device",
               "Device re-enumeration failed");
  }
  return g_device.device_count();
}

// ── Audio device (extended) ───────────────────────────────────────────────

uint32_t eclipsa_studio_device_supported_sample_rate_count(
    uint32_t device_index) {
  if (device_index >= g_device.device_count()) return 0;
  return static_cast<uint32_t>(
      g_device.device_list()[device_index].supported_sample_rates.size());
}

uint32_t eclipsa_studio_device_supported_sample_rate(uint32_t device_index,
                                                     uint32_t rate_index) {
  if (device_index >= g_device.device_count()) return 0;
  const auto& rates =
      g_device.device_list()[device_index].supported_sample_rates;
  if (rate_index >= static_cast<uint32_t>(rates.size())) return 0;
  return rates[rate_index];
}

uint32_t eclipsa_studio_device_supported_channel_count_count(
    uint32_t device_index) {
  if (device_index >= g_device.device_count()) return 0;
  return static_cast<uint32_t>(
      g_device.device_list()[device_index].supported_channel_counts.size());
}

uint32_t eclipsa_studio_device_supported_channel_count(uint32_t device_index,
                                                       uint32_t ch_index) {
  if (device_index >= g_device.device_count()) return 0;
  const auto& chs =
      g_device.device_list()[device_index].supported_channel_counts;
  if (ch_index >= static_cast<uint32_t>(chs.size())) return 0;
  return chs[ch_index];
}

uint32_t eclipsa_studio_device_max_channels(uint32_t device_index) {
  if (device_index >= g_device.device_count()) return 2;
  return g_device.device_list()[device_index].channel_count;
}

uint8_t eclipsa_studio_device_is_default(uint32_t device_index) {
  if (device_index >= g_device.device_count()) return 0;
  return g_device.device_list()[device_index].is_default ? 1 : 0;
}

uint32_t eclipsa_studio_current_sample_rate(void) {
  return g_device.current_sample_rate();
}

uint32_t eclipsa_studio_device_hardware_sample_rate(void) {
  if (!g_initialized) return 0;
  return g_device.query_hardware_sample_rate();
}

uint32_t eclipsa_studio_current_buffer_size(void) {
  return g_device.current_buffer_size();
}

uint32_t eclipsa_studio_current_device_index(void) {
  return g_device.selected_index();
}

uint32_t eclipsa_studio_oar_buffer_size(void) {
  const auto* oar = g_graph.oar_renderer();
  return oar ? oar->buffer_size() : 0;
}

const char* eclipsa_studio_last_device_error(void) {
  const std::string e = g_device.last_error();
  if (e.empty()) return nullptr;
  // Caller (Dart FFI) owns the returned buffer and releases it via
  // eclipsa_studio_string_free() — the engine.h contract for all returned
  // strings. NEVER package:ffi's malloc.free(): that maps to
  // CoTaskMemFree on Windows and corrupts the heap when handed
  // CRT-malloc'd memory (ES-353).  Returning a c_str() pointer into
  // the std::string member would be a use-after-free if another
  // thread mutates last_error_ between the read and Dart's
  // toDartString() copy.
  char* copy = static_cast<char*>(malloc(e.size() + 1));
  if (!copy) return nullptr;
  std::memcpy(copy, e.data(), e.size() + 1);
  return copy;
}

int32_t eclipsa_studio_engine_reconfigure(uint32_t device_index,
                                          uint32_t sample_rate,
                                          uint32_t buffer_size) {
  if (!g_initialized) return -1;

  // Fade the output before stopping the stream — stop() mid-program
  // is a hard discontinuity (issue ES-73). Resolves in a few ms while
  // playing, via the paused-branch snap otherwise; skipped entirely
  // when no stream is running.
  auto* oar = g_graph.oar_renderer();
  if (oar != nullptr && g_audio_thread.is_running()) {
    oar->fade_out_and_wait();
  }

  // Stop the audio thread (stops the device stream).
  g_audio_thread.stop();

  // Validate and select the requested device.
  if (!g_device.select_device(device_index)) {
    // Invalid index — restart with previous settings.
    g_audio_thread.start(g_graph, g_device, g_sample_rate, g_buffer_size);
    if (oar != nullptr) oar->fade_in();
    return -2;
  }

  const uint32_t prev_rate = g_sample_rate;
  const uint32_t prev_buf = g_buffer_size;
  if (sample_rate > 0) g_sample_rate = sample_rate;
  if (buffer_size > 0) g_buffer_size = buffer_size;

  // Retarget the graph while the audio thread is stopped: per-element
  // resamplers, meter ballistics, mix-bus loudness. Without this the
  // thread drives at the new device rate while every chain still
  // produces frames for the old one (issue #8's pitch shift).
  //
  // The transport position is a frame count whose meaning changes with
  // the rate — rescale it so the playhead stays at the same wall-clock
  // time, and re-seek the graph so element cursors line up with it
  // (the seek also converts through the freshly retargeted resamplers).
  const bool rate_changed = g_sample_rate != prev_rate;
  const uint64_t prev_pos = g_audio_thread.position_frames();
  if (rate_changed) {
    g_graph.set_sample_rate(g_sample_rate);
    const uint64_t new_pos =
        (prev_pos * g_sample_rate + prev_rate / 2) / prev_rate;
    g_audio_thread.seek(new_pos);
    g_graph.seek(new_pos);
  }

  // Mark OAR as reconfiguring so the audio thread outputs silence
  // until we've reinitialised it for the (possibly different) rate and
  // buffer size.
  if (oar) oar->set_reconfiguring(true);

  if (!g_audio_thread.start(g_graph, g_device, g_sample_rate, g_buffer_size)) {
    if (oar) {
      oar->set_reconfiguring(false);
      oar->fade_in();
    }
    g_sample_rate = prev_rate;
    g_buffer_size = prev_buf;
    if (rate_changed) {
      g_graph.set_sample_rate(prev_rate);
      g_audio_thread.seek(prev_pos);
      g_graph.seek(prev_pos);
    }
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine",
               "Audio device failed to reopen after reconfigure");
    return -3;
  }

  // The hardware may have refused the requested rate — adopt its
  // actual rate (clock-slip starvation otherwise; issue ES-30).
  const uint32_t rate_after_adopt = AdoptHardwareSampleRate();

  // Reinitialise OAR to match the new rate and the actual device buffer
  // size. OAR latches both at create time, so a rate change always
  // needs the rebuild, and so does any change of the effective buffer
  // size. Compare against OAR's own configured size — g_buffer_size was
  // already overwritten with the request above, so comparing against it
  // missed every granted buffer-size change: OAR kept its old block
  // size and the output went silent when the buffer grew (render()
  // refuses blocks larger than its pre-allocated output).
  const uint32_t actual_buf = g_device.current_buffer_size();
  if (oar && (rate_changed || rate_after_adopt != prev_rate ||
              actual_buf != oar->buffer_size())) {
    oar->reinit_for_format(g_sample_rate, actual_buf);
    g_graph.resync_loudness_meter_if_stale();
  }
  if (oar) {
    // Arm the gentle ramp BEFORE clearing the reconfiguring flag: the
    // output device may just have changed (ES-467), and program audio
    // snapping on at full scale on new hardware reads as a hard cut.
    // On the reinit path rebuild() has already cleared the flag and
    // armed the short default fade — rendering may resume the moment
    // it does, and one large block covers the whole 5 ms ramp, so a
    // fade_in placed after set_reconfiguring(false) here could find
    // the gain already at unity and be a no-op. Arming first makes
    // the 100 ms ramp the live target by the time rendering resumes
    // on the no-reinit path, and shortens the losing window to the
    // reinit-path race above (rare; degrades to the fast fade).
    oar->fade_in(OarRenderer::kReopenFadeSeconds);
    oar->set_reconfiguring(false);
  }
  g_buffer_size = actual_buf;

  char buf[128];
  snprintf(buf, sizeof(buf), "Engine reconfigured: device=%u, %u Hz, %u frames",
           device_index, g_sample_rate, g_buffer_size);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  return 0;
}

// ── Meters ────────────────────────────────────────────────────────────────

const EclipsaStudioMeterState* eclipsa_studio_get_meter_state(void) {
  return g_graph.meter_state();
}

// Shared body of the two meter-reset exports. reset_meters() writes
// the peak/RMS meter internals and the shared per-element meter slots
// that the audio thread's process() writes concurrently during
// playback — the ES-145 fix fenced only the loudness analyzer. Mirror
// the eclipsa_studio_element_remove barrier: pause, wait for the in-flight
// callback to return, reset, then restore the transport state. On the
// pause-path callers the pause/restore is a no-op; the save/restore
// covers the rest, and the quiescence wait is what closes the race
// with a callback that was already inside process() when the pause
// landed.
static void reset_meters_quiesced(bool preserve_clips, const char* what) {
  // The app's stop path calls this immediately after
  // eclipsa_studio_transport_pause() — give the 10 ms fade-stop its time to
  // land click-free before imposing the instant barrier pause (ES-530).
  g_audio_thread.wait_fade_stop_parked();
  const bool was_playing = g_audio_thread.is_logically_playing();
  g_audio_thread.set_playing(false);
  if (!g_audio_thread.wait_for_callback_quiescent() &&
      g_audio_thread.is_running()) {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "%s: audio callback did not quiesce in time; proceeding", what);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "meters", buf);
  }
  g_graph.reset_meters(preserve_clips);
  g_audio_thread.set_playing(was_playing);
}

void eclipsa_studio_meter_reset(void) {
  reset_meters_quiesced(/*preserve_clips=*/false, "meter_reset");
}

void eclipsa_studio_meter_reset_levels(void) {
  // Only the sticky clip latches survive the reset (ES-528).
  reset_meters_quiesced(/*preserve_clips=*/true, "meter_reset_levels");
}

uint64_t eclipsa_studio_get_frame_counter(void) {
  EclipsaStudioMeterState* state = g_graph.meter_state();
  return state ? static_cast<uint64_t>(state->frame_counter) : 0;
}

uint32_t eclipsa_studio_get_output_peaks(float* out_peaks,
                                         uint32_t max_channels) {
  if (!out_peaks) return 0;
  return g_graph.get_output_peaks(out_peaks, max_channels);
}

uint32_t eclipsa_studio_get_output_rms(float* out_rms, uint32_t max_channels) {
  if (!out_rms) return 0;
  return g_graph.get_output_rms(out_rms, max_channels);
}

uint32_t eclipsa_studio_get_output_clips(uint8_t* out_clips,
                                         uint32_t max_channels) {
  if (!out_clips) return 0;
  return g_graph.get_output_clips(out_clips, max_channels);
}

void eclipsa_studio_set_channel_stats_enabled(uint8_t enabled) {
  g_graph.set_channel_stats_enabled(enabled != 0);
}

void eclipsa_studio_meter_reset_clips(void) {
  // Safe to call at any time. While playing, the clear is handed to
  // the audio thread — it is the sole writer of the clip flags and
  // zeroes them itself at the top of its next process() (≤ one block,
  // ~10 ms), so there is no cross-thread write-write race. While
  // paused, clear directly after waiting out any in-flight callback
  // (same barrier as eclipsa_studio_meter_reset).
  if (g_audio_thread.is_playing()) {
    g_graph.request_clip_clear();
    return;
  }
  g_audio_thread.wait_for_callback_quiescent();
  g_graph.clear_clips_now();
}

// ── Monitoring / OAR ─────────────────────────────────────────────────────

int32_t eclipsa_studio_monitoring_set_layout(uint32_t layout) {
  char buf[64];
  snprintf(buf, sizeof(buf), "set_layout(%u)", layout);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  // Rebuilds OAR, unless it already renders this layout, and
  // reconfigures the mix-bus loudness meter (channel count and BS.1770
  // weights) inside one loudness fence; see
  // AudioGraph::set_monitoring_layout().
  return g_graph.set_monitoring_layout(layout) ? 0 : -1;
}

uint32_t eclipsa_studio_monitoring_get_channels(void) {
  auto* oar = g_graph.oar_renderer();
  return oar ? oar->channel_count() : 0;
}

int32_t eclipsa_studio_monitoring_set_routing(const uint64_t* masks,
                                              uint32_t len) {
  const int32_t rc = g_graph.set_routing(masks, len);
  if (rc == 0) {
    char buf[64];
    snprintf(buf, sizeof(buf), "set_routing(len=%u)", len);
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  }
  return rc;
}

int32_t eclipsa_studio_monitoring_set_layout_and_routing(uint32_t layout,
                                                         const uint64_t* masks,
                                                         uint32_t len) {
  char buf[80];
  snprintf(buf, sizeof(buf), "set_layout_and_routing(%u, len=%u)", layout, len);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  return g_graph.set_layout_and_routing(layout, masks, len);
}

int32_t eclipsa_studio_monitoring_set_noise(uint32_t mode, uint32_t channel,
                                            float dbfs) {
  // Validate before publishing: an out-of-range mode would still register as
  // "noise active" (muting the program) while scattering nothing, leaving the
  // output silently dead; a non-finite dbfs would make pow() produce a NaN
  // amplitude that propagates into the device buffer. Reject both. The channel
  // packs into a 24-bit field, so anything wider can't round-trip.
  if (mode > 2 || channel > 0xFFFFFFu || (mode != 0 && !std::isfinite(dbfs))) {
    char buf[80];
    snprintf(buf, sizeof(buf), "set_noise rejected: mode=%u, ch=%u, %.1f dBFS",
             mode, channel, dbfs);
    engine_log(ECLIPSA_STUDIO_LOG_WARN, "engine", buf);
    return -1;
  }
  // Off carries no level; otherwise convert the dBFS reference to a linear
  // amplitude. The audio thread applies this fixed gain, bypassing the master
  // fader, so the calibration level stays known.
  const float amp = mode == 0 ? 0.0f : std::pow(10.0f, dbfs / 20.0f);
  g_graph.set_noise(static_cast<uint8_t>(mode), channel, amp);
  char buf[80];
  snprintf(buf, sizeof(buf), "set_noise(mode=%u, ch=%u, %.1f dBFS)", mode,
           channel, dbfs);
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  return 0;
}

int32_t eclipsa_studio_set_bypass_oar(uint8_t enabled) {
  g_graph.set_bypass_oar(enabled != 0);
  char buf[64];
  snprintf(buf, sizeof(buf), "OAR bypass %s", enabled ? "ON" : "OFF");
  engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", buf);
  return 0;
}

void eclipsa_studio_engine_set_export_paused(uint8_t paused) {
  if (!g_initialized) return;
  auto* oar = g_graph.oar_renderer();
  if (!oar) return;
  if (paused) {
    // Serialized against layout switches / rebuilds by construction
    // (takes OarRenderer::control_mutex_); logs its own ack status.
    // Refcounted: overlapping passes (export dialog + loudness
    // report) nest, and the live OAR resumes only at the last exit —
    // OarRenderer logs which case each end call was.
    oar->begin_offline_exclusive();
  } else {
    // Through AudioGraph so a deferred layout switch replayed here also
    // resyncs the mix-bus loudness meter to the new channel count.
    g_graph.end_offline_exclusive();
    engine_log(ECLIPSA_STUDIO_LOG_INFO, "engine", "export pause: released");
  }
}

// ── IAMF export ──────────────────────────────────────────────────────────
// Delegates to eclipsa_studio::IamfExporter (the push-PCM path, ES-480). See
// engine/iamf/iamf_exporter.{h,cc}.

float eclipsa_studio_iamf_export_progress(void) {
  return g_iamf_exporter.Progress();
}

void eclipsa_studio_iamf_export_cancel(void) { g_iamf_exporter.Cancel(); }

// ── IAMF push export (ES-480) ──────────────────────────────────────────────
// begin/add/run build a pending request on the calling (control) thread,
// then run() drives IamfExporter::EncodePush under the busy guard;
// run() clears the pending state on every exit. The builder state is
// serialized by g_push_export_mutex (ES-504): the contract (engine.h)
// still asks for one builder sequence at a time, but a second thread
// interleaving its own calls now garbles a request at worst instead of
// racing on the strings/vector. The builder calls are control-plane
// only, so the lock is uncontended in correct use; run() drops it
// before the long encode.

namespace {
struct PushExportRequest {
  std::string config_textproto;
  std::string output_iamf_path;
  std::vector<eclipsa_studio::IamfExporter::PushElement> elements;
  bool pending = false;
};
PushExportRequest g_push_export_request;
std::mutex g_push_export_mutex;
}  // namespace

int32_t eclipsa_studio_iamf_push_export_begin(const char* config_textproto,
                                              const char* output_iamf_path) {
  if (config_textproto == nullptr || output_iamf_path == nullptr) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_begin: null argument");
    return -1;
  }
  std::lock_guard<std::mutex> lock(g_push_export_mutex);
  if (g_iamf_export_busy.load(std::memory_order_acquire)) {
    // Without this guard, the ResetForNewRequest() below would clear a
    // cancel the user already raised against the in-flight encode —
    // run() rejects concurrent entry with -4, so begin must too.
    engine_log(
        ECLIPSA_STUDIO_LOG_ERROR, "iamf",
        "eclipsa_studio_iamf_push_export_begin: another export is running");
    return -4;
  }
  try {
    g_push_export_request.config_textproto = config_textproto;
    g_push_export_request.output_iamf_path = output_iamf_path;
    g_push_export_request.elements.clear();
    g_push_export_request.pending = true;
    // Arm the request: zero progress (the dialog starts polling as soon
    // as it begins a request) and drop any cancel raised before begin —
    // while keeping one raised *after* begin armed so it aborts run()
    // even when it lands in the begin→run window (EncodePush does not
    // reset the cancel flag; see IamfExporter::ResetForNewRequest).
    g_iamf_exporter.ResetForNewRequest();
    return 0;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_begin: exception");
    g_push_export_request.pending = false;
    return -5;
  }
}

int32_t eclipsa_studio_iamf_push_export_add_element(
    const char* wav_basename, const char* source_wav_path, float gain_db,
    const int32_t* routing, int32_t routing_len, uint64_t pad_to_frames,
    uint32_t output_sample_rate) {
  // Taken before the argument checks: the bad-argument path below
  // writes `pending`.
  std::lock_guard<std::mutex> lock(g_push_export_mutex);
  if (wav_basename == nullptr || source_wav_path == nullptr ||
      routing_len < 0 || (routing_len > 0 && routing == nullptr)) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_add_element: bad argument");
    // A failed add dooms the whole request; drop it so the pending
    // state never outlives its builder sequence.
    g_push_export_request.pending = false;
    return -1;
  }
  if (!g_push_export_request.pending) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_add_element: no pending begin");
    return -1;
  }
  try {
    eclipsa_studio::IamfExporter::PushElement element;
    element.wav_basename = wav_basename;
    element.stream.input_wav_path = source_wav_path;
    element.stream.gain_db = gain_db;
    element.stream.routing.assign(routing, routing + routing_len);
    element.stream.pad_to_frames = pad_to_frames;
    element.stream.output_sample_rate = output_sample_rate;
    g_push_export_request.elements.push_back(std::move(element));
    return 0;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_add_element: exception");
    g_push_export_request.pending = false;
    return -5;
  }
}

int32_t eclipsa_studio_iamf_push_export_run(void) {
  std::unique_lock<std::mutex> lock(g_push_export_mutex);
  if (!g_push_export_request.pending) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_run: no pending request");
    return -1;
  }
  bool expected = false;
  if (!g_iamf_export_busy.compare_exchange_strong(expected, true)) {
    engine_log(
        ECLIPSA_STUDIO_LOG_ERROR, "iamf",
        "eclipsa_studio_iamf_push_export_run: another export is running");
    return -4;
  }
  BusyGuard guard(g_iamf_export_busy);
  // Move the request out so the pending state is cleared on every exit,
  // then drop the lock before the long encode: a rejected concurrent
  // begin must fail fast on the busy guard, not block behind the run.
  PushExportRequest request = std::move(g_push_export_request);
  g_push_export_request = PushExportRequest{};
  lock.unlock();
  // Exception firewall — see eclipsa_studio_iamf_export.
  try {
    return g_iamf_exporter.EncodePush(
        request.config_textproto, request.output_iamf_path, request.elements);
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_iamf_push_export_run: exception: %s", e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
    return -5;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_push_export_run: unknown exception");
    return -5;
  }
}

int32_t eclipsa_studio_iamf_push_export_element_clip_stats(
    uint32_t index, uint64_t* out_clipped_samples, float* out_peak_linear) {
  return g_iamf_exporter.GetElementClipStats(index, out_clipped_samples,
                                             out_peak_linear)
             ? 0
             : -1;
}

// ── IAMF + video → MP4 mux ───────────────────────────────────────────────
// Delegates to eclipsa_studio::IamfMuxer (libgpac in-process). See
// engine/iamf/iamf_muxer.{h,cc}.

int32_t eclipsa_studio_iamf_mux(const char* input_iamf, const char* input_video,
                                const char* output_mp4) {
  if (input_iamf == nullptr || input_video == nullptr ||
      output_mp4 == nullptr) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_mux: null argument");
    return -1;
  }
  bool expected = false;
  if (!g_iamf_mux_busy.compare_exchange_strong(expected, true)) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_mux: another mux is already running");
    return -4;
  }
  BusyGuard guard(g_iamf_mux_busy);
  try {
    return g_iamf_muxer.Mux(input_iamf, input_video, output_mp4);
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf), "eclipsa_studio_iamf_mux: exception: %s",
             e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
    return -5;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_iamf_mux: unknown exception");
    return -5;
  }
}

int32_t eclipsa_studio_video_container_probe(const char* input_video) {
  if (input_video == nullptr) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_video_container_probe: null argument");
    return -1;
  }
  // No busy flag: the probe only reads, and libgpac's system init is
  // serialized by eclipsa_studio::GpacSystem, so it may overlap a running mux.
  try {
    return g_iamf_muxer.ProbeVideo(input_video);
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_video_container_probe: exception: %s", e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf", buf);
    return -5;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf",
               "eclipsa_studio_video_container_probe: unknown exception");
    return -5;
  }
}

// ── Volume free space ───────────────────────────────────────────────────

int32_t eclipsa_studio_fs_volume_info(const char* path,
                                      uint64_t* out_free_bytes,
                                      uint64_t* out_volume_id) {
  if (path == nullptr || out_free_bytes == nullptr ||
      out_volume_id == nullptr) {
    return -1;
  }
  return eclipsa_studio::VolumeInfo(path, out_free_bytes, out_volume_id) ? 0
                                                                         : -2;
}

// ── Still image → video-only MP4 (ES-192) ─────────────────────────────────
// Delegates to eclipsa_studio::StillVideoEncode (OS encoder). See
// engine/video/still_video_encoder.h for the contract.

int32_t eclipsa_studio_still_video_encode(const uint8_t* rgba,
                                          uint64_t rgba_size, uint32_t width,
                                          uint32_t height, uint32_t fps,
                                          double duration_seconds,
                                          const char* output_mp4) {
  try {
    return eclipsa_studio::StillVideoEncode(rgba, rgba_size, width, height, fps,
                                            duration_seconds, output_mp4);
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_still_video_encode: exception: %s", e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "video", buf);
    return -5;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "video",
               "eclipsa_studio_still_video_encode: unknown exception");
    return -5;
  }
}

// ── Offline mix renderer ─────────────────────────────────────────────────

struct eclipsa_studio_mix_renderer {
  eclipsa_studio::OfflineMixRenderer renderer;
};

eclipsa_studio_mix_renderer_t* eclipsa_studio_mix_renderer_create(
    uint32_t sample_rate, uint32_t buffer_size, uint32_t layout) {
  auto* r = new (std::nothrow) eclipsa_studio_mix_renderer;
  if (!r) return nullptr;
  if (!r->renderer.Init(sample_rate, buffer_size, layout)) {
    delete r;
    return nullptr;
  }
  return r;
}

int32_t eclipsa_studio_mix_renderer_add_element(
    eclipsa_studio_mix_renderer_t* r, const char* source_wav_path,
    uint32_t element_id, int32_t element_type, int32_t element_sub_type,
    uint32_t channels, float mix_gain_db, uint32_t headphones_mode,
    uint32_t binaural_profile, float gain_db, const int32_t* routing,
    int32_t routing_len, uint64_t pad_to_frames, uint32_t output_sample_rate) {
  if (!r || !source_wav_path) return -1;
  eclipsa_studio::MixElementConfig cfg;
  cfg.element_id = element_id;
  cfg.stream.input_wav_path = source_wav_path;
  cfg.stream.gain_db = gain_db;
  cfg.stream.pad_to_frames = pad_to_frames;
  cfg.stream.output_sample_rate = output_sample_rate;
  if (routing != nullptr && routing_len > 0) {
    cfg.stream.routing.assign(routing, routing + routing_len);
  }
  cfg.element_type = element_type;
  cfg.element_sub_type = element_sub_type;
  cfg.channels = channels;
  cfg.mix_gain_db = mix_gain_db;
  cfg.headphones_mode = headphones_mode;
  cfg.binaural_profile = binaural_profile;
  return r->renderer.AddElement(cfg) ? 0 : -1;
}

void eclipsa_studio_mix_renderer_set_object_position(
    eclipsa_studio_mix_renderer_t* r, uint32_t element_id, uint32_t num_objects,
    float azimuth_deg, float elevation_deg, float distance, float azimuth2_deg,
    float elevation2_deg, float distance2) {
  if (!r) return;
  const float az[2] = {azimuth_deg, azimuth2_deg};
  const float el[2] = {elevation_deg, elevation2_deg};
  const float dist[2] = {distance, distance2};
  r->renderer.SetObjectPosition(element_id, num_objects, az, el, dist);
}

void eclipsa_studio_mix_renderer_set_element_channel_order(
    eclipsa_studio_mix_renderer_t* r, uint32_t element_id, uint32_t order) {
  if (r) r->renderer.SetElementChannelOrder(element_id, order);
}

void eclipsa_studio_mix_renderer_set_output_gain(
    eclipsa_studio_mix_renderer_t* r, float gain_db) {
  if (r) r->renderer.SetOutputMixGain(gain_db);
}

int32_t eclipsa_studio_mix_renderer_measure(eclipsa_studio_mix_renderer_t* r,
                                            float* out_integrated_lufs,
                                            float* out_true_peak_dbtp,
                                            float* out_digital_peak_dbfs) {
  if (!r) return -1;
  // Exception firewall.
  try {
    const auto result = r->renderer.RenderAndMeasure();
    if (!result.has_value()) {
      // Specifics already in the engine log. Distinct code so a failed
      // measure can never pass for a silent (-120 LUFS) program.
      return -2;
    }
    if (out_integrated_lufs) *out_integrated_lufs = result->integrated_lufs;
    if (out_true_peak_dbtp) *out_true_peak_dbtp = result->true_peak_dbtp;
    if (out_digital_peak_dbfs) {
      *out_digital_peak_dbfs = result->digital_peak_dbfs;
    }
    return 0;
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_mix_renderer_measure: exception: %s", e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer", buf);
    return -5;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "mix_renderer",
               "eclipsa_studio_mix_renderer_measure: unknown exception");
    return -5;
  }
}

uint32_t eclipsa_studio_mix_renderer_trace_len(eclipsa_studio_mix_renderer_t* r,
                                               uint32_t series) {
  return r ? r->renderer.TraceLength(series) : 0;
}

uint32_t eclipsa_studio_mix_renderer_copy_trace(
    eclipsa_studio_mix_renderer_t* r, uint32_t series, float* out,
    uint32_t cap) {
  return r ? r->renderer.CopyTrace(series, out, cap) : 0;
}

int32_t eclipsa_studio_mix_renderer_loudness_range(
    eclipsa_studio_mix_renderer_t* r, float* out_lra_lu,
    int32_t* out_is_stable) {
  if (!r) return -1;
  float lra = 0.0f;
  bool stable = false;
  if (!r->renderer.GetLoudnessRange(&lra, &stable)) return -1;
  if (out_lra_lu) *out_lra_lu = lra;
  if (out_is_stable) *out_is_stable = stable ? 1 : 0;
  return 0;
}

int32_t eclipsa_studio_mix_renderer_element_clip_stats(
    eclipsa_studio_mix_renderer_t* r, uint32_t element_id,
    uint64_t* out_clipped, float* out_peak_linear) {
  if (!r) return -1;
  return r->renderer.GetElementClipStats(element_id, out_clipped,
                                         out_peak_linear)
             ? 0
             : -1;
}

void eclipsa_studio_mix_renderer_destroy(eclipsa_studio_mix_renderer_t* r) {
  delete r;
}

// ── Offline IAMF measurer ────────────────────────────────────────────────

struct eclipsa_studio_iamf_measurer {
  eclipsa_studio::OfflineIamfMeasurer measurer;
};

eclipsa_studio_iamf_measurer_t* eclipsa_studio_iamf_measurer_create(
    const char* path, uint32_t buffer_size, uint32_t layout) {
  if (!path) return nullptr;
  auto* m = new (std::nothrow) eclipsa_studio_iamf_measurer;
  if (!m) return nullptr;
  // Exception firewall: the open runs the upstream decoder's descriptor
  // parse and scan.
  try {
    if (!m->measurer.Open(path, buffer_size, layout)) {
      delete m;
      return nullptr;
    }
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_iamf_measurer_create: exception: %s", e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf_measure", buf);
    delete m;
    return nullptr;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf_measure",
               "eclipsa_studio_iamf_measurer_create: unknown exception");
    delete m;
    return nullptr;
  }
  return m;
}

int32_t eclipsa_studio_iamf_measurer_include_element(
    eclipsa_studio_iamf_measurer_t* m, uint32_t audio_element_id,
    float mix_gain_db, uint32_t headphones_mode, uint32_t binaural_profile) {
  if (!m) return -1;
  // Exception firewall: including an element adds an OAR sub-renderer
  // and allocates its block buffer. A throw reports -2 with the reason
  // in the engine log, the code engine.h documents for an element that
  // cannot render.
  try {
    return m->measurer.IncludeElement(audio_element_id, mix_gain_db,
                                      headphones_mode, binaural_profile)
               ? 0
               : -2;
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_iamf_measurer_include_element: exception: %s",
             e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf_measure", buf);
    return -2;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf_measure",
               "eclipsa_studio_iamf_measurer_include_element: unknown "
               "exception");
    return -2;
  }
}

void eclipsa_studio_iamf_measurer_set_output_gain(
    eclipsa_studio_iamf_measurer_t* m, float gain_db) {
  if (m) m->measurer.SetOutputMixGain(gain_db);
}

int32_t eclipsa_studio_iamf_measurer_measure(eclipsa_studio_iamf_measurer_t* m,
                                             float* out_integrated_lufs,
                                             float* out_true_peak_dbtp,
                                             float* out_digital_peak_dbfs) {
  if (!m) return -1;
  // Exception firewall.
  try {
    const auto result = m->measurer.Measure();
    if (!result.has_value()) {
      // Specifics in the engine log and last_error. Distinct code so a
      // failed measure can never pass for a silent (-120 LUFS) program.
      return -2;
    }
    if (out_integrated_lufs) *out_integrated_lufs = result->integrated_lufs;
    if (out_true_peak_dbtp) *out_true_peak_dbtp = result->true_peak_dbtp;
    if (out_digital_peak_dbfs) {
      *out_digital_peak_dbfs = result->digital_peak_dbfs;
    }
    return 0;
  } catch (const std::exception& e) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "eclipsa_studio_iamf_measurer_measure: exception: %s", e.what());
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf_measure", buf);
    return -5;
  } catch (...) {
    engine_log(ECLIPSA_STUDIO_LOG_ERROR, "iamf_measure",
               "eclipsa_studio_iamf_measurer_measure: unknown exception");
    return -5;
  }
}

uint32_t eclipsa_studio_iamf_measurer_trace_len(
    eclipsa_studio_iamf_measurer_t* m, uint32_t series) {
  return m ? m->measurer.TraceLength(series) : 0;
}

uint32_t eclipsa_studio_iamf_measurer_copy_trace(
    eclipsa_studio_iamf_measurer_t* m, uint32_t series, float* out,
    uint32_t cap) {
  return m ? m->measurer.CopyTrace(series, out, cap) : 0;
}

int32_t eclipsa_studio_iamf_measurer_loudness_range(
    eclipsa_studio_iamf_measurer_t* m, float* out_lra_lu,
    int32_t* out_is_stable) {
  if (!m) return -1;
  float lra = 0.0f;
  bool stable = false;
  if (!m->measurer.GetLoudnessRange(&lra, &stable)) return -1;
  if (out_lra_lu) *out_lra_lu = lra;
  if (out_is_stable) *out_is_stable = stable ? 1 : 0;
  return 0;
}

const char* eclipsa_studio_iamf_measurer_last_error(
    eclipsa_studio_iamf_measurer_t* m) {
  return m ? m->measurer.last_error().c_str() : "";
}

void eclipsa_studio_iamf_measurer_destroy(eclipsa_studio_iamf_measurer_t* m) {
  delete m;
}

// ── Info ──────────────────────────────────────────────────────────────────
// Note: eclipsa_studio_peaks_* functions are implemented in
// waveform/peak_compute.cpp.

const char* eclipsa_studio_version(void) {
  return "Eclipsa Studio Engine " ECLIPSA_STUDIO_ENGINE_VERSION;
}

int32_t eclipsa_studio_api_version(void) {
  return ECLIPSA_STUDIO_ENGINE_API_VERSION;
}

}  // extern "C"
