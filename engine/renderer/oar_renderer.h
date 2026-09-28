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

#ifndef ECLIPSA_STUDIO_RENDERER_OAR_RENDERER_H_
#define ECLIPSA_STUDIO_RENDERER_OAR_RENDERER_H_

#include <atomic>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <vector>

// Forward-declare the OAR opaque type to avoid leaking the OAR header.
typedef struct Oar oar_t;

/// Single-instance OAR renderer.
///
/// One OAR instance at a time — switching between loudspeaker and binaural
/// layouts destroys and recreates the renderer.  Pre-allocates all output
/// buffers at init time — zero heap on the audio thread.
class OarRenderer {
 public:
  OarRenderer();
  ~OarRenderer();

  // Non-copyable.
  OarRenderer(const OarRenderer&) = delete;
  OarRenderer& operator=(const OarRenderer&) = delete;

  /// Initialise the renderer.
  /// @param sample_rate     Output sample rate (e.g. 48000).
  /// @param buffer_size     Frames per audio callback.
  /// @param layout          Target layout (oar_layout_t enum value).
  /// @returns true on success.
  bool init(uint32_t sample_rate, uint32_t buffer_size, uint32_t layout);

  /// Tear down the OAR instance and all tracked state. Must not be
  /// called while the audio device is running: both call sites —
  /// init() before the device starts, and the destructor after
  /// AudioThread::stop() — guarantee no audio thread. The short ack
  /// wait inside is a belt-and-braces check, not a license to call
  /// this concurrently with a live callback (skipped entirely after
  /// set_no_audio_thread()).
  void shutdown();

  /// Add an audio element to the renderer.
  bool add_element(uint32_t element_id, int type, int sub_type,
                   uint32_t channels);

  /// Remove an element from the renderer.
  void remove_element(uint32_t element_id);

  /// Update the per-element IAMF rendering config. Stages the change
  /// and marks the renderer dirty — commit_rendering_config() must be
  /// called to actually apply it. OAR latches these fields at element-
  /// add time, so committing triggers a full rebuild of the OAR
  /// instance. Batching avoids N rebuilds on session load / mix switch.
  ///
  /// @param element_id  Element to update (must already be tracked).
  /// @param mode        oar_headphones_rendering_mode_t value
  ///                    (0=stereo fallback for channel-based; also
  ///                    binaural world-locked for scene/object.
  ///                    1=binaural world-locked. 2=binaural head-locked).
  /// @param profile     oar_binaural_filter_profile_t value
  ///                    (0=AMBIENT, 1=DIRECT, 2=REVERBERANT).
  /// @returns true if the element was tracked, false otherwise.
  bool set_element_rendering_config(uint32_t element_id, uint32_t mode,
                                    uint32_t profile);

  /// Rebuild the OAR instance if any pending rendering-config changes
  /// have been staged via set_element_rendering_config(). No-op if
  /// nothing is dirty. Returns true on success.
  bool commit_rendering_config();

  /// Feed per-element PCM (planar float) to the renderer.
  /// @param stride  Planar stride (capacity_frames, not active frames).
  void update_element_data(uint32_t element_id, const float* data,
                           uint32_t channels, uint32_t frames, uint32_t stride);

  /// Push per-element IAMF mix gain metadata to OAR via
  /// oar_update_audio_element_metadata() with ck_metadata_gain. The gain
  /// is pushed as a linear animated ramp (ck_param_animated +
  /// ck_animation_type_linear) from `start_db` at sample 0 to `end_db`
  /// at sample `frames`. OAR interpolates within the block at sample
  /// rate, so callers can pass end=start for a flat gain, or chain
  /// consecutive blocks by setting this call's `start` to the previous
  /// call's `end` — giving sample-accurate and block-continuous ramps
  /// without introducing click artifacts on fast parameter changes.
  ///
  /// Must be called on the audio thread (like update_element_data) so
  /// it is sequenced correctly with rendering.
  void set_element_mix_gain(uint32_t element_id, float start_db, float end_db,
                            uint32_t frames);

