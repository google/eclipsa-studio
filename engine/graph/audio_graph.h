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

#ifndef ECLIPSA_STUDIO_GRAPH_AUDIO_GRAPH_H_
#define ECLIPSA_STUDIO_GRAPH_AUDIO_GRAPH_H_

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "dsp/pink_noise.h"
#include "graph/audio_buffer.h"
#include "meters/meter_state.h"

// Forward declarations (implementations included in audio_graph.cc).
class WavReader;
class IamfPlaybackSession;
class IamfRingSource;
class PeakMeter;
class RmsMeter;
class LoudnessMeter;
class ChannelStats;
class OarRenderer;
namespace dsp {
class Gain;
class Resampler;
}  // namespace dsp

static constexpr uint32_t kGraphMaxElements = kEclipsaStudioMaxElements;
static constexpr uint32_t kGraphMaxChannels = 28;
static constexpr uint32_t kGraphMaxFrames = 4096;

/// Trivially-copyable per-element control fields, grouped so
/// ElementChain::reset()/move_from() handle them wholesale through
/// reset()/copy_from() below instead of field-by-field at a distance —
/// mix_excluded and wav_channels were each forgotten there once
/// (issue ES-323). When adding a field, update reset() and copy_from()
/// immediately below the field list. Atomics are copied via relaxed
/// load/store (plain struct assignment is not possible for them, which
/// is why the two functions exist at all).
struct ElementControlState {
  std::atomic<bool> active{false};
  std::atomic<bool> muted{false};
  std::atomic<bool> solo{false};
  std::atomic<bool> mix_excluded{false};
  std::atomic<bool> is_scene{false};

  // Per-element IAMF mix gain target (element_mix_gain from the active
  // mix presentation). Control thread writes via set_element_mix_gain;
  // audio thread reads each callback and produces a slew-limited linear
  // ramp to OAR as ck_param_animated metadata.
  std::atomic<float> mix_gain_db{0.0f};

  // Audio-thread only — slew-limited target the audio thread is
  // currently moving toward. Each callback clamps the delta from
  // mix_gain_db to +/- kMaxMixGainDbPerCallback so text-edit jumps
  // and other abrupt changes fade in over a few callbacks instead of
  // producing a hard click.
  float mix_gain_slewed_db = 0.0f;

  // Audio-thread only — the end value we sent to OAR last callback,
  // used as the start of the next block's ramp so consecutive blocks
  // are sample-continuous.
  float mix_gain_last_sent_db = 0.0f;

  // Object-based flag + polar position targets. Control thread writes
  // via set_element_object_position / set_element_object; the audio
  // thread pushes a constant-position metadata block to OAR every
  // callback while is_object is set. OAR's object-to-loudspeaker
  // renderer (OLR) creates its per-object processing only when
  // position metadata arrives, so an object element with no pushed
  // position renders SILENCE on every speaker layout — the per-
  // callback push both fixes that and makes positions survive OAR
  // rebuilds (layout switches, element adds) with no extra machinery.
  // The second triplet is used only when object_count == 2 (dual).
  std::atomic<bool> is_object{false};
  std::atomic<uint32_t> object_count{1};
  std::atomic<float> object_az{0.0f};
  std::atomic<float> object_el{0.0f};
  std::atomic<float> object_dist{1.0f};
  std::atomic<float> object_az2{0.0f};
  std::atomic<float> object_el2{0.0f};
  std::atomic<float> object_dist2{1.0f};

  // Source channel count (from WAV). Cached so the audio-thread remap
  // step can reset `buf` to the WAV view at the top of each callback
  // without touching the WavReader.
  uint32_t wav_channels = 0;

  /// Reinitialize every field to its default-constructed value.
  void reset() {
    active.store(false, std::memory_order_relaxed);
    muted.store(false, std::memory_order_relaxed);
    solo.store(false, std::memory_order_relaxed);
    mix_excluded.store(false, std::memory_order_relaxed);
    is_scene.store(false, std::memory_order_relaxed);
    mix_gain_db.store(0.0f, std::memory_order_relaxed);
    mix_gain_slewed_db = 0.0f;
    mix_gain_last_sent_db = 0.0f;
    is_object.store(false, std::memory_order_relaxed);
    object_count.store(1, std::memory_order_relaxed);
    object_az.store(0.0f, std::memory_order_relaxed);
    object_el.store(0.0f, std::memory_order_relaxed);
    object_dist.store(1.0f, std::memory_order_relaxed);
    object_az2.store(0.0f, std::memory_order_relaxed);
    object_el2.store(0.0f, std::memory_order_relaxed);
    object_dist2.store(1.0f, std::memory_order_relaxed);
    wav_channels = 0;
  }

  /// Wholesale copy from `src` (atomics via relaxed load/store).
  void copy_from(const ElementControlState& src) {
    active.store(src.active.load(std::memory_order_relaxed),
                 std::memory_order_relaxed);
    muted.store(src.muted.load(std::memory_order_relaxed),
                std::memory_order_relaxed);
    solo.store(src.solo.load(std::memory_order_relaxed),
               std::memory_order_relaxed);
    mix_excluded.store(src.mix_excluded.load(std::memory_order_relaxed),
                       std::memory_order_relaxed);
    is_scene.store(src.is_scene.load(std::memory_order_relaxed),
                   std::memory_order_relaxed);
    mix_gain_db.store(src.mix_gain_db.load(std::memory_order_relaxed),
                      std::memory_order_relaxed);
    mix_gain_slewed_db = src.mix_gain_slewed_db;
    mix_gain_last_sent_db = src.mix_gain_last_sent_db;
    is_object.store(src.is_object.load(std::memory_order_relaxed),
                    std::memory_order_relaxed);
    object_count.store(src.object_count.load(std::memory_order_relaxed),
                       std::memory_order_relaxed);
    object_az.store(src.object_az.load(std::memory_order_relaxed),
                    std::memory_order_relaxed);
    object_el.store(src.object_el.load(std::memory_order_relaxed),
                    std::memory_order_relaxed);
    object_dist.store(src.object_dist.load(std::memory_order_relaxed),
                      std::memory_order_relaxed);
    object_az2.store(src.object_az2.load(std::memory_order_relaxed),
                     std::memory_order_relaxed);
    object_el2.store(src.object_el2.load(std::memory_order_relaxed),
                     std::memory_order_relaxed);
    object_dist2.store(src.object_dist2.load(std::memory_order_relaxed),
                       std::memory_order_relaxed);
    wav_channels = src.wav_channels;
  }
};

