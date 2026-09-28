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

#ifndef ECLIPSA_STUDIO_METERS_METER_STATE_H_
#define ECLIPSA_STUDIO_METERS_METER_STATE_H_

#include <atomic>
#include <cstddef>
#include <cstdint>

/// A T-sized cell accessed with relaxed atomic loads/stores.
///
/// The shared meter state is written by the audio thread and read by the
/// Dart UI over FFI without synchronization; control-thread meter resets
/// and clip clears additionally write the same fields (under a
/// callback-quiescence contract for resets — see reset_meters()).
/// Relaxed atomics give every such access defined behavior — and keep
/// TSan quiet where tests deliberately race reset against process() —
/// at zero audio-thread cost: a relaxed load/store compiles to the same
/// plain move as the raw field on arm64 and x86-64.
///
/// Reads and writes convert implicitly, so `cell = v` / `float x = cell`
/// work unchanged. Compound updates (`+=`, `++`) are load-then-store,
/// not atomic RMW — fine here because every counter has a single writer.
/// Layout is asserted below to match the wrapped T exactly, so the Dart
/// FFI struct mirrors are unaffected.
template <typename T>
class RelaxedAtomic {
 public:
  RelaxedAtomic() = default;
  explicit RelaxedAtomic(T v) : v_(v) {}
  RelaxedAtomic(const RelaxedAtomic& other) : v_(other.load()) {}
  RelaxedAtomic& operator=(const RelaxedAtomic& other) {
    store(other.load());
    return *this;
  }
  RelaxedAtomic& operator=(T v) {
    store(v);
    return *this;
  }
  // Implicit by design: reads must stay spelled like the raw field.
  operator T() const { return load(); }  // NOLINT(google-explicit-constructor)
  RelaxedAtomic& operator+=(T d) {
    store(load() + d);
    return *this;
  }
  RelaxedAtomic& operator++() { return *this += T{1}; }

 private:
  T load() const { return v_.load(std::memory_order_relaxed); }
  void store(T v) { v_.store(v, std::memory_order_relaxed); }
  std::atomic<T> v_{};
};

// The FFI contract: a RelaxedAtomic<T> occupies exactly a T and its
// atomic ops never fall back to a lock (which would both break the
// layout promise and be audio-thread-hostile).
static_assert(sizeof(RelaxedAtomic<float>) == sizeof(float) &&
                  alignof(RelaxedAtomic<float>) == alignof(float) &&
                  std::atomic<float>::is_always_lock_free,
              "RelaxedAtomic<float> must be layout-identical to float");
static_assert(sizeof(RelaxedAtomic<uint8_t>) == sizeof(uint8_t) &&
                  alignof(RelaxedAtomic<uint8_t>) == alignof(uint8_t) &&
                  std::atomic<uint8_t>::is_always_lock_free,
              "RelaxedAtomic<uint8_t> must be layout-identical to uint8_t");
static_assert(sizeof(RelaxedAtomic<uint32_t>) == sizeof(uint32_t) &&
                  alignof(RelaxedAtomic<uint32_t>) == alignof(uint32_t) &&
                  std::atomic<uint32_t>::is_always_lock_free,
              "RelaxedAtomic<uint32_t> must be layout-identical to uint32_t");
static_assert(sizeof(RelaxedAtomic<uint64_t>) == sizeof(uint64_t) &&
                  alignof(RelaxedAtomic<uint64_t>) == alignof(uint64_t) &&
                  std::atomic<uint64_t>::is_always_lock_free,
              "RelaxedAtomic<uint64_t> must be layout-identical to uint64_t");

/// Maximum audio elements and channels per element.
/// Must match ECLIPSA_STUDIO_MAX_* in eclipsa_studio_engine.h — these values
/// define the Dart FFI struct layout, which is fixed at compile time.
static constexpr uint32_t kEclipsaStudioMaxElements = 28;
static constexpr uint32_t kEclipsaStudioMaxChannelsPerElement = 28;

/// Convenience alias used by meter implementations.
static constexpr uint32_t kMeterMaxChannels =
    kEclipsaStudioMaxChannelsPerElement;

/// Max channels for which we track pairwise correlation. 7.1.4 = 12
/// channels (66 pairs); 22.2 = 24 (276 pairs). Capped at 16 to bound
/// per-block CPU — ALL current channel-based IAMF layouts fit.
static constexpr uint32_t kStatsCorrMaxChannels = 16;

/// Packed upper-triangular pair count: N*(N-1)/2.
static constexpr uint32_t kStatsCorrPairs =
    kStatsCorrMaxChannels * (kStatsCorrMaxChannels - 1) / 2;  // 120