  /// Push constant polar position(s) for an object-based element via
  /// oar_update_audio_element_metadata() with
  /// ck_metadata_object_positions, covering the next `frames` samples.
  /// OAR's object-to-loudspeaker renderer (OLR) creates its per-object
  /// processing only when position metadata arrives — an object
  /// element that never receives positions renders silence on every
  /// speaker layout. `count` is clamped to [1, 2]; az/el/dist point at
  /// `count` values (degrees / degrees / normalized 0..1).
  ///
  /// Must be called on the audio thread (like set_element_mix_gain) so
  /// it is sequenced correctly with rendering; the caller re-pushes
  /// every callback, which keeps OAR's metadata queue at one entry and
  /// re-seeds positions after any rebuild.
  void set_element_object_positions(uint32_t element_id, uint32_t count,
                                    const float* az_deg, const float* el_deg,
                                    const float* dist, uint32_t frames);

  /// Push group-level IAMF mix gain (output mix gain / master fader) via
  /// oar_update_metadata() with ck_metadata_gain. Same linear-ramp
  /// semantics as set_element_mix_gain — start/end in dB, OAR
  /// interpolates within the block.
  ///
  /// Must be called on the audio thread. gid defaults to 0 (the only
  /// group currently created).
  void set_output_mix_gain(float start_db, float end_db, uint32_t frames,
                           uint32_t gid = 0);

  /// Render output. Returns pointer to planar float output
  /// (ch0[0..N], ch1[0..N], ...).
  /// Valid until next render() call. Returns nullptr if not inited.
  const float* render(uint32_t frames);

  /// Current limiter gain envelope (1.0 = no reduction).
  /// Safe to call from any thread (reads an atomic snapshot).
  double limiter_env() const;

  /// Snapshot the live limiter envelope into the atomic cache.
  /// Must be called on the thread that calls render() (the audio
  /// thread live, the render loop offline), after render().
  void snapshot_limiter_env();

  /// Output delay the limiter adds, in samples (0 when uninitialized).
  /// The limiter is the libiamf reference peak limiter liboar carries
  /// upstream: 5 ms look-ahead (240 samples at 48 kHz), parabolic 1 ms
  /// attack, 200 ms release, hard clip at the ceiling. Reads an atomic
  /// cache updated at init/rebuild — safe from any thread, never
  /// touches the OAR instance.
  uint32_t limiter_delay() const {
    return limiter_delay_.load(std::memory_order_relaxed);
  }

  /// Number of output channels for the current layout. Reads an atomic
  /// cache updated at init/rebuild time — safe from any thread, never
  /// touches the OAR instance.
  uint32_t channel_count() const {
    return channel_count_.load(std::memory_order_relaxed);
  }

  /// Current layout (oar_layout_t enum value). Control thread only
  /// (plain field, written under control_mutex_).
  uint32_t layout() const { return layout_; }

  /// Current configured buffer size (samples per channel). Atomic —
  /// safe from any thread.
  uint32_t buffer_size() const {
    return buffer_size_.load(std::memory_order_relaxed);
  }

  /// Change target layout (destroys and recreates the renderer).
  /// Safe to call from control thread — audio thread skips rendering
  /// while reconfiguration is in progress.
  bool set_layout(uint32_t layout);

  /// Reinitialise for a new sample rate + buffer size (engine
  /// reconfigure). Preserves current layout and registered elements.
  /// OAR latches the rate at create time, so this rebuilds the
  /// instance; the audio thread skips rendering during the rebuild.
  bool reinit_for_format(uint32_t new_sample_rate, uint32_t new_buffer_size);

  /// True while the renderer is being reconfigured (audio thread must
  /// skip rendering). Set by control thread, read by audio thread.
  bool is_reconfiguring() const {
    return reconfiguring_.load(std::memory_order_acquire);
  }

  /// Manually set the reconfiguring flag (e.g. to guard a start→reinit
  /// window where the audio thread is already running). Clearing is
  /// ignored while offline-exclusive mode is held (ES-158): the device
  /// start/reconfigure paths drive this flag raw, and without the
  /// guard a device change during an export pass would resume the
  /// live OAR mid-measure.
  void set_reconfiguring(bool v) {
    if (!v && offline_exclusive_depth_.load(std::memory_order_acquire) > 0) {
      return;
    }
    reconfiguring_.store(v, std::memory_order_release);
  }

