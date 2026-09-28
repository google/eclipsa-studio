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

//
// WAV reader: RIFF, RF64 and BW64 containers; uint8/int16/int24/int32 PCM
// and float32/float64 IEEE samples; plain and WAVE_FORMAT_EXTENSIBLE `fmt `.
// `ds64` is accepted anywhere before the `data` chunk. ADM metadata chunks
// (`axml`, `chna`, `bext`) are preserved verbatim, and every chunk is
// inventoried in file order.
//
// The parser fails closed by default: a malformed file — truncated
// payloads, chunk sizes exceeding the file, a missing/late `ds64`, `fmt `
// after `data`, unsupported sample formats, partial trailing chunks — is
// an error, never a silent partial success. OpenMode::kLenient relaxes
// exactly the damage patterns real-world files exhibit while the header
// itself is intact (see OpenMode); structural damage before `data` fails
// in both modes.
//
// Samples are delivered planar in either of two conventions:
//   - finite float32 (PCM normalized to [-1, 1]; IEEE-float sources keep
//     their headroom)                          (ReadPlanarFloat)
//   - left-justified int32                     (ReadPlanarInt32LeftJustified)

#ifndef ECLIPSA_STUDIO_WAV_READER_H_
#define ECLIPSA_STUDIO_WAV_READER_H_

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include "wav/result.h"
#include "wav/types.h"

namespace wav {

// How Open() treats recoverable damage.
//
// kStrict is for producers and metadata-critical consumers (export, ADM
// import): any deviation is an error, because a silently-short read there
// corrupts a deliverable.
//
// kLenient is for consumers standing in front of the user's content
// library (playback, waveform, probing), where the alternative to a
// partial file is nothing at all. It recovers the damage patterns
// common in real-world files:
//   - plain-RIFF `data` declaring more bytes than remain on disk
//     (interrupted recording / partial copy): clamped to what exists;
//   - a plain-RIFF `data` size of 0xFFFFFFFF (non-seekable streaming
//     writers that never patch the header): treated as extending to
//     EOF. Both size recoveries are RIFF-ONLY: in RF64/BW64 the bytes
//     after `data` are where broadcast tools put ADM metadata, and
//     absorbing them into the payload would return the file as longer
//     plain audio with its `axml` decoded as samples — those
//     containers fail even leniently;
//   - a `data` size that is not a whole number of frames: the dangling
//     partial frame is dropped;
//   - garbage after `data` has been located (stray trailing bytes, a
//     tail chunk overrunning EOF): the chunk walk stops, keeping
//     everything parsed so far.
// Lenient recovery is NOT free of information loss, and callers must
// treat a recovered open accordingly: chunks()/chunks_seen() and the
// metadata accessors reflect only what was parsed before the walk
// stopped (a dropped axml/chna is additionally flagged via
// metadata_dropped()), a clamped RIFF `data` may include trailing
// chunk bytes as audio, and I/O errors (badbit) always fail — only
// structural damage recovers. Every recovery is surfaced via
// Reader::recovered(). Damage before `data` (bad magic, broken
// `fmt `/`ds64`, unsupported formats, a corrupt chunk ahead of the
// payload) fails in both modes — there is nothing trustworthy to
// salvage without an intact header path to `data`.
enum class OpenMode {
  kStrict,
  kLenient,
};

class Reader {
 public:
  static Result<Reader> Open(const std::string& path,
                             OpenMode mode = OpenMode::kStrict);

  // Move-only: the underlying file stays open for on-demand reads.
  Reader(Reader&&) = default;
  Reader& operator=(Reader&&) = default;
  Reader(const Reader&) = delete;
  Reader& operator=(const Reader&) = delete;

  const Info& info() const { return info_; }

  // True when an OpenMode::kLenient open recovered damage: the `data`
  // payload was clamped or floored, or the chunk walk stopped early on a
  // malformed tail. Always false for kStrict opens (they fail instead).
  // Callers can use this to log that the file is damaged even though it
  // reads.
  bool recovered() const { return recovered_; }

  // True when a lenient walk-stop discarded a chunk that announced
  // itself as ADM metadata (`axml`/`chna`) but could not be read — the
  // file is ADM-adjacent and must not be silently treated as a plain
  // WAV (the probe surfaces this so ADM detection can route it to the
  // strict import path for an honest error). Best-effort: metadata
  // hidden behind an earlier malformed chunk, or swallowed by a
  // clamped RIFF `data`, is undetectable.
  bool metadata_dropped() const { return metadata_dropped_; }