/// Processing chain for one audio element.
/// All heavyweight objects are heap-allocated once in add_element(); the
/// audio thread never allocates — it just uses the pre-allocated objects.
struct ElementChain {
  uint32_t id = 0;

  // Grouped control fields — see ElementControlState. Routing state
  // stays out of the group: routing_map points into this chain's own
  // storage arrays, so move_from() has to recompute it rather than
  // copy it (see below).
  ElementControlState ctrl;

  // Processing pipeline (allocated once, used on audio thread).
  // Exactly one of {wav_reader, iamf_ring_source} is set per active
  // chain: WAV-sourced in Creator, IAMF-sourced in Playback.
  std::unique_ptr<WavReader> wav_reader;
  // Sample-rate converter. Non-null iff the WAV's native rate differs
  // from the engine output rate; on the matched-rate fast path
  // WavReader::read writes straight into chain.buf.
  std::unique_ptr<dsp::Resampler> resampler;
  std::unique_ptr<IamfRingSource> iamf_ring_source;
  std::unique_ptr<dsp::Gain> gain;
  // Dedicated mute gain — ramps to -120 dB when the element is muted (or
  // silenced by solo) and back to 0 dB when unmuted. Placed after user
  // DSP and before metering so meters reflect audible output. Uses the
  // Gain node's built-in IIR smoothing to avoid clicks.
  std::unique_ptr<dsp::Gain> mute_gain;
  std::unique_ptr<PeakMeter> peak_meter;
  std::unique_ptr<RmsMeter> rms_meter;
  std::unique_ptr<ChannelStats> channel_stats;

  // Per-element pre-allocated audio buffer.
  float buf_storage[kGraphMaxChannels * kGraphMaxFrames] = {};
  AudioBuffer buf;

  // Scratch buffer for input-channel remapping. The audio thread writes
  // the remapped (dest-indexed) planar signal here and swaps buf.data to
  // point at it; no allocation on the audio thread.
  float buf_remap_storage[kGraphMaxChannels * kGraphMaxFrames] = {};

  // Input routing map. routing_map is a pointer to one of the two
  // storage slots (double-buffered for lock-free publish). Convention:
  // routing_map[dest] = src_channel, where src is a WAV channel index,
  // or -1 to silence that dest. nullptr = identity (fast path; no
  // remap step, buf unchanged).
  std::atomic<const int8_t*> routing_map{nullptr};
  int8_t routing_storage_a[kGraphMaxChannels] = {};
  int8_t routing_storage_b[kGraphMaxChannels] = {};
  uint8_t routing_active_slot = 0;  // which of {a,b} is currently published.
  uint8_t routing_len = 0;

  /// Reset this chain to a default-constructed state (frees unique_ptrs).
  /// Defined in audio_graph.cc (needs complete types for unique_ptr reset).
  void reset();

  /// Move another chain's owned resources into this one.  The source is
  /// left in a reset state.  buf_storage is NOT moved (caller must re-seat
  /// buf.data afterward).
  void move_from(ElementChain& src);
};

/// Pull-based audio processing graph.
///
/// The output callback calls process() which pulls from all active element
/// chains, applies DSP, updates meters into a single shared
/// EclipsaStudioMeterState, and sums into the output buffer.
///
/// Thread-safety:
///   - process() is called from the audio thread only.
///   - add/remove/set_* are called from the control thread only.
///   - For Phase 1, no synchronisation between threads — changes take effect
///     on the next audio thread iteration.
class AudioGraph {
 public:
  AudioGraph();
  ~AudioGraph();

  bool init(uint32_t sample_rate, uint32_t max_frames, uint32_t channels);
  void shutdown();

  /// Retarget the graph to a new engine output rate after a device
  /// reconfigure. Walks every chain: re-inits the resampler at
  /// (wav_rate → new_rate), drops it where the rates now match, creates
  /// one where they newly mismatch, and refreshes meter ballistics
  /// (per-chain peak/RMS/stats + the mix-bus loudness meter).
  ///
  /// Must be called from the control thread while the audio thread is
  /// stopped — process() reads chain.resampler without locking.
  ///
  /// Returns false if any chain's resampler re-init failed; that chain
  /// is deactivated rather than left producing wrong-rate audio.
  bool set_sample_rate(uint32_t new_rate);

  /// Engine output rate the graph currently produces frames at.
  uint32_t sample_rate() const { return sample_rate_; }

  /// Add an element (loads WAV file).  Returns 0 on success, negative on error.
  int32_t add_element(uint32_t id, const char* wav_path);

  /// Remove an element by ID.
  void remove_element(uint32_t id);

  /// Copies the element id occupying each physical slot, in slot order,
  /// into [out] (up to [capacity] entries) and returns the element
  /// count. Introspection for hosts that key UI state by slot (the
  /// Dart engineOrder map, ES-531): slot i of the shared meter state
  /// belongs to the element whose id lands at out[i]. Control thread
  /// only, like add/remove — no concurrent mutation.
  uint32_t element_ids(uint32_t* out, uint32_t capacity) const;

