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

#include "audio_thread.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "engine_log.h"
#include "graph/audio_graph.h"
#include "io/device_manager.h"
#include "renderer/oar_renderer.h"
#include "transport_fade.h"

// Flush denormals to zero on the audio thread. Long feedback decays
// (meter EMAs, biquad state) settle into the subnormal range during
// silence, and subnormal arithmetic is 10-100x slower on x86-64 —
// enough to spike the callback cost and cause dropouts. FZ/DAZ are
// per-thread FPU control bits, so set them at every callback entry:
// the device backend may recreate or migrate its thread, and the
// register write costs nanoseconds against a multi-hundred-µs block.
#if defined(__SSE2__) || defined(_M_X64) || \
    (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <immintrin.h>
static void flush_denormals_to_zero() {
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
}
#elif defined(_MSC_VER) && defined(_M_ARM64)
#include <intrin.h>
static void flush_denormals_to_zero() {
  const __int64 fpcr = _ReadStatusReg(ARM64_FPCR);
  _WriteStatusReg(ARM64_FPCR, fpcr | (1ll << 24));  // FZ bit
}
#elif defined(__aarch64__)
static void flush_denormals_to_zero() {
  uint64_t fpcr;
  asm volatile("mrs %0, fpcr" : "=r"(fpcr));
  asm volatile("msr fpcr, %0" ::"r"(fpcr | (1ull << 24)));  // FZ bit
}
#else
static void flush_denormals_to_zero() {}
#endif

AudioThread::AudioThread() = default;
AudioThread::~AudioThread() { stop(); }

bool AudioThread::start(AudioGraph& graph, DeviceManager& device,
                        uint32_t sample_rate, uint32_t buffer_frames) {
  graph_ = &graph;
  device_ = &device;
  sample_rate_ = sample_rate;
  // Transport edge fade steps at the device rate (ES-530) — wall-clock
  // durations, so the fade shape is rate/buffer-size invariant.
  fade_in_step_ = transport_fade_step(kTransportFadeInMs, sample_rate);
  fade_out_step_ = transport_fade_step(kTransportFadeOutMs, sample_rate);
  // The downtime between stop() and start() must not read as a stall.
  dropout_detector_.reset();

  // _rt so the line also reaches stderr directly: test binaries never
  // register the Dart log callback, and the mute must be discoverable
  // in exactly those runs.
  mute_output_ = std::getenv("ECLIPSA_STUDIO_MUTE_OUTPUT") != nullptr;
  if (mute_output_) {
    engine_log_rt(ECLIPSA_STUDIO_LOG_INFO, "audio",
                  "ECLIPSA_STUDIO_MUTE_OUTPUT set — device output muted");
  }

  const bool ok = device.start(sample_rate, buffer_frames,
                               AudioThread::data_callback, this);
  is_running_.store(ok);
  // Let the graph's loudness reconfigure fence know callbacks are firing
  // (issue ES-145); on failure it stays/clears to not-running.
  graph.set_audio_running(ok);
  return ok;
}

void AudioThread::stop() {
  is_running_.store(false);
  if (graph_) graph_->set_audio_running(false);
  if (device_) {
    device_->stop();
    device_ = nullptr;
    graph_ = nullptr;
  }
  // A fade left pending here can never be consumed (no callbacks will
  // fire): later wait_fade_stop_parked() calls would burn their full
  // timeout and a restart would resume into the stale fade. Park it —
  // the pending bit means the user stopped, so parking honors that
  // intent. A plain playing state is deliberately preserved: the
  // device-reconfigure path stop()/start()s mid-playback and relies
  // on it surviving. device_->stop() has joined the callback, so this
  // plain store cannot race the park CAS.
  const uint64_t w = transport_word_.load(std::memory_order_relaxed);
  if ((w & kTransportFadePendingBit) != 0) {
    transport_word_.store(transport_next(w, 0), std::memory_order_release);
  }
}

void AudioThread::wait_fade_stop_parked(uint32_t timeout_ms) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  // Wait while a fade is still ramping: playing with the pending bit
  // set. The park clears both bits in one store (the word is a single
  // atomic), so observing pending==false here means the park — or a
  // superseding play/pause transition — is fully visible; there is no
  // window where the pending bit is gone but the park is not (ES-547).
  while (true) {
    const uint64_t w = transport_word_.load(std::memory_order_acquire);
    const bool fading =
        (w & kTransportPlayingBit) != 0 && (w & kTransportFadePendingBit) != 0;
    if (!fading) return;
    if (std::chrono::steady_clock::now() >= deadline) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

bool AudioThread::wait_for_callback_quiescent(uint32_t timeout_ms) {
  if (!is_running_.load(std::memory_order_acquire)) return false;
  // Wait for two callback boundaries to elapse: one to ensure the
  // current in-flight callback has returned, and one more so any
  // callback that entered before observing `playing_=false` has had
  // a chance to exit. Polling at sub-millisecond granularity is fine
  // because this runs on the control thread during teardown only.
  const uint64_t target =
      published_callback_count_.load(std::memory_order_acquire) + 2;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (published_callback_count_.load(std::memory_order_acquire) < target) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::microseconds(500));
  }
  return true;
}

