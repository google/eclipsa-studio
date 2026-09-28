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

// BW64/RIFF WAV reader for ADM audio — a thin ADM-metadata layer over the
// shared in-house wav library (engine/wav).
//
// The library does the parsing (RIFF/RF64/BW64, `ds64` sizing, format
// resolution, `axml`/`chna` capture, chunk inventory, planar PCM decode);
// this class keeps the ADM pipeline's historical surface: the resolved
// format (`wav::Info`), the axml/chna payloads, and an inventory of
// chunks beyond the structural ones (vendor sidecar metadata such as
// `dbmd`).

#ifndef ADM2IAMF_WAV_BW64_READER_H_
#define ADM2IAMF_WAV_BW64_READER_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "absl/status/statusor.h"
#include "wav/reader.h"
#include "wav/types.h"

namespace adm2iamf {

// Indexes a BW64/RIFF WAV file and extracts the ADM-relevant chunks. The
// underlying file stays open for on-demand PCM reads, so a reader is move-only
// and handed out by unique_ptr.
class Bw64Reader {
 public:
  static absl::StatusOr<std::unique_ptr<Bw64Reader>> Open(
      const std::string& path);

  // A chunk beyond the ones this reader consumes, e.g. vendor sidecar
  // metadata. Only the id and payload size are kept.
  struct ExtraChunk {
    std::string id;  // Four-character chunk id, e.g. "dbmd".
    uint64_t bytes = 0;
  };

  // Upper bound on retained ExtraChunk entries. Real files carry a handful;
  // a zero-filled tail otherwise synthesizes one entry per 8 bytes, so this
  // is a memory guard, not a limit on anything a well-formed file can
  // express.
  static constexpr size_t kMaxExtraChunks = 32;

  // Resolved properties of the stream — format, channels, sample rate.
  const wav::Info& format() const { return reader_->info(); }

  // Per-channel sample count of the `data` chunk.
  uint64_t num_frames() const { return reader_->info().num_frames; }

  // The `axml` chunk as text (empty if absent).
  const std::string& axml() const { return reader_->axml(); }
  // The raw `chna` chunk bytes (empty if absent).
  const std::vector<uint8_t>& chna() const { return reader_->chna(); }
  // Chunks other than fmt/data/axml/chna/ds64/JUNK, in file order, capped at
  // kMaxExtraChunks entries.
  const std::vector<ExtraChunk>& extra_chunks() const { return extra_chunks_; }
  // How many such chunks the file actually held; > extra_chunks().size() when
  // the cap truncated the inventory.
  uint64_t extra_chunks_seen() const { return extra_chunks_seen_; }

  // Reads frames [start_frame, start_frame + count) of `data` into `out` as
  // planar float32 (PCM normalized to [-1, 1]; float sources keep their
  // headroom). `out` is resized to [num_channels][frames_read]. Returns the
  // number of frames actually read (may be < count at EOF).
  absl::StatusOr<uint64_t> ReadPlanarFloat(
      uint64_t start_frame, uint64_t count,
      std::vector<std::vector<float>>& out);

 private:
  Bw64Reader() = default;

  std::optional<wav::Reader> reader_;
  std::vector<ExtraChunk> extra_chunks_;
  uint64_t extra_chunks_seen_ = 0;
};

}  // namespace adm2iamf

#endif  // ADM2IAMF_WAV_BW64_READER_H_