  /// Open an IAMF file in Playback mode. Creates an IamfPlaybackSession
  /// and claims one element slot per supported Audio Element (each AE's
  /// audio_element_id becomes the slot id). No slots are claimed on
  /// failure.
  ///
  /// Returns the number of slots claimed (>0) on success, negative on
  /// error: -1 no room, -2 open failed / malformed, -3 no supported AEs.
  /// On error, last_iamf_error() carries the upstream-prefixed reason.
  ///
  /// Must be called from the control thread while the audio thread is
  /// not holding process() (i.e. paused or before start), because
  /// process() reads element_count_ and chain source pointers without
  /// locking.
  int32_t open_iamf(const char* path);

  /// Tear down the IAMF session and release every slot whose source
  /// is an IamfRingSource. Safe to call when no session is open.
  /// Compacts the element list so subsequent add_element / open_iamf
  /// starts at slot 0 again.
  void close_iamf();

  /// True while an IAMF playback session is active.
  bool has_iamf_session() const { return iamf_session_ != nullptr; }

  /// Raw access to the underlying session — null when no file is open.
  /// Used by the FFI layer to read descriptor info without duplicating
  /// it across the AudioGraph boundary. Do not retain across
  /// close_iamf() calls.
  IamfPlaybackSession* iamf_session() { return iamf_session_.get(); }

  /// Last upstream-prefixed error from open_iamf() / session seek / a
  /// mid-stream decode failure. Empty when no error is pending.
  const std::string& last_iamf_error() const;

  /// Write IDs of every currently-active IAMF-sourced element slot
  /// into `out` (up to `max_ids`); returns the count written. Used by
  /// the FFI layer to unregister slots from OAR before close_iamf()
  /// resets the chain state.
  uint32_t iamf_element_ids(uint32_t* out, uint32_t max_ids) const;

  void set_element_gain(uint32_t id, float gain_db);
  void set_element_mute(uint32_t id, bool muted);
  void set_element_solo(uint32_t id, bool solo);
  void set_element_mix_excluded(uint32_t id, bool excluded);
  void set_element_scene(uint32_t id, bool scene);

  /// Mark a chain object-based. While set, the audio thread pushes the
  /// chain's polar position(s) to OAR as constant-position metadata
  /// every callback — required for object audibility on loudspeaker
  /// layouts (see ElementControlState::is_object).
  void set_element_object(uint32_t id, bool object);

  /// Set an object element's polar position target(s). `count` is 1
  /// (mono) or 2 (dual); the second triplet is ignored for count == 1.
  /// Lock-free: the audio thread picks the values up next callback.
  void set_element_object_position(uint32_t id, uint32_t count, float az_deg,
                                   float el_deg, float dist, float az2_deg,
                                   float el2_deg, float dist2);

  /// Set per-element IAMF mix gain (passed to OAR as element metadata).
  /// This is the element_mix_gain from the active mix presentation,
  /// semantically distinct from set_element_gain() which controls the
  /// DSP-chain user gain. The audio thread slew-limits fast changes
  /// and emits a linear ramp to OAR each callback.
  void set_element_mix_gain(uint32_t id, float gain_db);

  /// Control whether the audio thread overwrites each IAMF chain's mix
  /// gain with the stream's per-TU `mix_gain_db_per_ae` every callback.
  /// The stream reports gains for the decoder's *default* mix
  /// presentation only (the streaming API has no mix selection —
  /// iamf-tools#23), so when the app selects a non-default presentation
  /// it disables this and drives set_element_mix_gain itself. Reset to
  /// enabled on every open_iamf(). Control thread writes, audio thread
  /// reads — lock-free.
  void set_iamf_stream_gains(bool enabled) {
    iamf_stream_gains_.store(enabled, std::memory_order_relaxed);
  }

  /// Current per-element mix gain target in dB (0 for an unknown id).
  /// Control-thread only; used by tests to observe whether the stream
  /// fan-out or an app-driven value won.
  float element_mix_gain_db(uint32_t id);

  /// Set the input channel routing map for an element. `map[dest] = src`
  /// where src is a WAV channel index (or -1 to silence that dest).
  /// Passing nullptr or len==0 clears to identity (no remap, fast path).
  /// Safe to call from the control thread during playback — publish is
  /// lock-free via double-buffered storage and release-store.
  void set_element_routing(uint32_t id, const int8_t* map, uint32_t len);

  /// Set output mix gain (master fader, passed to OAR as group metadata).
  /// Same slew-and-ramp semantics as set_element_mix_gain.
  void set_output_mix_gain(float gain_db);

  /// Seed the per-element mix gain to its steady-state value without
  /// a slew ramp. Safe to call only from the control thread while the
  /// audio thread is either stopped or outputting silence (transport
  /// paused). Used by session load so a freshly-opened session starts
  /// with its persisted gains applied immediately, not ramped up from
  /// zero — which would pre-play an audible dip.
  void seed_element_mix_gain(uint32_t id, float gain_db);

  /// Seed the output mix gain to its steady-state value without a
  /// slew ramp. Same constraints as seed_element_mix_gain.
  void seed_output_mix_gain(float gain_db);

  /// Monitor DIM (ES-629): a fixed -20 dB cut on the device buffer,
  /// applied after the OAR render, the limiter and the output meter and
  /// loudness taps, so it never reaches the mix, an export or a
  /// measurement and the meters keep reading the undimmed render. It
  /// covers program and calibration noise alike. Control thread
  /// writes; the audio thread ramps the gain over 15 ms each way.
  void set_monitor_dim(bool engaged);
  bool monitor_dim() const {
    return monitor_dim_.load(std::memory_order_relaxed);
  }

