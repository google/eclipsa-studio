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

#ifndef ECLIPSA_STUDIO_METERS_LIVE_LOUDNESS_METER_H_
#define ECLIPSA_STUDIO_METERS_LIVE_LOUDNESS_METER_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

#include "graph/audio_buffer.h"
#include "meters/loudness_meter.h"
#include "meters/meter_state.h"

/// The mix-bus loudness meter for live monitoring.
///
/// The audio thread copies each rendered block into a preallocated ring
/// with push(). A meter thread owned by this class wakes every
/// kPollInterval, feeds the ring's contents to a LoudnessMeter (the
/// google/loudness_ebur128 analyzer) and writes the readings to the
/// EclipsaStudioLoudnessData given at construction. The audio thread
/// never runs the analyzer: the analyzer appends to its history vectors
/// as blocks complete and computes the integrated value from the whole
/// history, so neither its memory nor its work is bounded.
///
/// ## Threading
///
/// - push(): the audio thread only. No allocation, no lock.
/// - drain(): any thread except the audio thread. The meter thread calls
///   it; tests call it to read the result of the blocks they pushed.
///   Calls are serialized by an internal mutex.
/// - reset(), reconfigure(), set_sample_rate(): the control thread. They
///   rewind the ring's indices and change the configuration push()
///   reads, and reconfigure() and set_sample_rate() reallocate the ring
///   when its size changes, so the caller must keep push() from running
///   for the duration (AudioGraph's loudness fence, or a stopped audio
///   thread). They take the internal mutex, so the meter thread is
///   outside drain() while they run.
/// - The readings: the meter thread writes them inside drain(), and
///   reset()/reconfigure()/set_sample_rate() clear them, all under the
///   internal mutex. Any thread may read them (relaxed atomics).
class LiveLoudnessMeter {
 public:
  /// Interval between the meter thread's drains. A reading lags the
  /// audio by at most this plus the time to analyze the drained frames.
  static constexpr std::chrono::milliseconds kPollInterval{20};

  /// Frames drain() hands back to push() at a time.
  static constexpr uint32_t kChunkFrames = LoudnessMeter::kMaxBlockFrames;

  /// @param out  Where the readings are written. Must outlive this
  ///             object.
  LiveLoudnessMeter(uint32_t sample_rate, uint32_t num_channels,
                    uint32_t layout, EclipsaStudioLoudnessData* out);
  /// Stops and joins the meter thread.
  ~LiveLoudnessMeter();

  LiveLoudnessMeter(const LiveLoudnessMeter&) = delete;
  LiveLoudnessMeter& operator=(const LiveLoudnessMeter&) = delete;

  /// Audio thread. Copies `frames` frames of `buffer` into the ring. A
  /// block whose channel count differs from num_channels() is skipped
  /// and counted in mismatched_blocks(); the first one per configuration
  /// is logged. A block larger than the ring's free space is dropped and
  /// counted in dropped_frames(); the meter thread logs the count at
  /// most once a second.
  void push(const AudioBuffer& buffer, uint32_t frames);

  /// Feeds every frame pushed so far to the analyzer and writes the
  /// readings.
  void drain();

  /// Drops the pending frames, rebuilds the analyzer (dropping every
  /// accumulated block) and clears the readings. See the threading note.
  void reset();

  /// reset() for a new channel count and layout (oar_layout_t value used
  /// for the BS.1770 weights; see LoudnessMeter).
  void reconfigure(uint32_t num_channels, uint32_t layout);

  /// reset() for a new sample rate.
  void set_sample_rate(uint32_t sample_rate);

  /// Control thread, or any thread while the configuration cannot change.
  uint32_t num_channels() const { return channels_; }
  uint32_t layout() const { return layout_; }

  /// Blocks push() skipped for a channel-count mismatch. Any thread.
  uint64_t mismatched_blocks() const {
    return mismatched_blocks_.load(std::memory_order_relaxed);
  }

  /// Frames push() dropped because the ring was full. Any thread.
  uint64_t dropped_frames() const {
    return dropped_frames_.load(std::memory_order_relaxed);
  }

  /// Frames pushed and not yet drained. Any thread.
  uint64_t pending_frames() const {
    return head_.load(std::memory_order_acquire) -
           tail_.load(std::memory_order_acquire);
  }

  /// Ring capacity in frames per channel (a power of two). Control
  /// thread.
  uint32_t ring_capacity() const { return capacity_; }

 private:
  // Sizes the ring for the meter's channel count and sample_rate_,
  // empties it, and copies the configuration push() reads. Caller holds
  // mu_ and keeps push() from running.
  void configure_ring_locked();
  void drain_locked();
  void run();

  EclipsaStudioLoudnessData* const out_;

  // Serializes drain() with itself and with the control-thread
  // reconfiguration calls. Guards meter_, sample_rate_, dropped_logged_,
  // last_drop_log_ and the consumer side of the ring.
  std::mutex mu_;
  LoudnessMeter meter_;
  uint32_t sample_rate_;

  // Single-producer single-consumer ring of planar float frames. Channel
  // c's plane is ring_[c * capacity_ .. (c + 1) * capacity_). head_ is
  // advanced by push() (release) after it writes the frames; tail_ by
  // drain_locked() (release) after the analyzer has read them. Each side
  // reads the other's counter with acquire. Both count frames since the
  // last configure_ring_locked() and never wrap in practice (2^64
  // frames). channels_ and layout_ are the configuration the ring was
  // sized for, which push() reads; like capacity_ and mask_ they change
  // only in configure_ring_locked().
  std::vector<float> ring_;
  uint32_t capacity_ = 0;
  uint32_t mask_ = 0;
  uint32_t channels_ = 0;
  uint32_t layout_ = 0;
  std::atomic<uint64_t> head_{0};
  std::atomic<uint64_t> tail_{0};

  std::atomic<uint64_t> mismatched_blocks_{0};
  std::atomic<uint64_t> dropped_frames_{0};
  // push() sets it after logging the first mismatched block; the
  // reconfiguration calls clear it while push() is kept from running.
  bool mismatch_logged_ = false;
  // dropped_frames() value at the last log line, and when it was
  // written. Under mu_.
  uint64_t dropped_logged_ = 0;
  std::chrono::steady_clock::time_point last_drop_log_{};

  // Meter thread control. stop_ is guarded by thread_mu_. The
  // constructor starts thread_ after sizing the ring.
  std::mutex thread_mu_;
  std::condition_variable thread_cv_;
  bool stop_ = false;
  std::thread thread_;
};

#endif  // ECLIPSA_STUDIO_METERS_LIVE_LOUDNESS_METER_H_
