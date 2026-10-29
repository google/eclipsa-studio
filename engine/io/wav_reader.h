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

#ifndef ECLIPSA_STUDIO_IO_WAV_READER_H_
#define ECLIPSA_STUDIO_IO_WAV_READER_H_

#include <cstdint>
#include <optional>
#include <string>

#include "graph/audio_buffer.h"
#include "wav/reader.h"

/// WAV reader with random-access seeking, backed by the in-house wav
/// library (engine/wav — RIFF/RF64/BW64, PCM 8/16/24/32 + float32/64).
///
/// Thread-safety: not thread-safe; after open(), one thread at a time
/// uses each reader. In playback that is the WavStreamer's disk thread,
/// through a WavStream (io/wav_stream.h), never the audio thread: a read
/// does file I/O. Reads are allocation-free: the library's decode
/// scratch is preallocated in open() and samples decode directly into
/// the destination AudioBuffer.
class WavReader {
 public:
  WavReader() = default;
  ~WavReader() = default;

  // Non-copyable.
  WavReader(const WavReader&) = delete;
  WavReader& operator=(const WavReader&) = delete;

  /// Open a WAV file for reading.
  ///
  /// `mode` follows wav::OpenMode: the strict default fails on any
  /// damage; kLenient recovers truncated/unterminated `data` payloads
  /// and malformed tails (logged as a warning) so damaged-but-playable
  /// user files still play. Playback opens lenient; the export/measure
  /// stream keeps strict so a deliverable can never silently ship less
  /// audio than the source claims.
  /// @returns true on success.
  bool open(const char* path, wav::OpenMode mode = wav::OpenMode::kStrict);

  /// Close and release the file handle.
  void close();

  bool is_open() const { return open_; }

  // File info (valid after open()).
  uint32_t channels() const { return channels_; }
  uint32_t sample_rate() const { return sample_rate_; }
  uint32_t bit_depth() const { return bit_depth_; }
  uint64_t total_frames() const { return total_frames_; }
  uint64_t cursor() const { return cursor_; }

  /// Read up to `frames` frames of float32 samples into `out_buffer`.
  /// File channels beyond out_buffer.channels are decoded to scratch and
  /// dropped; out_buffer channels beyond the file's are zero-filled.
  /// Returns the number of frames actually read (may be < frames at EOF).
  uint32_t read(AudioBuffer& out_buffer, uint32_t frames);

  /// Seek to an absolute sample-frame position.
  bool seek(uint64_t frame_pos);

  static constexpr uint32_t kMaxScratchFrames = 1024;
  static constexpr uint32_t kMaxScratchChannels = 32;

 private:
  std::optional<wav::Reader> reader_;

  bool open_ = false;
  uint32_t channels_ = 0;
  uint32_t sample_rate_ = 0;
  uint32_t bit_depth_ = 0;
  uint64_t total_frames_ = 0;
  uint64_t cursor_ = 0;

  // Per-channel decode scratch for file channels the destination buffer
  // doesn't carry (the library decodes every file channel).
  float scratch_[kMaxScratchChannels * kMaxScratchFrames] = {};
};

#endif  // ECLIPSA_STUDIO_IO_WAV_READER_H_
