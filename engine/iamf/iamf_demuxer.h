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

#ifndef ECLIPSA_STUDIO_IAMF_IAMF_DEMUXER_H_
#define ECLIPSA_STUDIO_IAMF_IAMF_DEMUXER_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "absl/types/span.h"
#include "iamf/read_only_file_map.h"

namespace eclipsa_studio {

// Where the IAMF bitstream of an MP4 `iamf` track sits: the descriptor OBUs
// serialised from the track's sample entry, then the byte ranges in the MP4
// file that hold the sample payloads, in sample order. Adjacent samples are
// merged into one range.
struct IamfTrackIndex {
  struct Range {
    uint64_t offset = 0;
    uint64_t size = 0;
  };
  std::vector<uint8_t> descriptor_obus;
  std::vector<Range> samples;
};

// Extracts the standalone IAMF bitstream from the `iamf` track of an
// IAMF-in-ISOBMFF MP4 (the inverse of IamfMuxer), in-process via libgpac.
//
// The reconstructed bitstream is the descriptor OBUs (serialized from the
// track's GF_IAConfig) followed by every frame's OBUs (the sample
// payloads) — exactly the layout a bare .iamf file has. The OBUs are
// carried through verbatim, so profile, substream layout, and measured
// loudness are preserved; demux -> probe is how the export -> QC
// round-trip is verified.
//
// Scope (first cut, ES-36): plays the audio track's frames from media time 0.
// IamfMuxer only ever writes a duration-clamp edit (EditTime/MediaTime 0),
// so our own exports stay A/V-aligned. A non-zero leading edit on an
// arbitrary external MP4 is detected and logged but NOT yet compensated.
//
// Control-thread only (heap-allocating, synchronous). Never call from the
// audio thread.
class IamfDemuxer {
 public:
  IamfDemuxer() = default;
  ~IamfDemuxer() = default;

  IamfDemuxer(const IamfDemuxer&) = delete;
  IamfDemuxer& operator=(const IamfDemuxer&) = delete;

  // Cheap content sniff: true if `bytes` looks like an ISOBMFF container
  // (a top-level `ftyp` box type at offset 4). Lets callers pick the MP4
  // path over the raw-IAMF path without opening the file twice. A raw IAMF
  // bitstream begins with an OBU header, never ASCII "ftyp" at offset 4.
  static bool IsIsoBmff(const uint8_t* bytes, size_t len);

  // Demux the `iamf` track of `input_mp4` into a standalone IAMF bitstream
  // appended to `*out_bytes`. Returns true on success; on failure returns
  // false, leaves `*out_bytes` as it was, and sets last_error() (with the
  // usual upstream-style prefix: "io:" / "unsupported:" / "malformed:" /
  // "invalid_argument:").
  bool DemuxToBytes(const std::string& input_mp4,
                    std::vector<uint8_t>* out_bytes);

  // Read the descriptor OBUs of the `iamf` track of `input_mp4` and the file
  // offset and size of every sample, without reading sample data. Returns
  // false and sets last_error() on failure. When the failure is that sample
  // data is stored in another file (an external data reference), also sets
  // sample_data_external(); DemuxToBytes can still read such a track.
  bool IndexTrack(const std::string& input_mp4, IamfTrackIndex* out_index);

  const std::string& last_error() const { return last_error_; }
  // True when the last IndexTrack failed because sample data is stored in
  // another file.
  bool sample_data_external() const { return sample_data_external_; }

 private:
  std::string last_error_;
  bool sample_data_external_ = false;
};

// An IAMF-in-MP4 file prepared for reading in place: the MP4 mapped
// read-only and its IAMF bitstream described as byte ranges, the descriptor
// OBUs first and then the sample payloads in the mapping, in sample order.
// Reading the ranges in order yields the bytes DemuxToBytes produces, but
// no sample is copied, so opening costs the sample table, not the track.
//
// The ranges stay valid until close() or destruction. Truncating the file
// while the ranges are read can fault (SIGBUS on POSIX), as with any
// mapping. Not copyable or movable: the ranges point into members.
class IamfMp4Source {
 public:
  IamfMp4Source() = default;
  ~IamfMp4Source() = default;

  IamfMp4Source(const IamfMp4Source&) = delete;
  IamfMp4Source& operator=(const IamfMp4Source&) = delete;

  // Index and map `path`. Returns false and, if `err` is non-null, fills it
  // (prefixed as for IamfDemuxer) when the track cannot be indexed, the file
  // cannot be mapped, or a sample lies outside the file. If
  // `sample_data_external` is non-null it is set to whether the failure is
  // sample data stored in another file, the one case where
  // IamfDemuxer::DemuxToBytes can still read the track.
  bool open(const std::string& path, std::string* err,
            bool* sample_data_external = nullptr);

  // Release the ranges and the mapping. Idempotent.
  void close();

  const std::vector<absl::Span<const uint8_t>>& segments() const {
    return segments_;
  }
  // Size of the IAMF bitstream the ranges describe.
  uint64_t size_bytes() const { return total_bytes_; }

 private:
  // Declared before `segments_`, which points into both.
  IamfTrackIndex index_;
  ReadOnlyFileMap map_;
  std::vector<absl::Span<const uint8_t>> segments_;
  uint64_t total_bytes_ = 0;
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_DEMUXER_H_