  /// Enter offline-exclusive mode (ES-158): fade out, raise the
  /// reconfiguring flag so the audio thread skips OAR and emits
  /// silence, and wait for its ack — after which the caller may safely
  /// create and drive other OAR instances (the offline export /
  /// loudness renderers; ES-44 discipline). Serialized against
  /// rebuild()/set_layout()/reinit_for_format() by construction: it
  /// takes control_mutex_, and any rebuild requested while the mode is
  /// held is deferred (staged element/layout state is replayed on
  /// exit). While the mode is held, set_reconfiguring(false) from the
  /// device start/reconfigure paths is ignored.
  ///
  /// Refcounted: the mode is a nesting depth, not a bool. The callers
  /// (export dialog, loudness report) are bracketed but can overlap —
  /// on macOS the native menu bar is not blocked by Flutter's modal
  /// barrier, so both dialogs can be open at once. A nested enter just
  /// increments the depth (offline-vs-offline overlap is pinned safe
  /// by offline_mix_concurrency_test, ES-494); the live OAR stays paused
  /// until the last owner exits. An ack timeout on the first enter
  /// (audio device not running) is logged but the mode is still
  /// entered.
  void begin_offline_exclusive();

  /// Exit offline-exclusive mode. Decrements the depth; on the last
  /// exit, replays any deferred rebuild, clears the reconfiguring
  /// flag, and fades back in. No-op when the mode is not held.
  /// @returns true when this call replayed a deferred rebuild, so the
  ///          channel count may have changed and a caller that sizes
  ///          state by channel_count() (the mix-bus loudness meter) must
  ///          resync.
  bool end_offline_exclusive();

  /// True while offline-exclusive mode is held. Every rebuild requested
  /// in that state is deferred, so channel_count() still reports the
  /// pre-switch count after set_layout() returns.
  bool is_offline_exclusive() const {
    return offline_exclusive_depth_.load(std::memory_order_acquire) > 0;
  }

  /// Block (spin-wait + std::this_thread::yield) until the audio thread
  /// acknowledges it has observed is_reconfiguring()==true and exited
  /// any in-flight oar_render() call. Returns true on ack, false on
  /// timeout (audio device may not be running). Set the reconfiguring
  /// flag *before* calling this.
  ///
  /// Used by rebuild() and by code that wants to safely operate on OAR
  /// state (or alternative OAR instances) without racing the audio
  /// thread — e.g. the offline export renderer. Returns true
  /// immediately when set_no_audio_thread() was called.
  bool wait_for_audio_thread_ack(int timeout_ms = 500);

  /// Declare that no audio thread will ever drive this instance
  /// (offline render / measure — OfflineMixRenderer). Makes
  /// fade_out_and_wait() and wait_for_audio_thread_ack() succeed
  /// immediately: with no consumer there is nothing to fade and no ack
  /// to wait for, so tearing down or rebuilding right away is safe —
  /// spinning to the timeouts instead burned ~0.55 s per rebuild
  /// (ES-515). Call before use; irreversible. Must never be called on
  /// the live instance.
  void set_no_audio_thread() { no_audio_thread_ = true; }

  /// Called by the audio thread when it observes is_reconfiguring()==true.
  /// Signals rebuild() that the audio thread is no longer accessing OAR.
  void acknowledge_reconfiguring() {
    ack_counter_.fetch_add(1, std::memory_order_release);
  }

  // ── Output fade (click-free rebuilds / device stops, issue ES-73) ────
  //
  // Every rebuild hard-cuts the output: the audio thread skips OAR
  // while reconfiguring_ is set, so program audio jumps to silence and
  // back — a waveform discontinuity at both edges. These primitives
  // bracket the gap with a short linear ramp applied by the audio
  // thread to the rendered output (AudioGraph::process → fade_block).
  // The ramp-down happens BEFORE reconfiguring_ is set, while the
  // renderer is still alive, so rendering during the fade is race-free.

