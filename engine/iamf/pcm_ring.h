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

#ifndef ECLIPSA_STUDIO_IAMF_PCM_RING_H_
#define ECLIPSA_STUDIO_IAMF_PCM_RING_H_

#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

#include "graph/audio_buffer.h"

/// Single-producer / single-consumer lock-free ring for interleaved
/// PCM frames. Used by `IamfPlaybackSession` to hand decoded audio
/// from the I/O thread to the audio thread without blocking either.
///
/// Storage layout: interleaved by `channels()`. Frame `f` channel `c`
/// lives at `buf_[(f & mask_) * channels_ + c]`. Reads convert to the
/// caller's planar `AudioBuffer` on the way out.
///
/// Indexing uses 64-bit monotonic counters `head_` (producer) and
/// `tail_` (consumer); the low bits index into a power-of-two-sized
/// buffer via `mask_`. Both counters are never reset.
///
/// Seek discard: the producer publishes a `discard_to_` value when
/// the upstream stream is repositioned. The consumer's next read
/// advances `tail_` to that value before serving frames, skipping
/// the now-stale pre-seek samples without breaking the
/// "tail is consumer-write-only" invariant.
class PcmRing {
 public:
  PcmRing() = default;

  PcmRing(const PcmRing&) = delete;
  PcmRing& operator=(const PcmRing&) = delete;

  /// Configure the ring. Must be called before any read/write.
  /// `capacity_frames` is rounded up to the next power of two so
  /// wrap-around uses a mask. Resets head/tail/discard counters.
  void configure(uint32_t channels, uint32_t capacity_frames) {
    channels_ = channels;
    uint32_t cap = 1;
    while (cap < capacity_frames) cap <<= 1;
    capacity_ = cap;
    mask_ = cap - 1;
    buf_.assign(static_cast<size_t>(cap) * channels_, 0.0f);
    head_.store(0, std::memory_order_relaxed);
    tail_.store(0, std::memory_order_relaxed);
    discard_to_.store(0, std::memory_order_relaxed);
    in_read_.store(false, std::memory_order_relaxed);
    eof_.store(false, std::memory_order_relaxed);
  }

  uint32_t channels() const { return channels_; }
  uint32_t capacity() const { return capacity_; }

  /// Producer-side (or any thread as a diagnostic observer): how many
  /// frames can still be written. Clamps to capacity if a discard has
  /// advanced the effective tail past `head_`.
  ///
  /// NOT monotonic between producer actions: while a read is in
  /// flight (`in_read_`), the result falls back to the plain `tail_`
  /// and can be SMALLER than a value returned moments earlier that
  /// counted the discard floor. The divergence is bounded to floors
  /// published during that same read (see read_planar(): the floor
  /// known at read entry is applied to `tail_` before the guard is
  /// raised) — and such floors were never counted by an earlier call
  /// either, so a value observed with no read in flight can only
  /// grow until the producer's own next publish_discard_to().
  ///
  /// Honors a published-but-not-yet-applied discard floor: the consumer
  /// jumps `tail_` to `discard_to_` before its next read, so the
  /// producer may reclaim `[.., discard_to_)` *now* instead of waiting
  /// for the consumer to advance `tail_`. Without this, a seek (which
  /// sets `discard_to_ == head_pos()`) leaves the producer seeing a
  /// stale-full ring until the consumer happens to read, stalling the
  /// post-seek refill — and, with a sibling ring still full, wedging
  /// the all-rings pump gate so a starved ring never refills (ES-238).
  ///
  /// The floor is counted as free ONLY while no read is in flight: a
  /// consumer inside read_planar() may be copying from above its
  /// applied tail, and once the ring has wrapped, writing into the
  /// "reclaimed" region overwrites the very slots that copy is
  /// reading (a data race, and audible garbage). The seq_cst pairing
  /// with read_planar()'s `in_read_` stores makes the two cases
  /// decidable — see the comment there. Falling back to the plain
  /// tail merely under-reports free space for the duration of one
  /// read call, so the ES-238 anti-wedge reclaim still happens on the
  /// producer's next poll.
  uint32_t free_frames() const {
    const uint64_t h = head_.load(std::memory_order_relaxed);
    // `in_read_` MUST be loaded before `tail_`: observing the guard up
    // synchronizes-with the consumer's seq_cst store, so the tail load
    // below is then guaranteed to see the pre-guard floor application
    // (read_planar part 1) — the documented divergence bound depends
    // on this order. Loading tail first could pair a stale tail with
    // an up guard even for floors applied before the read began.
    const bool reading = in_read_.load(std::memory_order_seq_cst);
    const uint64_t t = tail_.load(std::memory_order_acquire);
    uint64_t eff = t;
    if (!reading) {
      const uint64_t d = discard_to_.load(std::memory_order_acquire);
      if (d > eff) eff = d;
    }
    if (eff >= h) return capacity_;
    const uint64_t used = h - eff;
    if (used >= capacity_) return 0;
    return capacity_ - static_cast<uint32_t>(used);
  }