/// Per-element meter data.
///
/// Layout mirrors EclipsaStudioMeterData in eclipsa_studio_engine.h
/// byte-for-byte so the audio thread can write directly into the struct that
/// Dart reads. All values are LINEAR amplitudes (0..1+), NOT dBFS.
///
/// The peak/RMS fields are RelaxedAtomic because a control-thread meter
/// reset (and clip clear) writes them while the audio thread's meters do;
/// the stats block below stays plain — it has a single writer (the audio
/// thread) and resets never touch it.
struct EclipsaStudioMeterData {
  RelaxedAtomic<uint32_t> channel_count;  ///< Active channels
  RelaxedAtomic<float> peak[kEclipsaStudioMaxChannelsPerElement] =
      {};  ///< Instantaneous peak (linear)
  RelaxedAtomic<float> rms[kEclipsaStudioMaxChannelsPerElement] =
      {};  ///< RMS level (linear)
  RelaxedAtomic<float> peak_hold[kEclipsaStudioMaxChannelsPerElement] =
      {};  ///< Peak hold value (linear)
  RelaxedAtomic<uint8_t> clip[kEclipsaStudioMaxChannelsPerElement] =
      {};  ///< Clip flags (1 = clipped)

  /// SH active intensity snapshot — mean(W * ch_c) per channel.
  /// For scene-based (ambisonic) elements: ch[0] = energy (W*W),
  /// ch[c>0] = signed correlation with W (preserves spatial direction).
  /// For non-ambisonic elements: W = ch[0], so this degenerates to
  /// cross-channel correlation with the first channel.
  /// Written by the audio thread each process() call.
  float sh_snapshot[kEclipsaStudioMaxChannelsPerElement] = {};

  // ── Channel stats block (visualizer inputs) ───────────────────────
  //
  // All values are computed on the audio thread once per process() call
  // with fixed EMA time constants (see channel_stats.cc). Zero initialised
  // means "no signal" — readers should treat a zeroed block as inactive.

  /// Short-window energy per channel (linear power, EMA-smoothed).
  float stats_energy[kEclipsaStudioMaxChannelsPerElement] = {};

  /// Three-band coherence against the element sum (lo/mid/hi, |γ|² in 0..1).
  float stats_coh_lo[kEclipsaStudioMaxChannelsPerElement] = {};
  float stats_coh_mid[kEclipsaStudioMaxChannelsPerElement] = {};
  float stats_coh_hi[kEclipsaStudioMaxChannelsPerElement] = {};

  /// Transient onset flag per channel (1 = onset detected within hold
  /// window, 0 = quiescent). Sticky for ~80 ms after detection.
  uint8_t stats_onset[kEclipsaStudioMaxChannelsPerElement] = {};

  /// Reserved fill — stats_corr is already 4-byte aligned without it,
  /// but the field is baked into the ABI (sizeof == 1440, mirrored by
  /// the Dart FFI struct) and must stay.
  uint8_t stats_pad_[4] = {};

  /// Upper-triangular pairwise Pearson correlation. Packed in row-major:
  /// for i<j<N, index = i*(2N-i-1)/2 + (j-i-1) with N=kStatsCorrMaxChannels.
  /// Values ∈ [-1, +1]. Only pairs within the element's active channel
  /// count (up to kStatsCorrMaxChannels) are updated; others remain 0.
  float stats_corr[kStatsCorrPairs] = {};
};

/// Master bus loudness data.
struct EclipsaStudioLoudnessData {
  float lufs_momentary = -120.0f;   ///< Momentary loudness (400 ms window)
  float lufs_short_term = -120.0f;  ///< Short-term loudness (3 s window)
  float lufs_integrated = -120.0f;  ///< Integrated loudness (programme)
  float true_peak = -100.0f;        ///< True peak across all channels (dBTP)
};

/// Shared meter state — written by the audio thread, read by Dart via FFI.
///
/// The compiler inserts 4 bytes of padding between element_count (uint32_t)
/// and frame_counter (uint64_t); the Dart FFI struct does the same.
///
/// The scalar counters and health/diagnostic fields below are written by
/// the audio thread and read concurrently (by Dart, and by tests on the
/// control thread), so they are RelaxedAtomic — same codegen as a plain
/// aligned store on 64-bit platforms, but a defined data race for
/// TSan/UBSan and any future platform. The bulk meter arrays and
/// loudness block stay plain: they're single-writer advisory data
/// repainted every frame, and wrapping whole float arrays would be
/// invasive for no observable benefit.
///
/// Snapshot consistency across FIELDS is deliberately best-effort: there
/// is no release/acquire pairing between the per-element writes and the
/// frame_counter increment, so a reader may see counter == N while some
/// fields still hold frame N-1 values. Meter/viz data is advisory and
/// repainted every frame, so a one-frame mix is acceptable; a seqlock-
/// style double-read of frame_counter around the copy is the upgrade
/// path if that ever stops being true.
struct EclipsaStudioMeterState {
  uint32_t element_count = 0;             ///< Active element count
  RelaxedAtomic<uint64_t> frame_counter;  ///< Incremented per process() call
  EclipsaStudioMeterData elements[kEclipsaStudioMaxElements] =
      {};                                   ///< Per-element readings
  EclipsaStudioLoudnessData loudness = {};  ///< Mix bus loudness