  /// Called from the audio thread — no allocation.
  /// Writes interleaved float32 output to `out` (frames * channels samples).
  void process(float* out, uint32_t frames, uint32_t channels);

  /// Pointer to the shared meter state (all elements + loudness).
  /// The audio thread writes; the Dart UI reads.
  EclipsaStudioMeterState* meter_state() { return &global_meter_state_; }

  /// Reposition every element chain to `frame_pos` (engine-rate
  /// frames). Both session types STAGE the seek for the audio thread
  /// (ES-473 for IAMF, ES-536 for WAV): it fades the program down
  /// (kSeekFadeSeconds), applies the seek RT-safely (session post for
  /// IAMF, reader reposition for WAV), holds muted until primed (IAMF
  /// waits for ~40 ms of refill; WAV completes in one block), then
  /// fades back in — replacing the old hard-edged silence gaps and
  /// butt-joint splices with click-free ramps. While paused, the
  /// paused hook applies the seek without the fade (nothing is
  /// audible). Control thread only.
  void seek(uint64_t frame_pos);

  /// Audio-thread hook for the paused transport branch, mirroring
  /// consume_pending_clip_clear(): process() (which runs the seek
  /// state machine) is skipped while paused, so a staged seek would
  /// otherwise sit unconsumed until the next play — and resume would
  /// start from the stale position. The output is already silent
  /// while paused, so the fade-out stage is skipped for both session
  /// types. IAMF: post immediately and enter the priming hold with
  /// the fade gain at zero, so a resume stays muted until the refill
  /// is primed, then fades in. WAV (ES-536): apply immediately and stay
  /// transparent (kIdle, gain 1) — no refill exists to hold for, no
  /// program needs burning at the target, and the transport fade-in
  /// already covers the resume edge (a priming hold here would only
  /// double-fade against it). Guarded by the paused-drain disarm gate
  /// — see the staging-protocol comment.
  void consume_pending_seek_paused();

  /// Audio-thread hook for the paused transport branch (ES-530): drains
  /// the OAR pipeline's held tail — the limiter's delay line
  /// plus, on binaural, the convolver state — one native-size block
  /// per paused callback until the zero-fed output decays below
  /// audibility. Without it, the last ~2 ms of the pre-stop program
  /// (and the binaural reverb tail) survive the pause and replay as a
  /// stale burst at the head of the resumed output — audible when a
  /// seek moved the playhead while paused. Draining across paused
  /// callbacks keeps the per-callback cost at one render; process()
  /// re-arms the drain for the next pause. Audio thread only, like
  /// the other paused-branch hooks.
  void drain_oar_tail_paused();

  /// True once the current pause's drain reached silence (or had
  /// nothing to drain). Exposed for tests, which mimic the paused
  /// branch by calling drain_oar_tail_paused() directly.
  bool oar_tail_drained() const { return oar_tail_drained_; }

  /// Gate for drain_oar_tail_paused(), mirroring the paused seek
  /// hook's disarm contract: control-thread barriers that mutate the
  /// chain array while paused (element remove, session open/close)
  /// must disarm, THEN wait for callback quiescence, THEN mutate —
  /// the paused callback keeps firing during the mutation and the
  /// drain iterates the chains. Re-arm after the mutation. A COUNT,
  /// not a flag, because barriers nest (playback_open's rollback runs
  /// the close barrier inside its own disarm scope).
  void disarm_paused_drain() {
    paused_drain_disarm_count_.fetch_add(1, std::memory_order_release);
  }
  void rearm_paused_drain() {
    paused_drain_disarm_count_.fetch_sub(1, std::memory_order_release);
  }

  /// Disarm the paused hook's IAMF routing BEFORE an open_iamf() /
  /// close_iamf() session swap; open_iamf() re-arms on success. The
  /// caller must disarm, THEN wait for the in-flight callback to
  /// return, THEN swap. Division of duties since ES-534: the
  /// memory-safety gate for everything the paused hooks touch
  /// (including this hook's session and staging fields) is the
  /// paused-drain disarm count, which every session/chain barrier
  /// holds via PausedDrainDisarmScope; this flag is the narrower
  /// "session fully constructed, no swap underway" signal that routes
  /// consume_pending_seek_paused() to its IAMF branch.
  void disarm_paused_seek_hook() {
    paused_seek_hook_armed_.store(false, std::memory_order_release);
  }

  /// Zero all meter state (peaks, RMS, holds, loudness, counters).
  /// When preserve_clips is true the sticky clip latches — element
  /// clip[] and output_clip_ — survive: overload markers must outlive
  /// a transport stop (ES-528); they are cleared only by the clip-clear
  /// paths or a full reset (mode switch, session load).
  void reset_meters(bool preserve_clips = false);

  /// Audio-thread only. If the control thread has raised the mix-bus
  /// loudness reconfigure fence, acknowledge it. Called from the paused
  /// transport branch, where process() — which posts the ack itself — does
  /// not run; without this a pause-time meter reset would stall on the
  /// fence's timeout. Mirrors OarRenderer::acknowledge_reconfiguring().
  /// See issue ES-145.
  void ack_loudness_reconfigure_if_pending() {
    // seq_cst: see the loudness fence members below.
    if (loudness_reconfiguring_.load(std::memory_order_seq_cst)) {
      loudness_ack_.fetch_add(1, std::memory_order_seq_cst);
    }
  }

  /// Set by AudioThread::start()/stop() to mark whether the device
  /// callback is firing. Lets the loudness fence skip its ack-wait when
  /// no callback is running (unit tests, paused-but-stopped device), where
  /// no concurrent access to the meter is possible.
  void set_audio_running(bool v) {
    audio_running_.store(v, std::memory_order_release);
  }

