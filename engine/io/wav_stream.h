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

#ifndef ECLIPSA_STUDIO_IO_WAV_STREAM_H_
#define ECLIPSA_STUDIO_IO_WAV_STREAM_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "graph/audio_buffer.h"
#include "iamf/pcm_ring.h"
#include "io/wav_reader.h"

/// Streams one WAV file to the audio thread through a lock-free ring.
///
/// A disk thread (WavStreamer) reads the file ahead of the playhead into
/// a PcmRing; the audio thread reads the ring with read() and never
/// touches the file. A seek from the audio thread is a request:
/// post_seek_rt() stores the target, the disk thread repositions the
/// reader, publishes a discard floor so the audio thread skips the
/// frames read before the seek, and refills from the target. primed()
/// tells the audio thread when the refill is deep enough to play.
///
/// ## Threading
///
/// - open(): the control thread, before the stream is handed to a
///   WavStreamer. It opens the file and reads its first kChunkFrames.
/// - read(), eof(), post_seek_rt(), seek_applied(), primed(): the audio
///   thread. No allocation, no lock, no file I/O.
/// - service(): the disk thread, once the stream is handed to a
///   WavStreamer (open() calls it on the control thread before that).
/// - channels(), sample_rate(), total_frames(): any thread after open().
class WavStream {
 public:
  /// Ring capacity in frames: 682 ms at 48 kHz.
  static constexpr uint32_t kRingFrames = 32768;
  /// Frames the disk thread reads per WavReader::read() call.
  static constexpr uint32_t kChunkFrames = 4096;

  WavStream() = default;
  WavStream(const WavStream&) = delete;
  WavStream& operator=(const WavStream&) = delete;

  /// Opens `path` leniently (a damaged but playable file plays its intact
  /// prefix; see wav::OpenMode) and reads its first kChunkFrames into the
  /// ring, so the audio thread has data before the disk thread first
  /// wakes. At most `max_channels` channels are streamed; the file's
  /// further channels are dropped. Returns false if the file does not
  /// open.
  bool open(const char* path, uint32_t max_channels);

  /// Channels streamed (the file's count, capped at open()'s
  /// max_channels).
  uint32_t channels() const { return channels_; }
  uint32_t sample_rate() const { return sample_rate_; }
  uint64_t total_frames() const { return total_frames_; }

  /// Audio thread. Reads up to `frames` frames into `out` (planar) and
  /// sets out.frames. Returns fewer at the end of the file, or when the
  /// disk thread has fallen behind (eof() tells the two apart).
  uint32_t read(AudioBuffer& out, uint32_t frames);

  /// Audio thread. True once the disk thread has read to the end of the
  /// file from the current position.
  bool eof() const { return ring_.eof(); }

  /// Audio thread. Asks the disk thread to continue from file frame
  /// `frame_pos` (clamped to the file's length). Frames already in the
  /// ring are discarded once the disk thread applies the request; until
  /// primed() returns true, read() may return them, so the caller must
  /// not read in between.
  void post_seek_rt(uint64_t frame_pos);

  /// Audio thread. True when the disk thread has applied every seek
  /// posted so far, so the ring holds no frames from before it.
  bool seek_applied() const {
    return seeks_applied_.load(std::memory_order_acquire) >= seeks_posted_;
  }

  /// Audio thread. True when seek_applied() and the ring holds at least
  /// `min_frames` frames from the new position, or the file ends before
  /// that.
  bool primed(uint32_t min_frames) const;

  /// Disk thread. Applies a pending seek, then reads up to `max_chunks`
  /// chunks of kChunkFrames into the ring while it has room for them.
  /// Returns true if it applied a seek or wrote any frames.
  bool service(uint32_t max_chunks);

  /// Test seam: while set, service() returns at once without applying a
  /// seek or reading, as if the disk thread had stalled on this file.
  /// The other streams of the same WavStreamer are serviced as usual.
  /// Costs one relaxed load per service() call. Any thread.
  void set_stalled_for_testing(bool stalled) {
    stalled_for_testing_.store(stalled, std::memory_order_relaxed);
  }
  bool stalled_for_testing() const {
    return stalled_for_testing_.load(std::memory_order_relaxed);
  }

 private:
  // True when the audio thread has posted a seek service() has not
  // applied yet.
  bool seek_pending() const {
    return seeks_requested_.load(std::memory_order_acquire) != seeks_seen_;
  }

  uint32_t channels_ = 0;
  uint32_t sample_rate_ = 0;
  uint64_t total_frames_ = 0;

  // The disk thread's reader and the planar chunk it reads into.
  WavReader reader_;
  std::vector<float> chunk_;

  PcmRing ring_;

  // Seek requests, the same protocol as IamfPlaybackSession's: the audio
  // thread stores the target, then bumps seeks_requested_; the disk
  // thread loads the count, then the target (a torn pair can only pair
  // an older count with a newer target, which the next service()
  // re-applies), repositions, publishes the discard floor and stores
  // seeks_applied_ last (release), so a reader that sees the new value
  // also sees the floor.
  std::atomic<uint64_t> seek_target_{0};
  std::atomic<uint64_t> seeks_requested_{0};
  std::atomic<uint64_t> seeks_applied_{0};
  uint64_t seeks_seen_ = 0;    // Disk thread.
  uint64_t seeks_posted_ = 0;  // Audio thread: the count primed() waits for.

  // See set_stalled_for_testing().
  std::atomic<bool> stalled_for_testing_{false};
};

/// The disk thread that services every WavStream of an AudioGraph.
///
/// It holds weak references, so a stream is destroyed when its element
/// chain releases it, on whichever thread drops the last reference (the
/// control thread, or this thread when it is servicing the stream at
/// that moment); the audio thread never owns a reference. Each pass
/// applies every stream's pending seek and reads one chunk per stream,
/// so a seek waits for at most one chunk of each other stream, not for
/// their whole rings. The thread repeats passes until no stream needs
/// work, then sleeps for kIdleInterval.
class WavStreamer {
 public:
  /// Poll interval while every ring is full and no seek is pending. A
  /// seek posted by the audio thread is applied within about this long.
  static constexpr std::chrono::milliseconds kIdleInterval{2};

  WavStreamer();
  /// Stops and joins the disk thread.
  ~WavStreamer();

  WavStreamer(const WavStreamer&) = delete;
  WavStreamer& operator=(const WavStreamer&) = delete;

  /// Control thread. Starts servicing `stream`, which must be open.
  void add(const std::shared_ptr<WavStream>& stream);

 private:
  void run();

  std::mutex mu_;  // Guards streams_ and stop_.
  std::condition_variable cv_;
  std::vector<std::weak_ptr<WavStream>> streams_;
  bool stop_ = false;
  std::thread thread_;  // Last: starts after the fields above exist.
};

#endif  // ECLIPSA_STUDIO_IO_WAV_STREAM_H_