  /// Request a fade to silence and block until the audio thread
  /// reports the output gain reached zero. Resolves via render
  /// callbacks while playing, via the paused-branch snap otherwise,
  /// and immediately when already silent. Returns false on timeout
  /// (no callbacks at all — device not running); callers proceed,
  /// accepting a possible click. Control thread only. Returns true
  /// immediately — without touching the fade state — when
  /// set_no_audio_thread() was called.
  bool fade_out_and_wait(int timeout_ms = kFadeWaitTimeoutMs);

  /// Restore the output: the audio thread ramps the gain back to
  /// unity on subsequent rendered blocks over [seconds] (default: the
  /// short click-killer ramp). Pass kReopenFadeSeconds for an audibly
  /// gentle ramp — used when the output device itself changed
  /// (ES-467), where a near-instant resume on new hardware reads as a
  /// hard cut. Control thread only.
  void fade_in(float seconds = kFadeSeconds) {
    // The guard rejects zero, negatives, NaN (all comparisons false)
    // and infinity, any of which would stall or zero the ramp step.
    fade_seconds_.store(
        std::isfinite(seconds) && seconds > 0.0f ? seconds : kFadeSeconds,
        std::memory_order_relaxed);
    fade_target_.store(1.0f, std::memory_order_release);
  }

  /// Gentle ramp-in length for a device-switch reopen (see fade_in).
  static constexpr float kReopenFadeSeconds = 0.1f;

  /// Compute this block's fade gains and advance the fade state.
  /// `*g0`/`*g1` are the gains at the block's first and last frame;
  /// the caller applies a linear ramp between them. Audio thread only.
  void fade_block(uint32_t frames, uint32_t sample_rate, float* g0, float* g1);

  /// Complete any requested fade instantly. Called from the paused
  /// branch of the audio callback — output is silent while paused, so
  /// the snap is inaudible and keeps fade_out_and_wait() from
  /// stalling on rebuilds done while the transport is paused (e.g.
  /// playback_open). Audio thread only.
  void fade_snap_to_target() {
    fade_gain_.store(fade_target_.load(std::memory_order_relaxed),
                     std::memory_order_release);
  }

 private:
  /// Default output fade length. Long enough to kill the
  /// discontinuity, short enough to be imperceptible as a fade. With
  /// large buffers a single block may span the whole fade; the ramp
  /// then stretches across that block.
  static constexpr float kFadeSeconds = 0.005f;

  /// Bound on fade_out_and_wait when no callbacks advance or snap the
  /// gain (device not running). Generous vs. kFadeSeconds plus one
  /// buffer period at the largest supported buffer size.
  static constexpr int kFadeWaitTimeoutMs = 50;
  /// RAII guard: sets reconfiguring_ on construction, clears on destruction.
  struct ReconfigGuard {
    std::atomic<bool>& flag;
    explicit ReconfigGuard(std::atomic<bool>& f) : flag(f) {
      flag.store(true, std::memory_order_release);
    }
    ~ReconfigGuard() { flag.store(false, std::memory_order_release); }
  };

  oar_t* renderer_ = nullptr;

  uint32_t sample_rate_ = 48000;
  // Atomic: read by the audio thread (update_element_data / render
  // logging) and the control/UI threads; written under control_mutex_.
  std::atomic<uint32_t> buffer_size_{512};
  uint32_t layout_ = 0;  // oar_layout_t

  // Output channel count of the current OAR instance, cached at
  // init/rebuild so channel_count() never dereferences renderer_.
  // Written under control_mutex_; read from any thread.
  std::atomic<uint32_t> channel_count_{0};

  // A renderer whose teardown had to be deferred: rebuild() hit the
  // ack timeout, so the audio thread may still be inside oar_render()
  // on this instance — destroying it (or freeing the output buffers an
  // in-flight render writes into) would be a use-after-free. Kept
  // alive until the next successful ack proves no OAR access is in
  // flight. Guarded by control_mutex_; a vector covers back-to-back
  // timeout rebuilds (bounded by the consecutive-timeout count).
  struct Zombie {
    oar_t* renderer = nullptr;
    std::vector<float> output;
    std::vector<float> interleaved_tmp;
  };
  std::vector<Zombie> zombies_;

