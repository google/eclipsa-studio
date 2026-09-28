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

#ifndef ECLIPSA_STUDIO_DSP_RESAMPLER_H_
#define ECLIPSA_STUDIO_DSP_RESAMPLER_H_

#include <cstdint>
#include <memory>

#include "graph/audio_buffer.h"

namespace dsp {

/// Sample-rate converter for one element's signal chain.
///
/// Wraps libsamplerate's bandlimited-sinc converters. Quality::kLive
/// (SRC_SINC_MEDIUM_QUALITY) is the real-time tier; Quality::kExport
/// (SRC_SINC_BEST_QUALITY) is the transparent tier for bounce/export.
/// Heap-allocates its working buffers in init() so the audio thread
/// never touches the allocator. Used as planar-in → planar-out: the
/// caller writes source samples into input_buffer() (an AudioBuffer
/// view onto private storage), then calls consume() to produce output
/// frames into a caller-owned planar AudioBuffer.
///
/// libsamplerate decides per call how much input it needs to fill the
/// requested output; any frames it leaves unconsumed are carried over
/// internally and folded into the next consume(), so no source samples
/// are ever dropped. required_input() accounts for the carry.
///
/// Thread-safety: init() is control-thread only. required_input(),
/// consume(), and input_buffer() are audio-thread safe once init()
/// has succeeded. reset() is callable from EITHER the control thread
/// or the audio thread (but not concurrently with consume()): it is
/// allocation- and lock-free — src_reset() zeroes the converter's
/// filter history, a memset bounded by the filter length × channels
/// (~100 µs worst case for a 16-channel chain) — and the ES-473 seek
/// path invokes it on the audio thread at seek-post time.
class Resampler {
 public:
  /// Converter quality tier. kLive is cheap enough for the per-element
  /// real-time path; kExport is audibly/measurably transparent and
  /// roughly 4× the CPU — offline paths only.
  enum class Quality { kLive, kExport };

  Resampler();
  ~Resampler();

  // Non-copyable / non-movable — libsamplerate's state holds internal
  // pointers; copying or moving would invalidate them.
  Resampler(const Resampler&) = delete;
  Resampler& operator=(const Resampler&) = delete;

  /// Set up the resampler for `channels` planar f32 streams converting
  /// from `in_rate` to `out_rate`. `max_out_frames` is the largest
  /// output block the caller will ever request in a single consume()
  /// call — sizes the internal scratch buffers. Allocates on the heap.
  /// Returns false on bad config (zero rate / channels) or allocation
  /// failure. Safe to call only from the control thread.
  bool init(uint32_t in_rate, uint32_t out_rate, uint32_t channels,
            uint32_t max_out_frames, Quality quality = Quality::kLive);

  /// How many fresh input frames the caller should hand off to produce
  /// `out_frames` output frames, given frames already carried over from
  /// the previous consume(). Includes sinc-filter priming headroom, so
  /// the first call after init() / reset() asks for slightly more.
  /// Audio-thread safe.
  uint64_t required_input(uint64_t out_frames) const;

  /// Planar AudioBuffer view onto the resampler's private input
  /// storage. The caller (typically a WavReader) writes up to
  /// max_in_frames frames here; consume() then reads from it. The
  /// view's `frames` field is set by the caller's read.
  AudioBuffer& input_buffer() { return input_view_; }

  /// Read `in_frames` from input_buffer() and write up to
  /// `out_frames_wanted` planar frames into `out_planar`. Sets
  /// `out_planar.frames` to the number actually written, which can be
  /// less than `out_frames_wanted` while the sinc filter primes (first
  /// call) or near end-of-stream. Audio-thread safe — no allocation.
  uint32_t consume(AudioBuffer& out_planar, uint32_t in_frames,
                   uint32_t out_frames_wanted);

  /// Drain the sinc filter's history at end-of-stream. Feeds
  /// libsamplerate `end_of_input` (plus any input still carried from
  /// the last consume()) and writes up to `out_frames_wanted` planar
  /// frames into `out_planar`, returning the count produced. Call
  /// repeatedly until it returns 0 to emit the full ~wing-length tail
  /// (≈3 ms at kExport when downsampling) that consume() leaves in the
  /// filter — otherwise that tail is lost and the deliverable's end is
  /// truncated. Offline/export paths only; no allocation.
  ///
  /// After flush() the converter is in end-of-input state: call reset()
  /// before any further consume(). See issue ES-83.
  uint32_t flush(AudioBuffer& out_planar, uint32_t out_frames_wanted);

  /// Discard the resampler's internal filter state and the input
  /// carry. Call after a seek so the next consume() doesn't bleed
  /// pre-seek samples into the output. Audio-thread safe (see the
  /// class comment); must not race consume().
  void reset();

  uint32_t in_rate() const { return in_rate_; }
  uint32_t out_rate() const { return out_rate_; }
  uint32_t channels() const { return channels_; }

 private:
  uint32_t in_rate_ = 0;
  uint32_t out_rate_ = 0;
  uint32_t channels_ = 0;
  uint32_t max_in_frames_ = 0;
  uint32_t max_out_frames_ = 0;
  uint32_t priming_frames_ = 0;
  uint32_t carry_frames_ = 0;
  double ratio_ = 0.0;  // out_rate / in_rate, as libsamplerate wants it.
  bool initialized_ = false;

  // Copy `produced` interleaved frames from out_il_storage_ into the
  // caller's planar buffer, zero-filling any extra caller channels, and
  // set out_planar.frames. Shared by consume() and flush().
  void write_planar_output(AudioBuffer& out_planar, uint32_t produced) const;

  // Owning pointer to a heap-allocated SRC_STATE. void* keeps
  // samplerate.h out of this header. Freed in destructor.
  void* src_state_ = nullptr;

  // Per-rate-conversion working buffers. Allocated in init().
  //   in_planar — planar (channels × max_in_frames). WavReader writes here.
  //   in_il     — interleaved (2 × max_in_frames × channels). Holds the
  //               carry from the previous call followed by the freshly
  //               interleaved input; libsamplerate reads from here.
  //   out_il    — interleaved (max_out_frames × channels). Filled by
  //               libsamplerate.
  std::unique_ptr<float[]> in_planar_storage_;
  std::unique_ptr<float[]> in_il_storage_;
  std::unique_ptr<float[]> out_il_storage_;
  AudioBuffer input_view_ = {};
};

}  // namespace dsp

#endif  // ECLIPSA_STUDIO_DSP_RESAMPLER_H_