  /// Access the OAR renderer for configuration changes.
  /// Returns nullptr if not initialized.
  OarRenderer* oar_renderer() { return oar_renderer_.get(); }

  /// The mix-bus loudness meter, for inspection (tests). Its configuration
  /// is written only on the control thread, inside the loudness fence.
  /// Returns nullptr if not initialized.
  const LoudnessMeter* mix_loudness_meter() const {
    return mix_loudness_meter_.get();
  }

  /// Switch the OAR monitoring layout and reconfigure the mix-bus loudness
  /// meter for the new channel count and BS.1770 weights (the table in
  /// meters/bs1770_weights.cc, which the offline exporter also uses).
  /// Control-thread only. The loudness fence is raised before the OAR
  /// rebuild and lowered after the meter reconfigure, so the audio thread
  /// never feeds the meter a block from the new layout while it is still
  /// sized for the old one. While offline-exclusive mode is held the OAR
  /// rebuild is deferred and the meter keeps its old configuration until
  /// end_offline_exclusive() replays the rebuild.
  /// @returns false if OarRenderer::set_layout() fails.
  bool set_monitoring_layout(uint32_t layout);

  /// Release one offline-exclusive hold on the OAR renderer
  /// (OarRenderer::end_offline_exclusive()). When the release replays a
  /// deferred rebuild, the meter is resynced to the renderer's channel
  /// count and layout inside the same loudness fence as the replay.
  /// Control-thread only.
  /// @returns true when the release replayed a deferred rebuild.
  bool end_offline_exclusive();

  /// Reconfigure the mix-bus loudness meter if its channel count or layout
  /// no longer matches the OAR renderer. Call on the control thread after
  /// an OarRenderer rebuild that is not a layout switch (add_element,
  /// remove_element, commit_rendering_config, reinit_for_format). Such a
  /// rebuild keeps the channel count unless an earlier rebuild failed and
  /// left it at 0; this covers that case. In that case the renderer has
  /// already produced blocks at the new count before this call, so
  /// LoudnessMeter::process() skips and logs at least one mismatched block
  /// first. Returns without raising the loudness fence when the meter
  /// already matches.
  void resync_loudness_meter_if_stale();

  /// Set the per-OAR-channel device routing. `masks[oar_ch]` is a
  /// device-channel bitmask (bit `d` set = OAR channel `oar_ch` feeds device
  /// channel `d`; 0 = mute). `len` MUST equal the active OAR channel count;
  /// a mismatch is rejected so a stale-length push never partially applies.
  /// Control-thread only — serialised on routing_mutex_; the audio thread
  /// reads each mask lock-free. @returns 0 on success, -1 on size mismatch.
  int32_t set_routing(const uint64_t* masks, uint32_t len);

  /// Atomic layout + routing switch. Stores `masks` first (so they are live
  /// before the OAR rebuild) then applies `layout`; during the rebuild the
  /// audio thread skips rendering (OarRenderer::is_reconfiguring), so it
  /// never sees the new layout paired with the old routing. `len` is the new
  /// layout's device-channel-mask count. @returns 0 on success, -1 on error.
  int32_t set_layout_and_routing(uint32_t layout, const uint64_t* masks,
                                 uint32_t len);

  /// Set the single active pink-noise injection point. `mode`: 0=off,
  /// 1=row (pre-routing, `channel` indexes the active OAR output channel),
  /// 2=col (post-routing, `channel` indexes the device output channel).
  /// `amp` is the linear gain (10^(dbfs/20)); while a cell is lit the program
  /// is muted and the generator runs at this fixed level, bypassing the
  /// master fader. Control-thread only; published lock-free to the audio
  /// thread via a single packed atomic.
  void set_noise(uint8_t mode, uint32_t channel, float amp);

  /// True while a calibration noise cell is lit (mode != off). Read from the
  /// audio thread so the paused-transport branch can keep injecting noise.
  bool noise_active() const {
    return (noise_.load(std::memory_order_relaxed) & 0xFFu) != 0;
  }

  /// Render ONLY the calibration noise into `out` — no element reads, no
  /// transport advance, no OAR render. Used by the audio thread while
  /// transport is paused so pink-noise speaker calibration works without
  /// playback. Updates the output peak meter so the level stays visible.
  /// Audio-thread only; no allocation. `out` is fully overwritten.
  void render_noise(float* out, uint32_t frames, uint32_t channels);

  /// When true, bypass OAR and route the first 2 channels of each element
  /// directly to the output (summed to stereo).  For debugging audio issues.
  void set_bypass_oar(bool v) {
    bypass_oar_.store(v, std::memory_order_relaxed);
  }
  bool bypass_oar() const {
    return bypass_oar_.load(std::memory_order_relaxed);
  }

  /// Enable/disable the visualizer channel-stats pass. Default off —
  /// the audio thread skips the whole ChannelStats::process() call
  /// when disabled, so inactive visualizers cost nothing in the
  /// real-time path. An off->on transition resets the accumulated
  /// stats state so re-enabling doesn't briefly show stale readings.
  void set_channel_stats_enabled(bool enabled);

 private:
  ElementChain* find_element(uint32_t id);

  /// Audio-thread only. Record an IAMF ring starvation event (a short
  /// read with no EOF) into the shared meter state and emit a
  /// throttled rt-safe log so the drop is visible in stderr / JSONL.
  void note_ring_underrun(uint32_t element_index, uint32_t missing);

  uint32_t sample_rate_ = 48000;
  uint32_t max_frames_ = 512;
  uint32_t channels_ = 2;
  bool initialized_ = false;
  uint64_t process_call_count_ = 0;  // Audio-thread only.
  // Latches the one-shot warning for a device buffer larger than the
  // pre-allocated kGraphMaxFrames. Audio-thread only.
  bool frames_clamped_warned_ = false;

