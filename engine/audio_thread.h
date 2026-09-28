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

#ifndef ECLIPSA_STUDIO_ENGINE_AUDIO_THREAD_H_
#define ECLIPSA_STUDIO_ENGINE_AUDIO_THREAD_H_

#include <atomic>
#include <cstdint>

#include "dropout_detector.h"

// Forward declarations.
class AudioGraph;
class DeviceManager;

/// Owns the connection between the DeviceManager callback and AudioGraph.
///
/// Manages playback state (playing/paused) and transport position tracking.
/// The data_callback runs on the backend's real-time audio thread; all
/// other methods run on the control thread.
class AudioThread {
 public:
  AudioThread();
  ~AudioThread();

  /// Wire the audio graph to the device and start the callback.
  bool start(AudioGraph& graph, DeviceManager& device, uint32_t sample_rate,
             uint32_t buffer_frames);

  /// Stop the device stream (callback will no longer be called).
  void stop();

  // ── Transport state word ───────────────────────────────────────────
  // {playing, fade-stop pending, transition seq} live in ONE atomic so
  // every observer sees a coherent pair and the callback's park can be
  // a single CAS against the exact state it observed (ES-547). Split
  // across two atomics, the park raced control-thread transitions: a
  // play() landing inside the final fade block was overwritten by the
  // park (wedged transport), and patching that with fix-up stores
  // reordered the park's publication under its control-side waiters.
  // Control transitions are CAS loops so they compose with the park
  // CAS (the audio thread's only write, which can only move
  // playing→parked and only against an unchanged word); they are
  // uncontended in practice — all transport FFI runs on the Dart main
  // isolate.

  void set_playing(bool playing) {
    // Any explicit transition discards a pending fade-stop: a quick
    // pause→play must not have the stale fade consumed as a stop
    // against the resumed program, and a barrier's instant pause
    // supersedes a still-ramping user stop.
    uint64_t w = transport_word_.load(std::memory_order_relaxed);
    uint64_t next;
    do {
      next = transport_next(w, playing ? kTransportPlayingBit : 0);
    } while (!transport_word_.compare_exchange_weak(
        w, next, std::memory_order_release, std::memory_order_relaxed));
  }
  bool is_playing() const {
    return (transport_word_.load(std::memory_order_acquire) &
            kTransportPlayingBit) != 0;
  }

  /// Transport state as the user intends it: false as soon as a
  /// fade-stop is pending — the fade block still renders, but the
  /// transport is logically stopped. Barrier save/restore paths must
  /// use THIS, not is_playing(): saving the raw flag inside the
  /// one-block fade window would "restore" a transport the user just
  /// stopped back into play. Single load — the pair is coherent.
  bool is_logically_playing() const {
    const uint64_t w = transport_word_.load(std::memory_order_acquire);
    return (w & kTransportPlayingBit) != 0 &&
           (w & kTransportFadePendingBit) == 0;
  }

  /// Click-free user stop (ES-530): the transport keeps rendering while
  /// the device output ramps to silence (kTransportFadeOutMs of wall
  /// clock, across however many callbacks the buffer size implies),
  /// then parks — a release instead of a hard mid-waveform cut. Only
  /// the user-facing pause path uses this; teardown/mutation barriers
  /// keep calling set_playing(false) directly because their contract
  /// is "no process() after quiescence", which fade blocks would
  /// break (they use wait_fade_stop_parked() to let a ramp land
  /// first). No-op while already paused.
  void request_fade_stop() {
    // CAS loop (not a plain store): the parked guard must hold against
    // the word actually replaced — a stale pre-park read here would
    // otherwise re-assert the playing bit and resurrect a transport
    // the audio thread just parked.
    uint64_t w = transport_word_.load(std::memory_order_relaxed);
    uint64_t next;
    do {
      if ((w & kTransportPlayingBit) == 0) return;  // Already parked.
      // On a dead device no callbacks will fire to run the fade — park
      // immediately so the transport state cannot wedge.
      next = transport_next(w, is_running_.load() ? kTransportPlayingBit |
                                                        kTransportFadePendingBit
                                                  : 0);
    } while (!transport_word_.compare_exchange_weak(
        w, next, std::memory_order_release, std::memory_order_relaxed));
  }

  /// Control thread: if a user fade-stop is still ramping, wait
  /// (bounded) for the audio thread to park itself so the fade lands
  /// click-free BEFORE a barrier imposes its instant pause. The
  /// routine offender is the app's stop path, which calls
  /// eclipsa_studio_meter_reset_levels() immediately after
  /// eclipsa_studio_transport_pause() — without this wait the barrier's
  /// set_playing(false) truncates the 10 ms release after a fraction
  /// of it has played, and leaves the transport gain mid-ramp, which
  /// then guts the next play's fade-in. Returns immediately when no
  /// fade is pending; falls through on timeout (dead/stalled device)
  /// so barriers can never wedge on it.
  void wait_fade_stop_parked(uint32_t timeout_ms = 100);

