// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "adm_import/wav/bw64_reader.h"

#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "wav/reader.h"
#include "wav/types.h"

namespace adm2iamf {
namespace {

// Chunks the reader (or the underlying library) consumes structurally;
// everything else is surfaced as an ExtraChunk.
bool IsStructuralChunk(const std::string& id) {
  return id == "fmt " || id == "data" || id == "axml" || id == "chna" ||
         id == "ds64" || id == "JUNK";
}

}  // namespace

absl::StatusOr<std::unique_ptr<Bw64Reader>> Bw64Reader::Open(
    const std::string& path) {
  auto r = wav::Reader::Open(path);
  if (!r.ok()) {
    // Preserve the historical distinction between "no such file" and
    // "not a WAV we accept".
    if (r.error().rfind("Cannot open", 0) == 0) {
      return absl::NotFoundError(r.error());
    }
    return absl::InvalidArgumentError(r.error());
  }

  auto reader = std::unique_ptr<Bw64Reader>(new Bw64Reader());
  reader->reader_.emplace(std::move(*r));

  // Everything beyond the structural chunks is sidecar metadata. The
  // library's inventory ids are already sanitized to printable ASCII.
  uint64_t structural_seen = 0;
  for (const wav::ChunkInfo& c : reader->reader_->chunks()) {
    if (IsStructuralChunk(c.id)) {
      ++structural_seen;
      continue;
    }
    if (reader->extra_chunks_.size() < kMaxExtraChunks) {
      reader->extra_chunks_.push_back(ExtraChunk{c.id, c.size});
    }
  }
  // chunks_seen() stays exact past the inventory cap, but chunks can only
  // be *classified* within the retained prefix — anything past the cap
  // counts as an extra here even if it is structural (e.g. a late JUNK).
  // fmt /data sit at the front of real files, so this is an upper bound
  // that is exact for anything but pathologically chunk-heavy inputs; the
  // value only feeds the probe inspector's summary line.
  reader->extra_chunks_seen_ = reader->reader_->chunks_seen() - structural_seen;
  return reader;
}

absl::StatusOr<uint64_t> Bw64Reader::ReadPlanarFloat(
    uint64_t start_frame, uint64_t count,
    std::vector<std::vector<float>>& out) {
  auto n = reader_->ReadPlanarFloat(start_frame, count, out);
  if (!n.ok()) return absl::DataLossError(n.error());
  return *n;
}

}  // namespace adm2iamf