/// Smoothing coefficient for CPU load EMA.
/// Time constant ~= buffer_period / alpha (e.g., ~210 ms at 48 kHz / 512).
static constexpr float kCpuLoadAlpha = 0.05f;

void AudioThread::data_callback(void* output, uint32_t frames,
                                uint32_t channels, void* user_data) {
  flush_denormals_to_zero();
  auto* self = reinterpret_cast<AudioThread*>(user_data);
  if (!self || !self->graph_) {
    // Silence the output.
    if (output) {
      std::memset(output, 0,
                  static_cast<size_t>(frames) * channels * sizeof(float));
    }
    return;
  }

  EclipsaStudioMeterState* state = self->graph_->meter_state();
  self->callback_count_++;
  // Publish the callback count so Dart can see the first-callback
  // transition (used to log the open params) and compute deltas for
  // the dropout/overrun counters below.
  state->audio_callback_count = self->callback_count_;
  // Mirror to the atomic so control-thread teardown barriers
  // (`wait_for_callback_quiescent`) observe the same count.
  self->published_callback_count_.store(self->callback_count_,
                                        std::memory_order_release);

  if (!self->is_playing()) {
    // Paused — no program audio. Still inject pink-noise calibration if a
    // cell is lit, so speaker calibration works without a session playing
    // (render_noise advances no elements and no transport); otherwise
    // silence. The audio graph proper stays idle either way.
    if (output) {
      if (self->graph_->noise_active()) {
        self->graph_->render_noise(reinterpret_cast<float*>(output), frames,
                                   channels);
        if (self->mute_output_) {
          std::memset(output, 0,
                      static_cast<size_t>(frames) * channels * sizeof(float));
        }
      } else {
        std::memset(output, 0,
                    static_cast<size_t>(frames) * channels * sizeof(float));
      }
    }
    // No graph processing when paused — CPU load is negligible.
    state->audio_cpu_load = 0.0f;
    // Reset the dropout detector so the first callback after unpause
    // doesn't register the pause as a stall.
    self->dropout_detector_.reset();
    // Still acknowledge OAR reconfigures while paused. AudioGraph::process
    // posts the ack, but it's skipped on this branch; without it,
    // OarRenderer::rebuild() spin-waits up to 500 ms per call. During
    // playback_open we call rebuild() multiple times before unpausing,
    // adding ~1 s per OAR rebuild to the open path. The skip is safe
    // because we never feed or render OAR on the paused branch.
    //
    // Likewise complete any requested output fade instantly: the
    // output is already silent while paused, so the snap is inaudible
    // and keeps fade_out_and_wait() from stalling on paused rebuilds.
    if (auto* oar = self->graph_->oar_renderer(); oar != nullptr) {
      oar->fade_snap_to_target();
      if (oar->is_reconfiguring()) oar->acknowledge_reconfiguring();
    }
    // Same rationale for the mix-bus loudness reconfigure fence: process()
    // (which posts the ack) doesn't run on this branch, so a pause-time
    // meter reset would otherwise stall on the fence timeout (issue ES-145).
    self->graph_->ack_loudness_reconfigure_if_pending();
    // And for clip clears: a request posted just before a pause (or an
    // EOF auto-pause) must not stay stranded until the next play.
    self->graph_->consume_pending_clip_clear();
    // And for staged IAMF seeks (ES-473): a scrub while paused must
    // reach the session now — process() (which runs the seek state
    // machine) is skipped on this branch, and resume would otherwise
    // start from the stale position.
    self->graph_->consume_pending_seek_paused();
    // Drain the OAR pipeline's held tail while paused (ES-530) — the
    // limiter delay line (and on binaural, the convolver state) still
    // hold the last stretch of the pre-stop program, which would
    // otherwise replay as a stale burst at the head of the resumed
    // output. One zero-fed render per paused callback until silent;
    // the paused branch has the budget for it.
    self->graph_->drain_oar_tail_paused();
    return;
  }

  // steady_clock::now() is a lock-free monotonic read on both backends
  // (mach_absolute_time on macOS, QueryPerformanceCounter on Windows) —
  // safe on the audio thread.
  const auto t0 = std::chrono::steady_clock::now();

  const double period_ns = static_cast<double>(frames) /
                           static_cast<double>(self->sample_rate_) * 1e9;
  const auto period_ms = static_cast<float>(period_ns / 1e6);

  // ── Dropout detection ─────────────────────────────────────────────
  // Neither backend surfaces xruns directly; DropoutDetector infers
  // lost buffers from cumulative delivery throughput vs wall clock
  // (tolerant of burst-paced callback delivery — see dropout_detector.h).
  const uint64_t t0_ns = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          t0.time_since_epoch())
          .count());
  const DropoutDetector::Result drop =
      self->dropout_detector_.on_callback(t0_ns, frames, self->sample_rate_);
  if (drop.new_dropouts > 0) {
    self->dropout_count_ += drop.new_dropouts;
    // Publish the latest event details first, then bump the counter
    // last — Dart reads counter deltas as the "new event" signal, so
    // this ordering avoids it ever observing a bumped count paired
    // with stale details. The release fence prevents the compiler (or
    // weakly-ordered CPUs on the writer side) from reordering the
    // detail stores past the count store.
    state->last_dropout_behind_ms = drop.behind_ms;
    state->last_dropout_period_ms = period_ms;
    state->last_dropout_cb = self->callback_count_;
    std::atomic_thread_fence(std::memory_order_release);
    state->audio_dropout_count = self->dropout_count_;
  }

  self->graph_->process(reinterpret_cast<float*>(output), frames, channels);

  // Transport edge fades (ES-530): the gain ramps toward 0 while a user
  // fade-stop is pending and toward 1 otherwise (covering the resume
  // edge — the gain parks at whatever the pause left, 0 after a
  // user stop). Wall-clock durations, so the shape survives every
  // sample-rate / buffer-size combination; a play() mid-fade-out just
  // ramps back up from wherever the gain is — no jump. Runs after
  // metering (meters show what fed the fade), before the mute. In the
  // steady gain == target == 1 state this is a one-load no-op.
  // One snapshot of the transport word serves the whole fade section:
  // `stopping` decides the ramp target and the position hold, and the
  // park below CASes against this exact snapshot, so the park can only
  // land if no control-thread transition (play, pause, barrier)
  // intervened since (ES-547). Loaded here — after process(), not at
  // callback entry — so a pause arriving during process() still fades
  // and holds the position in this same block (the playhead must not
  // creep a buffer past the stop point).
  const uint64_t transport_snapshot =
      self->transport_word_.load(std::memory_order_acquire);
  const bool stopping = (transport_snapshot & kTransportFadePendingBit) != 0;
  // The fade-out block is a release tail, not program progress: hold
  // the position where the user stopped. The UI playhead reads this
  // counter, and advancing it here nudged the playhead forward by a
  // buffer on every stop; resume re-seeks the graph to the UI
  // position anyway, so nothing depends on the tail being counted.
  if (!stopping) self->position_frames_.fetch_add(frames);
  const float fade_target = stopping ? 0.0f : 1.0f;
  // Apply whenever the block is not steady unity — NOT merely when
  // gain != target: a failed park CAS (a transition raced it) leaves
  // gain == target == 0 into the next stopping block, which must
  // still be silenced, not passed to the device at full scale.
  if (self->transport_gain_ < 1.0f || fade_target < 1.0f) {
    if (output) {
      self->transport_gain_ =
          transport_fade_apply(reinterpret_cast<float*>(output), frames,
                               channels, self->transport_gain_, fade_target,
                               self->fade_in_step_, self->fade_out_step_);
    } else {
      self->transport_gain_ = fade_target;
    }
  }
  if (stopping && self->transport_gain_ <= 0.0f) {
    // Fade-out complete — park the transport (clear both bits, bump
    // the seq) in one CAS against the snapshot this block faded
    // under. Any control transition since — a play (must not be
    // overwritten: the app believes it is playing and never re-sends
    // play, ES-547), another pause, a barrier — bumped the seq, fails
    // the CAS, and the next callback re-evaluates the fresh word
    // (gain is already 0, so a still-pending stop parks then; a play
    // ramps back up). On success the paused branch (and its OAR tail
    // drain) takes over from the next callback.
    uint64_t expected = transport_snapshot;
    self->transport_word_.compare_exchange_strong(
        expected, transport_next(transport_snapshot, 0),
        std::memory_order_acq_rel);
  }

  if (self->mute_output_ && output) {
    std::memset(output, 0,
                static_cast<size_t>(frames) * channels * sizeof(float));
  }

  const auto t1 = std::chrono::steady_clock::now();

  const double elapsed_ns = static_cast<double>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());

  const float load =
      (period_ns > 0.0) ? static_cast<float>(elapsed_ns / period_ns) : 0.0f;

  // ── Overrun detection ─────────────────────────────────────────────
  // The callback body took longer than the buffer period — this
  // callback's output is late, and the next one will be late too
  // unless the backlog is absorbed.
  if (elapsed_ns > period_ns) {
    self->overrun_count_++;
    // Same pattern as dropout above: publish details first, fence,
    // then bump the counter last.
    state->last_overrun_elapsed_ms = static_cast<float>(elapsed_ns / 1e6);
    state->last_overrun_period_ms = period_ms;
    state->last_overrun_cb = self->callback_count_;
    std::atomic_thread_fence(std::memory_order_release);
    state->audio_overrun_count = self->overrun_count_;
  }

  // Exponential moving average. Read into a local: RelaxedAtomic's
  // compound ops are load-then-store, and the EMA needs one coherent
  // read of the previous value anyway.
  const float prev = state->audio_cpu_load;
  state->audio_cpu_load = prev + kCpuLoadAlpha * (load - prev);
}
