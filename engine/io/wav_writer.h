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

#ifndef ECLIPSA_STUDIO_IO_WAV_WRITER_H_
#define ECLIPSA_STUDIO_IO_WAV_WRITER_H_

#include <cstdint>
#include <optional>
#include <string>

#include "graph/audio_buffer.h"
#include "wav/writer.h"

/// WAV writer backed by the in-house wav library (engine/wav). Inherits
/// its guarantees: a valid header on close, no silent 4 GiB wraparound
/// (the container auto-upgrades to RF64 past the 32-bit ceiling), and the
/// canonical round-to-nearest float → PCM quantizer.
///
/// Thread-safety: one WavWriter instance per output file. Not
/// thread-safe — use from a single thread (the bounce thread).
class WavWriter {
 public:
  WavWriter() = default;
  ~WavWriter() { close(); }

  WavWriter(const WavWriter&) = delete;
  WavWriter& operator=(const WavWriter&) = delete;

  /// Open a new WAV file for writing.
  /// @param path       Output file path. Parent directory must exist.
  /// @param channels   Number of output channels.
  /// @param sample_rate Sample rate in Hz.
  /// @param format     Output sample format. 32-bit IEEE float is the
  ///                   natural internal format (matches our planar
  ///                   float buffers); integer PCM is needed by
  ///                   downstream tools that can't read float WAVs
  ///                   (notably iamf-tools).
  /// @returns true on success.
  bool open(const char* path, uint32_t channels, uint32_t sample_rate,
            wav::WriteFormat format);

  /// Write `frames` frames from a planar AudioBuffer.
  /// @returns the number of frames actually written.
  uint32_t write(const AudioBuffer& buffer, uint32_t frames);

  /// Finalize and close the file. Called automatically by the
  /// destructor if not called explicitly. Returns false when writing the
  /// pad byte, patching the header or closing the file fails, and true
  /// otherwise, including when no file is open.
  bool close();

  bool is_open() const { return open_; }
  uint64_t frames_written() const { return frames_written_; }

  static constexpr uint32_t kMaxScratchChannels = 32;

 private:
  std::optional<wav::Writer> writer_;

  bool open_ = false;
  uint32_t channels_ = 0;
  uint64_t frames_written_ = 0;
};

#endif  // ECLIPSA_STUDIO_IO_WAV_WRITER_H_
