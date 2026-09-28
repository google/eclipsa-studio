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

#ifndef ECLIPSA_STUDIO_IAMF_IAMF_STREAM_READER_H_
#define ECLIPSA_STUDIO_IAMF_IAMF_STREAM_READER_H_

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "graph/audio_buffer.h"
#include "iamf/include/iamf_tools/iamf_stream_interface.h"
#include "iamf/read_only_file_map.h"

/// WavReader-shaped adapter over iamf-tools' Phase A streaming public API
/// (`IamfStreamFactory::OpenFromBytes` + `IamfStreamInterface`).
///
/// Wraps a single Audio Element in the bitstream and exposes the same
/// pull interface the existing audio graph uses for WAV sources. The
/// per-TU granularity of the upstream API (e.g. 960 samples for Opus,
/// 1024 for AAC) is hidden: `read(AudioBuffer&, frames)` chunks or
/// batches TUs as needed and de-interleaves into planar output.
///
/// Thread-safety: one reader per element-chain slot; accessed only from
/// the audio thread after `open()`. Construction / `open()` / `close()` /
/// destruction must happen on the control thread. The underlying
/// `IamfStreamInterface` contract requires that `NextTemporalUnit`,
/// `Seek`, and destruction not race any other mutating call on the same
/// stream — that's guaranteed by this single-thread-per-reader design.
///
/// Caveat (from the upstream header): for one or two TUs after a
/// `Seek`, `mix_gain_db_per_ae` may fall back to the AE default because
/// the covering parameter block sits behind the new cursor. Callers that
/// care about block-accurate mix gain across seeks should smooth the
/// resulting value (the graph's existing slew on `set_element_mix_gain`
/// handles this).
///
/// Scope: single-AE. Multi-AE fan-out (one stream feeding N chains)
/// belongs in a higher-level playback session that owns the
/// `IamfStreamInterface` and routes per-AE samples to per-slot
/// ring buffers — that will land when the graph learns about Playback
/// mode.
class IamfStreamReader {
 public:
  IamfStreamReader();
  ~IamfStreamReader();

  IamfStreamReader(const IamfStreamReader&) = delete;
  IamfStreamReader& operator=(const IamfStreamReader&) = delete;

  /// Open an IAMF file. mmaps the file on success; the mapping stays
  /// alive until `close()` (the upstream API requires the backing bytes
  /// to remain valid for the stream's lifetime).
  /// @param path      Filesystem path to a .iamf file.
  /// @param ae_index  Which Audio Element to read (must be <
  ///                  `GetNumAudioElements`). Defaults to 0.
  /// @returns true on success. On failure, `last_error()` holds a
  ///          prefixed reason ("malformed:", "io:", "unsupported:",
  ///          "invalid_argument:").
  bool open(const char* path, uint32_t ae_index = 0);

  /// Test-only: open directly from an in-memory byte buffer. A copy is
  /// taken so the caller does not have to keep `bytes` alive.
  bool open_from_memory(const uint8_t* bytes, size_t len,
                        uint32_t ae_index = 0);

  /// Close and release native resources (stream, mmap).
  void close();

  bool is_open() const { return stream_ != nullptr; }

  // File info, valid after `open()`.
  uint32_t channels() const { return channels_; }
  uint32_t sample_rate() const { return sample_rate_; }
  uint64_t total_frames() const { return total_frames_; }
  uint64_t cursor() const { return cursor_; }
  uint32_t ae_index() const { return ae_index_; }

  /// Most recent error message (already carries an upstream prefix like
  /// "malformed:" / "io:" / "unsupported:" / "decode:"). Empty if no
  /// error has occurred on this reader.
  const std::string& last_error() const { return last_error_; }

  /// Read up to `frames` frames into `out_buffer` (planar). Returns the
  /// number of frames actually produced. Stops at `frames` or at EOF /
  /// unrecoverable error. After a decode error or EOF, subsequent reads
  /// return 0; `seek()` clears a decode-error-poisoned stream per the
  /// upstream contract.
  uint32_t read(AudioBuffer& out_buffer, uint32_t frames);

  /// Seek to an absolute sample-frame position (trim-adjusted timeline).
  /// TU-aligned: rounds down to the start of the TU containing
  /// `frame_pos`. Clamps to `total_frames()`. Returns false and sets
  /// `last_error()` on failure.
  bool seek(uint64_t frame_pos);

 private:
  bool configure_from_open_stream(uint32_t ae_index);
  bool map_file(const char* path);
  void unmap_file();

  std::unique_ptr<iamf_tools::api::IamfStreamInterface> stream_;

  uint32_t ae_index_ = 0;
  uint32_t channels_ = 0;
  uint32_t sample_rate_ = 0;
  uint64_t total_frames_ = 0;
  uint64_t cursor_ = 0;
  bool eof_ = false;
  std::string last_error_;

  // Backing bytes. mapped_bytes_/mapped_len_ point either into
  // `file_map_.data()` (from `open()`) or into `owned_bytes_` (from
  // `open_from_memory()`). Never both.
  const uint8_t* mapped_bytes_ = nullptr;
  size_t mapped_len_ = 0;
  eclipsa_studio::ReadOnlyFileMap file_map_;
  std::vector<uint8_t> owned_bytes_;

  // Reused across `read()` calls so the inner vectors retain capacity
  // and `NextTemporalUnit`'s resize+copy-into is free after the first
  // TU (typical case).
  iamf_tools::api::TemporalUnitOutput tu_;

  // Cursor into `tu_.samples_per_ae[ae_index_]` between reads.
  // `tu_frames_remaining_ == 0` means the TU buffer is drained and we
  // need to pump another one on the next read.
  uint32_t tu_frame_offset_ = 0;
  uint32_t tu_frames_remaining_ = 0;
};

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_STREAM_READER_H_