  /// Block until any in-flight audio callback has returned. Intended
  /// for the control thread to call before mutating shared state that
  /// the callback observes (e.g. tearing down the IAMF session). Set
  /// `set_playing(false)` first; this waits until the next callback
  /// boundary on the paused branch confirms the audio thread is no
  /// longer inside `graph_->process()`. Returns false if the device
  /// is not running (no callbacks will fire) or if the wait timed out.
  bool wait_for_callback_quiescent(uint32_t timeout_ms = 100);

  /// True when start() has successfully opened the device and the
  /// callback is wired up; cleared by stop().
  bool is_running() const { return is_running_.load(); }

  /// Sample-frame position of the playhead.
  uint64_t position_frames() const { return position_frames_.load(); }

  /// Transport seek — updates position; WAV seeks are handled by AudioGraph.
  void seek(uint64_t frames) { position_frames_.store(frames); }

  double sample_rate() const { return sample_rate_; }

 private:
  /// Called by DeviceManager on the audio thread.
  static void data_callback(void* output, uint32_t frames, uint32_t channels,
                            void* user_data);

  AudioGraph* graph_ = nullptr;
  DeviceManager* device_ = nullptr;
  uint32_t sample_rate_ = 48000;
  uint64_t callback_count_ = 0;  // Audio-thread only.

  // Zero the buffer handed to hardware as the last step of the
  // callback. Set from ECLIPSA_STUDIO_MUTE_OUTPUT in start() (before the
  // device starts, so no race with the callback) so engine tests can
  // run on the real output device without audible tones (ES-348). All
  // test-observable work — graph processing, meters, clip latching,
  // position advance — happens before the mute, so it is invisible to
  // assertions. The app never sets the variable.
  bool mute_output_ = false;

  // ── Dropout / overrun detection (audio-thread only) ────────────────
  //
  // A "dropout" is a buffer's worth of audio the output device consumed
  // but we never delivered — audible as a click or stutter. Detected by
  // DropoutDetector from cumulative delivery throughput, which stays
  // quiet on burst-paced (but lossless) callback delivery; see
  // dropout_detector.h.
  //
  // An "overrun" is when a single callback takes longer than the buffer
  // period. That callback's output is late and the next one will be
  // late too.
  //
  // Counts are mirrored into EclipsaStudioMeterState so the Dart tick loop
  // can observe deltas and route the messages through Log.w → JSONL.
  // The detector is reset on pause so the first unpaused callback
  // doesn't register the pause gap as a stall.
  DropoutDetector dropout_detector_;
  uint64_t dropout_count_ = 0;
  uint64_t overrun_count_ = 0;

  // Bit layout of transport_word_ (see the class comment on the word
  // at set_playing above).
  static constexpr uint64_t kTransportPlayingBit = 1ull << 0;
  static constexpr uint64_t kTransportFadePendingBit = 1ull << 1;
  static constexpr uint64_t kTransportSeqIncrement = 1ull << 2;

  /// The successor word for a transition from `w`: both state bits
  /// cleared, seq bumped, then `bits` applied. Every writer goes
  /// through this so no copy of the bit expression can drift.
  static constexpr uint64_t transport_next(uint64_t w, uint64_t bits) {
    return ((w & ~(kTransportPlayingBit | kTransportFadePendingBit)) +
            kTransportSeqIncrement) |
           bits;
  }

  // The transport state word. Written by control-thread transitions
  // (set_playing / request_fade_stop / stop) and by exactly one
  // audio-thread writer: the fade-out park CAS in data_callback,
  // which can only move playing→parked and only when no transition
  // intervened since the callback observed the fade (ES-547).
  std::atomic<uint64_t> transport_word_{0};

  // ── Transport edge fade (ES-530; audio-thread only) ──────────────────
  // Output gain ramped toward 1 while playing and toward 0 while a
  // fade-stop is pending; persists across callbacks so the wall-clock
  // fade durations survive any buffer size. Starts at 0 so the first
  // play fades in. Steps are set in start() from the device rate.
  float transport_gain_ = 0.0f;
  float fade_in_step_ = 1.0f;
  float fade_out_step_ = 1.0f;
  std::atomic<bool> is_running_{false};
  std::atomic<uint64_t> position_frames_{0};

  // Mirrors `callback_count_` for cross-thread observers. The audio
  // callback publishes after each entry; the control thread reads it
  // via `wait_for_callback_quiescent` to bound a teardown barrier.
  std::atomic<uint64_t> published_callback_count_{0};
};

#endif  // ECLIPSA_STUDIO_ENGINE_AUDIO_THREAD_H_
