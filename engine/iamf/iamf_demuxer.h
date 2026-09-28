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

namespace eclipsa_studio {

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
  // false and sets last_error() (with the usual upstream-style prefix:
  // "io:" / "unsupported:" / "malformed:" / "invalid_argument:").
  bool DemuxToBytes(const std::string& input_mp4,
                    std::vector<uint8_t>* out_bytes);

  const std::string& last_error() const { return last_error_; }

 private:
  std::string last_error_;
};

// Process-wide single-slot handoff for the QC-open flow, which demuxes the same
// IAMF-in-MP4 twice in quick succession — once on the probe isolate
// (`eclipsa_studio_iamf_probe`) and once on the engine session
// (`eclipsa_studio_playback_open`) — re-parsing the whole container both
// times.
// The probe stashes its freshly-demuxed bitstream here and the session takes it
// instead of demuxing again (ES-215). The probe runs on a Dart `compute` isolate,
// which dlopens this same dylib image, so the slot (a C++ static) is shared
// across the isolate boundary and outlives the probe isolate. Thread-safe;
// holds at most one file's bytes.
//
// [StashIamfDemux] always overwrites: the producer (probe) re-parses on every
// call, so the slot reflects the file exactly as just seen — no stale-content
// risk even if the same path was re-exported between opens. [TakeIamfDemux]
// moves the bytes out and clears the slot on a path match (single use), so a
// consumer not preceded by a matching stash simply falls through to a fresh
// demux.
void StashIamfDemux(const std::string& path, const std::vector<uint8_t>& bytes);
bool TakeIamfDemux(const std::string& path, std::vector<uint8_t>* out);

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_DEMUXER_H_