  // Pre-allocated planar output buffer.
  std::vector<float> output_;

  // Temporary buffer for compacting planar element data.
  std::vector<float> interleaved_tmp_;

  // Track which elements have been added.
  struct ElementInfo {
    uint32_t id;
    int type;
    int sub_type;
    uint32_t channels;
    // IAMF element_rendering_config — OAR latches these at element-add
    // time, so a change here requires a full rebuild. Defaults are
    // ck_world_locked (1) and ck_ambient (0), matching the UI defaults.
    uint32_t headphones_mode = 1;
    uint32_t binaural_profile = 0;
  };
  std::vector<ElementInfo> elements_;

  // True when set_element_rendering_config() has staged a change that
  // has not yet been committed (i.e. the OAR instance's latched values
  // are stale). Cleared by commit_rendering_config() after the rebuild.
  bool rendering_config_dirty_ = false;

  std::atomic<double> limiter_env_{1.0};  // Audio thread writes, Dart reads.

  // Limiter output delay of the current OAR instance, in samples.
  // Written under control_mutex_ at init/rebuild/shutdown; read from
  // any thread (limiter_delay()) without touching renderer_.
  std::atomic<uint32_t> limiter_delay_{0};
  std::atomic<bool> reconfiguring_{false};
  std::atomic<uint64_t> ack_counter_{0};

  // No audio thread will ever drive this instance (offline render /
  // measure) — the fade/ack waits short-circuit. Set once before use
  // via set_no_audio_thread(), control thread only.
  bool no_audio_thread_ = false;

  // Offline-exclusive nesting depth (ES-158). Mutated under
  // control_mutex_; atomic so set_reconfiguring() can consult it
  // lock-free from the raw device start/reconfigure call sites.
  // Non-zero while any offline pass holds the mode.
  std::atomic<uint32_t> offline_exclusive_depth_{0};
  // A rebuild was requested while offline-exclusive; replayed on exit.
  // Guarded by control_mutex_.
  bool rebuild_deferred_ = false;

  // Audio-thread warning throttles (first N per configuration). Reset
  // by rebuild() so each reconfiguration gets its own log evidence —
  // process-lifetime counters went quiet after the first burst and hid
  // recurrences entirely.
  std::atomic<uint32_t> update_drop_log_count_{0};
  std::atomic<uint32_t> mismatch_log_count_{0};
  std::atomic<uint32_t> render_drop_log_count_{0};

  // Output fade state. gain is advanced toward target by the audio
  // thread (fade_block / fade_snap_to_target) and read by the control
  // thread (fade_out_and_wait). seconds is the length of the fade
  // currently in effect: fade_in() may stretch it (device-switch
  // reopen, ES-467); fade_out_and_wait() always restores the short
  // default so fade-outs stay prompt. Both writers store seconds
  // BEFORE their release store on target, and fade_block loads it
  // AFTER its acquire load of target — that pairing is what publishes
  // seconds, so its own accesses can stay relaxed.
  std::atomic<float> fade_gain_{1.0f};
  std::atomic<float> fade_target_{1.0f};
  std::atomic<float> fade_seconds_{kFadeSeconds};

  // Serialises all control-thread mutations (set_layout,
  // add/remove_element, reinit_for_format, shutdown, offline-exclusive
  // enter/exit). NEVER taken on the audio thread — all audio-thread-
  // visible state is atomics.
  std::mutex control_mutex_;

  oar_t* create_renderer(uint32_t layout);

  /// Destroy and recreate the OAR instance with the current layout
  /// and all tracked elements. Caller holds control_mutex_. Deferred
  /// (staged, replayed on exit) while offline-exclusive mode is held.
  bool rebuild();

  /// shutdown() body; caller holds control_mutex_ (init() re-enters
  /// via this to avoid self-deadlock).
  void shutdown_locked();

  /// Destroy any zombie renderers. Caller holds control_mutex_ and has
  /// just observed a successful audio-thread ack (or guarantees no
  /// audio thread), proving no in-flight OAR access remains.
  void reap_zombies_locked();
};

#endif  // ECLIPSA_STUDIO_RENDERER_OAR_RENDERER_H_