  /// Consumer-side or observer: frames currently buffered. Honors a
  /// published-but-not-yet-applied discard floor, symmetric with
  /// free_frames(): frames below `discard_to_` are already condemned
  /// and must not be reported as readable. Counting them made
  /// wait-for-buffered barriers return instantly on the stale
  /// pre-seek backlog while the actual post-seek refill had not
  /// started, so the next read returned 0 (ES-427). Clamps to 0 when
  /// the effective tail has advanced past `head_`.
  uint32_t buffered_frames() const {
    // Load order matters: `head_` first, floor last. Racing a
    // concurrent write/publish can then only UNDER-report — exactly
    // what a wait-for-buffered barrier needs.
    const uint64_t h = head_.load(std::memory_order_acquire);
    const uint64_t t = tail_.load(std::memory_order_relaxed);
    const uint64_t d = discard_to_.load(std::memory_order_acquire);
    const uint64_t eff = d > t ? d : t;
    if (h <= eff) return 0;
    return static_cast<uint32_t>(h - eff);
  }

  /// True once the producer has signalled end-of-stream and there
  /// are no more frames coming. The consumer drains buffered_frames
  /// then sees eof and stops.
  bool eof() const { return eof_.load(std::memory_order_acquire); }
  void mark_eof() { eof_.store(true, std::memory_order_release); }
  void clear_eof() { eof_.store(false, std::memory_order_release); }

  /// Producer write of interleaved PCM. Returns frames written
  /// (may be less than `frames` when the ring is near full).
  uint32_t write_interleaved(const float* src, uint32_t frames) {
    const uint32_t free = free_frames();
    const uint32_t to_write = frames < free ? frames : free;
    if (to_write == 0) return 0;
    const uint64_t h = head_.load(std::memory_order_relaxed);
    const uint32_t idx = static_cast<uint32_t>(h) & mask_;
    const uint32_t first = capacity_ - idx;
    const uint32_t a = to_write < first ? to_write : first;
    std::memcpy(buf_.data() + static_cast<size_t>(idx) * channels_, src,
                static_cast<size_t>(a) * channels_ * sizeof(float));
    if (to_write > a) {
      std::memcpy(
          buf_.data(), src + static_cast<size_t>(a) * channels_,
          static_cast<size_t>(to_write - a) * channels_ * sizeof(float));
    }
    head_.store(h + to_write, std::memory_order_release);
    return to_write;
  }

  /// Producer-side: declare a discard floor. The consumer's next
  /// read advances `tail_` to `target` before serving frames. Pass
  /// the current `head_pos()` to drop everything currently buffered.
  /// seq_cst: pairs with the `in_read_` handshake in read_planar() /
  /// free_frames() (see there).
  void publish_discard_to(uint64_t target) {
    discard_to_.store(target, std::memory_order_seq_cst);
  }