  // ── OAR tail drain state (ES-530) ────────────────────────────────────
  // Written by drain_oar_tail_paused() (the audio thread's paused
  // branch) and re-armed at the top of process(); audio-thread only.
  bool oar_tail_drained_ = false;
  uint32_t oar_drain_blocks_done_ = 0;
  // Cross-thread gate — see disarm_paused_drain().
  std::atomic<int> paused_drain_disarm_count_{0};
  // Drain termination: output peak below this counts as silent
  // (-120 dBFS); the block cap is a logged backstop, sized for a
  // multi-second binaural convolution tail at small buffers.
  static constexpr float kOarDrainSilenceEps = 1e-6f;
  static constexpr uint32_t kOarDrainMaxBlocks = 4096;

  std::array<ElementChain, kGraphMaxElements> elements_ = {};
  std::atomic<uint32_t> element_count_{0};

  // Single shared meter state for all elements + mix bus loudness.
  // Written by the audio thread; Dart reads via
  // eclipsa_studio_get_meter_state().
  EclipsaStudioMeterState global_meter_state_ = {};

  // Mix bus loudness meter (writes to global_meter_state_.loudness).
  std::unique_ptr<LoudnessMeter> mix_loudness_meter_;

  // ── Mix-bus loudness reconfigure fence (issue ES-145) ──────────────────
  // LoudnessMeter::reset()/reconfigure() free and reallocate the backing
  // EbuR128Analyzer (it has no in-place reset). Those run on the control
  // thread while the audio thread may be inside LoudnessMeter::process()
  // (called from process() below) — a use-after-free. Mirror the
  // OarRenderer reconfiguring_/ack_counter_ handshake: the control thread
  // raises loudness_reconfiguring_ and spin-waits until the audio thread
  // acknowledges (it skips the meter and bumps loudness_ack_) before
  // rebuilding the analyzer, then lowers the flag.
  //
  // The raise (store true), the control thread's ack snapshot and wait
  // loads, and the audio thread's flag load and ack increment are all
  // seq_cst. With release/acquire, the control thread's load of
  // loudness_ack_ could be ordered before its store of the flag (a
  // store-load reorder), so the snapshot could predate the raise and an
  // ack posted by a callback that had not observed the raise could end
  // the wait while that callback was still inside the meter. In the
  // single seq_cst order the raise precedes the snapshot, so every ack
  // counted after it comes from a callback that loaded the raised flag
  // and skipped the meter. Lowering the flag stays a release store.
  std::atomic<bool> loudness_reconfiguring_{false};
  std::atomic<uint64_t> loudness_ack_{0};
  std::atomic<bool> audio_running_{false};

  // Control-thread only. Raise the loudness fence, wait for the audio
  // thread to leave LoudnessMeter::process(), run `fn` (which rebuilds the
  // analyzer), then lower the fence. `fn` therefore frees/reallocates the
  // analyzer with the audio thread provably outside it. See issue ES-145.
  template <typename Fn>
  void with_loudness_fenced(Fn&& fn) {
    loudness_reconfiguring_.store(true, std::memory_order_seq_cst);
    wait_for_loudness_ack();
    fn();
    loudness_reconfiguring_.store(false, std::memory_order_release);
  }
  void wait_for_loudness_ack();

  // Control-thread only. Runs `change` (an OarRenderer reconfiguration
  // returning bool) inside the loudness fence, then resyncs the meter to
  // the renderer before the fence drops. Ordering: the fence is raised and
  // acknowledged first, so the audio thread is outside
  // LoudnessMeter::process() and stays out while OAR rebuilds and
  // publishes its new channel count; the meter is reconfigured for that
  // count; only then is the fence lowered (release), and the audio
  // thread's acquire load of the flag makes the rebuilt analyzer visible
  // before its next process() call. Shared by set_monitoring_layout() and
  // end_offline_exclusive() (issue ES-833).
  template <typename Fn>
  bool change_oar_loudness_fenced(Fn&& change, bool force_meter_reconfigure) {
    if (!mix_loudness_meter_) return change();
    bool ok = false;
    with_loudness_fenced([&] {
      ok = change();
      if (ok) resync_loudness_meter_locked(force_meter_reconfigure);
    });
    return ok;
  }

  // Reconfigure the loudness meter for the OAR renderer's current channel
  // count and layout. Caller holds the loudness fence. Skipped while
  // offline-exclusive mode is held (the rebuild is deferred, so
  // channel_count() is still the old count) and when the renderer has no
  // output channels. Unless `force`, also skipped when the meter already
  // matches, so a deferred element-only rebuild keeps the accumulated
  // integrated loudness.
  void resync_loudness_meter_locked(bool force);

  // True when the meter's channel count and layout match the renderer's.
  // Control-thread only.
  bool loudness_meter_matches_oar() const;

  // OAR renderer (single instance — layout switch reconfigures it).
  std::unique_ptr<OarRenderer> oar_renderer_;

  // When set, bypass OAR and sum element channels 0-1 directly to output.
  std::atomic<bool> bypass_oar_{false};

  // Gate for the visualizer channel-stats pass. Off by default — the
  // UI flips it on when any channel-viz module is enabled.
  std::atomic<bool> channel_stats_enabled_{false};

  // Per-OAR-channel device-channel routing. routing_[oar_ch] bit d set =
  // OAR channel oar_ch feeds device channel d; 0 = mute. One uint64_t spans
  // the full 64-device-channel range. Defaults to identity (1<<i) so an
  // un-pushed graph reproduces the flat 1:1 copy exactly. Written from the
  // control thread under routing_mutex_; read lock-free on the audio thread.
  static constexpr uint32_t kMaxRoutingChannels = 64;  // matches OAR + Dart
  std::array<std::atomic<uint64_t>, kMaxRoutingChannels> routing_{};
  std::mutex routing_mutex_;  // control-thread only (serialises set_routing).