  // Every chunk in file order (including fmt /data/ds64/JUNK), capped at
  // kMaxChunkInfos entries; chunks_seen() stays exact past the cap.
  const std::vector<ChunkInfo>& chunks() const { return chunks_; }
  uint64_t chunks_seen() const { return chunks_seen_; }

  // `data` payload location, straight from the chunk walk — authoritative
  // even when the chunk inventory above hits its cap.
  uint64_t data_offset() const { return data_offset_; }
  uint64_t data_size() const { return data_size_; }

  // ADM/broadcast metadata payloads, empty when absent. Only the first
  // occurrence of each chunk is retained.
  const std::string& axml() const { return axml_; }
  const std::vector<uint8_t>& chna() const { return chna_; }
  const std::vector<uint8_t>& bext() const { return bext_; }
  Metadata metadata() const { return Metadata{axml_, chna_, bext_}; }

  // Reads frames [start_frame, start_frame + count) as planar float32.
  // PCM sources are normalized to [-1, 1]; IEEE-float sources pass through
  // with their headroom intact (values may exceed ±1). Every delivered
  // sample is finite: NaN maps to 0 and ±inf (or float64 magnitudes beyond
  // FLT_MAX, where bare narrowing would be UB) saturate to ±FLT_MAX — see
  // wav/convert.h. `out` is resized to [channels][frames_read]. Returns the
  // number of frames actually read (< count only at end of stream).
  Result<uint64_t> ReadPlanarFloat(uint64_t start_frame, uint64_t count,
                                   std::vector<std::vector<float>>& out);

  // Same range semantics, delivered as left-justified int32 (the sample's
  // significant bits at the top of the word; float sources are quantized at
  // the 2^31 scale with the canonical wav/convert.h quantizer).
  Result<uint64_t> ReadPlanarInt32LeftJustified(
      uint64_t start_frame, uint64_t count,
      std::vector<std::vector<int32_t>>& out);

  // Non-allocating variant for real-time callers: decodes into
  // caller-provided per-channel destinations (info().channels pointers,
  // each with room for `count` samples). The internal byte scratch is
  // reused across calls; call ReserveReadScratch() once, off the real-time
  // thread, to guarantee reads never allocate.
  Result<uint64_t> ReadPlanarFloatInto(uint64_t start_frame, uint64_t count,
                                       float* const* out);

  // Preallocates the internal read scratch for reads of up to `max_frames`
  // frames, so subsequent ReadPlanarFloatInto calls of that size are
  // allocation-free.
  void ReserveReadScratch(uint64_t max_frames);

  // Memory guard on the retained chunk inventory. Real files carry a
  // handful of chunks; a garbage tail could otherwise synthesize one entry
  // per 8 bytes.
  static constexpr size_t kMaxChunkInfos = 64;

  // Memory guard on buffered metadata chunks (axml/chna/bext/ds64/fmt).
  // A declared size beyond this fails the open rather than driving a
  // multi-gigabyte allocation.
  static constexpr uint64_t kMaxBufferedChunkBytes = uint64_t{1} << 28;

 private:
  Reader() = default;

  // Clips [start_frame, +count) to the stream and reads the raw
  // interleaved bytes into raw_scratch_, returning the clipped frame
  // count. The scratch only ever grows, so steady-state reads of a fixed
  // block size are allocation-free. A read that starts where the previous
  // one ended skips the seek (one syscall per audio block).
  Status ReadRaw(uint64_t start_frame, uint64_t count, uint64_t& frames);

  std::ifstream file_;
  std::vector<uint8_t> raw_scratch_;
  // Byte offset file_ is positioned at after the last successful ReadRaw,
  // or -1 when unknown (before the first read, or after a failed one).
  int64_t stream_pos_ = -1;
  Info info_;
  uint64_t data_offset_ = 0;  // Byte offset of the `data` payload.
  uint64_t data_size_ = 0;    // `data` payload size in bytes.
  std::string axml_;
  std::vector<uint8_t> chna_;
  std::vector<uint8_t> bext_;
  std::vector<ChunkInfo> chunks_;
  uint64_t chunks_seen_ = 0;
  bool recovered_ = false;
  bool metadata_dropped_ = false;
};

}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_READER_H_