  /// Consumer read into a planar `AudioBuffer`. Returns frames
  /// written to `out` (also stored on `out.frames`). Honors any
  /// pending discard before reading.
  ///
  /// Ordering, part 1 — the pre-guard floor application: any floor
  /// visible at entry is applied to `tail_` BEFORE `in_read_` is
  /// raised. While the guard is up the producer falls back to the
  /// plain tail, so entering a read with a stale (pre-floor) tail
  /// makes free_frames() collapse below what the pump's headroom
  /// gate observed moments earlier. Lifting the tail first makes
  /// that window a couple of instructions in the common case — but
  /// NOT zero: a floor published-but-not-yet-propagated can slip
  /// past the entry load and only be caught by the post-guard
  /// re-check, and preemption can hold the gap open. Producers must
  /// therefore treat a gated write's shortfall as transient
  /// backpressure, not an invariant violation (io_loop retries with
  /// a deadline).
  ///
  /// Ordering, part 2 — the handshake: every `in_read_` store and
  /// the second `discard_to_` load are seq_cst, pairing with
  /// publish_discard_to()'s store and free_frames()'s `in_read_`
  /// load. In the single total order over those accesses, either the
  /// producer's `in_read_` load sees this read in flight (and skips
  /// reclaiming the discard region this poll), or this read's
  /// `discard_to_` load sees the published floor (and jumps tail
  /// past the condemned region before copying). There is no
  /// interleaving where the producer overwrites frames a concurrent
  /// read is still copying. The final `false` store is also seq_cst
  /// so it participates in that total order — and, as an
  /// acquire-visible store, it hands the producer the happens-before
  /// edge over this read's buffer accesses when observed.
  uint32_t read_planar(AudioBuffer& out, uint32_t frames) {
    {
      const uint64_t d0 = discard_to_.load(std::memory_order_acquire);
      const uint64_t t0 = tail_.load(std::memory_order_relaxed);
      if (d0 > t0) tail_.store(d0, std::memory_order_release);
    }
    in_read_.store(true, std::memory_order_seq_cst);
    const uint64_t discard = discard_to_.load(std::memory_order_seq_cst);
    uint64_t t = tail_.load(std::memory_order_relaxed);
    if (discard > t) {
      t = discard;
      tail_.store(t, std::memory_order_release);
    }
    const uint64_t h = head_.load(std::memory_order_acquire);
    if (h <= t) {
      in_read_.store(false, std::memory_order_seq_cst);
      out.frames = 0;
      return 0;
    }
    const uint32_t avail = static_cast<uint32_t>(h - t);
    // Clamp to the destination's real capacity: `out.channel()` strides
    // by `capacity_frames`, so honoring a larger request would overrun
    // the caller's buffer.
    const uint32_t req =
        frames < out.capacity_frames ? frames : out.capacity_frames;
    const uint32_t to_read = req < avail ? req : avail;
    const uint32_t idx = static_cast<uint32_t>(t) & mask_;
    const uint32_t first = capacity_ - idx;
    const uint32_t a = to_read < first ? to_read : first;
    const uint32_t out_ch = channels_ < out.channels ? channels_ : out.channels;
    {
      const float* src = buf_.data() + static_cast<size_t>(idx) * channels_;
      for (uint32_t c = 0; c < out_ch; ++c) {
        float* dst = out.channel(c);
        for (uint32_t f = 0; f < a; ++f) {
          dst[f] = src[f * channels_ + c];
        }
      }
    }
    if (to_read > a) {
      const uint32_t b = to_read - a;
      const float* src = buf_.data();
      for (uint32_t c = 0; c < out_ch; ++c) {
        float* dst = out.channel(c) + a;
        for (uint32_t f = 0; f < b; ++f) {
          dst[f] = src[f * channels_ + c];
        }
      }
    }
    for (uint32_t c = out_ch; c < out.channels; ++c) {
      std::memset(out.channel(c), 0, to_read * sizeof(float));
    }
    out.frames = to_read;
    tail_.store(t + to_read, std::memory_order_release);
    in_read_.store(false, std::memory_order_seq_cst);
    return to_read;
  }

  uint64_t head_pos() const { return head_.load(std::memory_order_acquire); }

 private:
  std::vector<float> buf_;
  uint32_t channels_ = 0;
  uint32_t capacity_ = 0;
  uint32_t mask_ = 0;
  alignas(64) std::atomic<uint64_t> head_{0};
  alignas(64) std::atomic<uint64_t> tail_{0};
  alignas(64) std::atomic<uint64_t> discard_to_{0};
  /// True while the consumer is inside read_planar(). Guards the
  /// producer's reclaim of a published discard region (free_frames()).
  alignas(64) std::atomic<bool> in_read_{false};
  alignas(64) std::atomic<bool> eof_{false};
};

#endif  // ECLIPSA_STUDIO_IAMF_PCM_RING_H_