  // Single active pink-noise injection, published as one packed atomic so the
  // audio thread reads a consistent (mode, channel, amp) triple with no torn
  // view. Layout: bits[0,8) mode, bits[8,32) channel, bits[32,64) amp as the
  // IEEE-754 float bit-pattern. 0 == off. See pack/unpack helpers in the .cc.
  std::atomic<uint64_t> noise_{0};
  dsp::PinkNoise noise_gen_;  // audio-thread only.
  // Audio-thread scratch for one block of generated noise (avoids a large
  // stack array in process()); written then scattered each callback.
  float noise_storage_[kGraphMaxFrames] = {};

  // When Playback mode is active, owns the stream feeding every
  // iamf_ring_source in the element_ array. Null in Creator mode.
  std::unique_ptr<IamfPlaybackSession> iamf_session_;
  std::string iamf_error_;

  // ── Seek de-click: mute-until-primed (ES-473, WAV since ES-536) ───────
  // A seek used to go straight to the source from the control thread;
  // for IAMF the ring then came up short until the decoder refilled
  // (a hard step to silence and back per underrun), and for both
  // session types the seek point itself was a butt-joint splice.
  // Instead, seek() stages the request here and the audio thread runs
  // a small state machine: fade the program out (kSeekFadeSeconds),
  // apply the seek RT-safely, hold muted until primed, then fade back
  // in. IAMF holds with ring reads SKIPPED until the refill lands;
  // WAV repositions instantly (WavReader::seek is a cursor
  // assignment), so its hold lasts exactly one block and its reads
  // continue (muted) to keep the reader tracking the transport.
  //
  // Staging protocol — NOTE the dual units: the control thread stores
  // the position, then bumps the count; for an IAMF session the value
  // is FILE-rate and pre-clamped, for a WAV session it is ENGINE-rate
  // and unclamped (WavReader::seek clamps downstream). The branch in
  // post_staged_seek_rt() resolves the unit by session presence, so a
  // staged pair is only meaningful for the session type that staged
  // it — close_iamf() clears the staging unconditionally (even with
  // no session attached) so a pair can never cross a session swap.
  // The audio thread loads count first, then position — a torn pair
  // can only post a FRESHER position with a stale count, which the
  // next block re-posts identically (idempotent). All other fields
  // are audio-thread only.
  //
  // paused_seek_hook_armed_ is NOT the hook's memory-safety gate any
  // more — that is the paused-drain disarm count, which every
  // session/chain barrier holds (ES-534). It survives as the "a fully
  // constructed session is attached and no swap is underway" signal
  // that routes the paused hook to its IAMF branch. See
  // disarm_paused_seek_hook() for the teardown protocol.
  std::atomic<bool> paused_seek_hook_armed_{false};
  std::atomic<uint64_t> pending_seek_file_pos_{0};
  std::atomic<uint32_t> pending_seek_count_{0};
  uint32_t pending_seek_consumed_ = 0;  // audio-thread only
  enum class SeekMuteState : uint8_t {
    kIdle,     // fade gain at (or ramping back to) unity
    kFadeOut,  // ramping to silence; post the seek once silent
    kPriming,  // muted, reads skipped, waiting for post-seek refill
  };
  SeekMuteState seek_mute_state_ = SeekMuteState::kIdle;  // audio thread
  // Linear fade applied to every chain's buffer; g0/g1 bracket the
  // current block (same ramp shape as OarRenderer::fade_block).
  float seek_fade_gain_ = 1.0f;  // audio-thread only
  float seek_fade_g0_ = 1.0f;    // audio-thread only
  float seek_fade_g1_ = 1.0f;    // audio-thread only
  // Session request count captured when the audio thread posts, so
  // the prime check can require the I/O thread to have APPLIED the
  // seek (discard floors published) before trusting buffered_frames —
  // otherwise the stale pre-seek backlog reads as "primed".
  uint64_t seek_posted_request_count_ = 0;  // audio-thread only
  // Engine-rate frames spent in the current priming hold; reset on
  // every post. Drives the kSeekPrimeTimeoutSeconds watchdog.
  uint32_t seek_prime_hold_frames_ = 0;  // audio-thread only
  /// Fade length: 10 ms nominal, matching the transport edge fades
  /// (kTransportFadeOutMs, ES-530/ES-536). Precisely: the per-BLOCK step
  /// is frames/(fade·rate), so the effective fade is max(10 ms, one
  /// block) — 21/43 ms at 1024/2048-frame buffers — unlike the
  /// transport fade, whose gain persists across callbacks and is
  /// exactly 10 ms everywhere. Long enough to kill the discontinuity,
  /// short enough to be imperceptible as a fade. Note the WAV seek's
  /// one-block hold also leaves the reader one block behind the
  /// free-running transport counter — fixed and non-cumulative, like
  /// the IAMF prime-hold offset described at kSeekPrimeFrames.
  static constexpr float kSeekFadeSeconds = 0.010f;
  /// Post-seek refill (file-rate frames) required before fading back
  /// in. ~43 ms at 48 kHz — inside the issue's 20-50 ms window, and
  /// several device blocks of cushion against an immediate
  /// re-underrun. Tuned by ear (ES-473 QC): 1024 frames plus a longer
  /// 80 ms coalesce interval was tried and sounded WORSE — shorter
  /// bursts arriving sooner read as harsher chatter than this
  /// setting's fewer, steadier windows. Note the hold also defers the
  /// audio program behind the transport counter (which keeps
  /// advancing) by the hold duration — a fixed ~20-60 ms offset per
  /// seek, comparable to the pre-ES-473 underrun gap, not cumulative.
  static constexpr uint32_t kSeekPrimeFrames = 2048;
  /// Watchdog on the priming hold. iamf_rings_primed() requires EVERY
  /// attached ring to reach the threshold or EOF — but a ring can
  /// starve indefinitely without EOF (e.g. the ES-238 partial-temporal-
  /// unit case, where one AE's ring gets nothing until a re-seek), and
  /// because the hold also skips reads, the healthy rings stay full
  /// and park the pump. Without a bound that turns a one-element
  /// dropout into a permanent whole-mix mute. On timeout, give up and
  /// fade back in unprimed: the starved element degrades to the old
  /// behaviour (underruns, counted and logged) while the rest play.
  static constexpr float kSeekPrimeTimeoutSeconds = 0.25f;
  /// Audio-thread: advance the state machine and compute this block's
  /// fade bracket. Called at the top of process().
  void update_seek_mute_state(uint32_t frames);
  /// Audio-thread: reposition every WAV chain to the staged
  /// engine-rate position (per-chain rate conversion) (ES-536).
  void apply_wav_seek_rt(uint64_t engine_frame_pos);
  /// Audio-thread: apply the staged seek — IAMF posts to the session,
  /// WAV goes through apply_wav_seek_rt() — then drop every chain's
  /// resampler history.
  void post_staged_seek_rt();
  /// Audio-thread: true when every attached IAMF ring has the seek
  /// applied and either kSeekPrimeFrames buffered or EOF.
  bool iamf_rings_primed() const;