  /// Limiter gain reduction (linear). 1.0 = no reduction; below 1.0 =
  /// active limiting. Written by audio thread after oar_render().
  float limiter_gr = 1.0f;

  /// Audio thread CPU load as a fraction (0.0 = idle, 1.0 = 100%).
  /// Exponentially smoothed in the audio callback.
  RelaxedAtomic<float> audio_cpu_load;

  // ── Audio-thread health counters ──────────────────────────────────
  //
  // Per-callback events are far too frequent to log individually (even
  // via the lock-free log ring), so diagnostic info is surfaced here as
  // plain counters instead and picked up by the Dart tick loop, which
  // logs changes to the normal pipeline.
  RelaxedAtomic<uint64_t> audio_callback_count;  ///< data_callback calls
  RelaxedAtomic<uint64_t> audio_dropout_count;   ///< Buffers lost (delivery
                                                 ///< fell behind the device)
  RelaxedAtomic<uint64_t> audio_overrun_count;   ///< Callback overran slot

  /// Most recent dropout details — overwritten each event; reader pairs
  /// these with a delta on audio_dropout_count to know when they changed.
  RelaxedAtomic<uint64_t> last_dropout_cb;      ///< callback_count at event
  RelaxedAtomic<float> last_dropout_behind_ms;  ///< Deficit behind schedule
  RelaxedAtomic<float> last_dropout_period_ms;  ///< Expected period

  /// Most recent overrun details.
  RelaxedAtomic<uint64_t> last_overrun_cb;
  RelaxedAtomic<float> last_overrun_elapsed_ms;  ///< Process time
  RelaxedAtomic<float> last_overrun_period_ms;   ///< Expected period

  // ── IAMF ring underruns ───────────────────────────────────────────
  //
  // The audio thread asked an element's PcmRing for more frames than
  // were buffered while the producer had not signalled EOF — the
  // decode pump fell behind and the shortfall played as silence.
  // EOF short reads are expected drain behaviour and are not counted.
  RelaxedAtomic<uint64_t> ring_underrun_count;   ///< Short-read events
  RelaxedAtomic<uint64_t> ring_underrun_frames;  ///< Total frames shorted

  /// Most recent underrun details — same delta-pairing contract as
  /// the dropout/overrun blocks above.
  RelaxedAtomic<uint32_t> last_underrun_element;  ///< Slot of last event
  RelaxedAtomic<uint32_t> last_underrun_missing;  ///< Frames missing
};

// Sizes must match the Dart FFI struct mirrors exactly.
static_assert(sizeof(EclipsaStudioMeterData) == 1440,
              "EclipsaStudioMeterData size mismatch with Dart FFI mirror");
static_assert(sizeof(EclipsaStudioLoudnessData) == 16,
              "EclipsaStudioLoudnessData size mismatch with Dart FFI mirror");
static_assert(
    offsetof(EclipsaStudioMeterState, frame_counter) == 8,
    "EclipsaStudioMeterState padding mismatch — Dart expects 4 B gap");
// Diagnostic field offsets — the Dart FFI mirror in ffi_bridge.dart
// reorders fields silently (sizeof() alone cannot catch it), so pin
// these offsets explicitly.
static_assert(offsetof(EclipsaStudioMeterState, last_dropout_behind_ms) ==
                  offsetof(EclipsaStudioMeterState, last_dropout_cb) + 8,
              "last_dropout_behind_ms must follow last_dropout_cb");
static_assert(offsetof(EclipsaStudioMeterState, last_overrun_cb) ==
                  offsetof(EclipsaStudioMeterState, last_dropout_period_ms) + 4,
              "last_overrun_cb must follow last_dropout_period_ms");
static_assert(offsetof(EclipsaStudioMeterState, ring_underrun_count) ==
                  offsetof(EclipsaStudioMeterState, last_overrun_period_ms) + 4,
              "ring_underrun_count must follow last_overrun_period_ms");
static_assert(sizeof(EclipsaStudioMeterState) == 40440,
              "EclipsaStudioMeterState size changed — update Dart FFI mirror");

#endif  // ECLIPSA_STUDIO_METERS_METER_STATE_H_