  // When true (the default), process() feeds each IAMF chain's mix
  // gain from the stream's per-TU report (default-presentation gains).
  // See set_iamf_stream_gains().
  std::atomic<bool> iamf_stream_gains_{true};

  // IAMF output mix gain target (master fader). Control thread writes,
  // audio thread reads each callback and produces a slew-limited
  // linear ramp to OAR via oar_update_metadata on group 0. Same
  // mechanism as per-element mix gain above.
  std::atomic<float> output_mix_gain_db_{0.0f};
  // Audio-thread only — slew-limited target and last value sent.
  float output_mix_gain_slewed_db_ = 0.0f;
  float output_mix_gain_last_sent_db_ = 0.0f;

  // Monitor DIM (ES-629): control thread writes the target, the audio
  // thread ramps monitor_dim_gain_ (linear, 1.0 undimmed) toward it.
  std::atomic<bool> monitor_dim_{false};
  float monitor_dim_gain_ = 1.0f;

  /// Multiplies the device buffer by the DIM gain, ramping toward the
  /// target. Audio thread only; the last step of process() and
  /// render_noise(), after every meter tap.
  void apply_monitor_dim(float* out, uint32_t frames, uint32_t channels);

  // Output peak and RMS levels (written after OAR render, read by Dart
  // via FFI). RMS is a per-sample EMA of the squared signal so the UI
  // can draw smoothed bars from the same tap as the peaks.
  //
  // kMeterRmsWindowMs is the integration time for BOTH the per-element
  // RmsMeter instances and the output bus. 50 ms is a deliberately
  // fast attack (~115 ms to 90% of a step); the UI clamps the fall to
  // its own release rate, so the display is smooth-but-responsive
  // rather than full 300 ms VU ballistics.
  // RelaxedAtomic: the audio thread writes these each block while the
  // control thread reads them (get_output_*) and zeroes them in
  // reset_meters() / clear_clips_now() (see meter_state.h).
  static constexpr uint32_t kMaxOutputChannels = 32;
  static constexpr float kMeterRmsWindowMs = 50.0f;
  RelaxedAtomic<float> output_peaks_[kMaxOutputChannels] = {};
  RelaxedAtomic<float> output_rms_sq_[kMaxOutputChannels] =
      {};  // EMA state (audio thread)
  RelaxedAtomic<float> output_rms_[kMaxOutputChannels] =
      {};  // published sqrt values
  RelaxedAtomic<uint8_t> output_clip_[kMaxOutputChannels] =
      {};  // sticky, >= 0 dBFS
  float output_rms_alpha_ = 0.0f;
  uint32_t output_channel_count_ = 0;

  // Clip-clear handshake. The audio thread is the sole writer of the
  // clip flags (per-element clip[] and output_clip_), so a clear
  // during playback is requested here and performed by the audio
  // thread itself at the top of the next process() — no cross-thread
  // write-write race. While the callback is quiescent the control
  // thread may call clear_clips_now() directly.
  std::atomic<bool> clip_clear_requested_{false};

  void update_output_rms_alpha();
  void meter_output_channel(const float* samples, uint32_t frames,
                            uint32_t stride, uint32_t channel);

 public:
  /// Read current output peak levels.
  uint32_t get_output_peaks(float* out, uint32_t max_ch) const;

  /// Read current output RMS levels (kMeterRmsWindowMs integration).
  uint32_t get_output_rms(float* out, uint32_t max_ch) const;

  /// Read the sticky per-output-channel clip flags (latched at
  /// >= 0 dBFS by the audio thread; cleared via the clip-clear paths).
  uint32_t get_output_clips(uint8_t* out, uint32_t max_ch) const;

  /// Ask the audio thread to clear all sticky clip flags on its next
  /// callback. Safe from any thread at any time.
  void request_clip_clear();

  /// Audio-thread only: perform a pending requested clip clear, if
  /// any. Called from process() and from the callback's paused branch
  /// so a request is never stranded by a pause/EOF.
  void consume_pending_clip_clear();

  /// Clear all sticky clip flags immediately. Caller must guarantee the
  /// audio callback is quiescent (same contract as reset_meters()).
  void clear_clips_now();
};

#endif  // ECLIPSA_STUDIO_GRAPH_AUDIO_GRAPH_H_
