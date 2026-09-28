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
// WAV writer: int16/int24/int32 PCM and float32 output, plain or
// WAVE_FORMAT_EXTENSIBLE `fmt ` (with channel masks), ADM metadata chunks
// (`bext`, `axml`, `chna`) written up front, and automatic container
// upgrade: files start as RIFF (with a JUNK placeholder reserving `ds64`
// space) and are transparently rewritten as RF64 — or BW64 when ADM
// metadata is present — the moment their size crosses the 32-bit RIFF
// ceiling. No silent 4 GiB wraparound, ever.
//
// Contract: after every Flush() the file on disk is a complete, valid WAV
// for the frames pushed so far. Finalize() writes the trailing pad byte,
// patches the header one last time and closes the file.
//
// Samples are accepted planar in either delivery convention:
//   - normalized float32 in [-1, 1]  (PushPlanarFloat) — quantized with the
//     canonical wav/convert.h quantizer (lrint round-to-nearest, symmetric
//     clamp, NaN → 0)
//   - left-justified int32           (PushPlanarInt32LeftJustified) — exact
//     for targets at least as deep as the source's significant bits

#ifndef ECLIPSA_STUDIO_WAV_WRITER_H_
#define ECLIPSA_STUDIO_WAV_WRITER_H_

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include "wav/result.h"
#include "wav/types.h"

namespace wav {

// Output sample encodings. (uint8 and float64 are read-side only: nothing
// should author new 8-bit or double-precision WAVs.)
enum class WriteFormat : uint8_t {
  kPcm16,
  kPcm24,
  kPcm32,
  kFloat32,
};

inline SampleFormat ToSampleFormat(WriteFormat f) {
  switch (f) {
    case WriteFormat::kPcm16:
      return SampleFormat::kInt16;
    case WriteFormat::kPcm24:
      return SampleFormat::kInt24;
    case WriteFormat::kPcm32:
      return SampleFormat::kInt32;
    case WriteFormat::kFloat32:
      return SampleFormat::kFloat32;
  }
  return SampleFormat::kInt16;
}

struct WriterOptions {
  uint16_t channels = 0;
  uint32_t sample_rate = 0;
  WriteFormat format = WriteFormat::kPcm24;

  // Written verbatim as `bext`/`axml`/`chna` chunks ahead of `fmt `.
  Metadata metadata;

  // kAuto starts as RIFF and upgrades to RF64 (or BW64 when metadata is
  // present) past the 32-bit ceiling. kRf64/kBw64 force the 64-bit
  // container from the start.
  enum class ContainerPolicy : uint8_t { kAuto, kRf64, kBw64 };
  ContainerPolicy container = ContainerPolicy::kAuto;

  // Plain `fmt ` is written for mono/stereo; WAVE_FORMAT_EXTENSIBLE for
  // > 2 channels, when a channel_mask is given, or when forced here.
  bool force_extensible = false;
  // dwChannelMask for the extensible `fmt `, written verbatim. 0 (the
  // spec's "unspecified") stays 0 — no mask is guessed from the channel
  // count, because e.g. a 4-channel file can as easily be first-order
  // ambisonics as quad, and a wrong loudspeaker claim misroutes the
  // file in third-party tools. A caller that knows the layout can set
  // it here (note the io/ and adm_import/ adapter open() paths do not
  // currently plumb a mask through — add a parameter there if one ever
  // needs it).
  uint32_t channel_mask = 0;
};

class Writer {
 public:
  static Result<Writer> Create(const std::string& path,
                               const WriterOptions& options);

  // Move-constructible only; finalizes on destruction if still open
  // (best-effort — call Finalize() explicitly to observe errors). The
  // moved-from writer becomes closed: pushes and Flush() on it fail,
  // Finalize() is a no-op. Move *assignment* is deleted — it would close
  // the destination's half-written file without patching its header.
  Writer(Writer&& other) noexcept;
  Writer& operator=(Writer&&) = delete;
  Writer(const Writer&) = delete;
  Writer& operator=(const Writer&) = delete;
  ~Writer();

  // Appends `frames` planar float samples (channels[c][i], c in
  // [0, channels)). Values are quantized/encoded per the output format.
  Status PushPlanarFloat(const float* const* channels, uint64_t frames);
  Status PushPlanarFloat(const std::vector<std::vector<float>>& channels);

  // Appends `frames` planar left-justified int32 samples.
  Status PushPlanarInt32LeftJustified(const int32_t* const* channels,
                                      uint64_t frames);
  Status PushPlanarInt32LeftJustified(
      const std::vector<std::vector<int32_t>>& channels);

  // Patches the header so the file on disk is a complete, valid WAV for
  // everything pushed so far, then flushes. More frames may follow.
  Status Flush();

  // Pad byte + final header patch + close. The writer is unusable after.
  Status Finalize();

  uint64_t frames_written() const { return frames_written_; }
  const std::string& path() const { return path_; }
  // The container the header currently declares (upgrades are sticky).
  Container container() const;

  // Testing seam: lowers the 32-bit size ceiling that triggers the
  // RF64/BW64 upgrade, so the upgrade path is exercised with small files
  // instead of > 4 GiB ones. Production code must not call this.
  void set_size_limit_for_testing(uint64_t bytes) { size_limit_ = bytes; }

 private:
  Writer() = default;

  Status WriteHeader();  // Emits the initial header layout.
  // Rewrites sizes (and, on upgrade, the container). `pad_on_disk` says
  // whether the odd-data-size pad byte has been written (Finalize only).
  Status PatchHeader(bool pad_on_disk);
  Status WriteBytes(const uint8_t* p, size_t n);
  Status PushConverted(uint64_t frames, const float* const* fch,
                       const int32_t* const* ich);

  std::string path_;
  std::ofstream file_;
  WriterOptions options_;
  bool open_ = false;
  bool finalized_ = false;
  bool extensible_ = false;
  bool upgraded_ = false;  // Header currently declares RF64/BW64.
  uint32_t channel_mask_ = 0;
  uint64_t size_limit_ = 0xFFFFFFFFull;

  uint64_t riff_size_offset_ = 4;    // Offset of the 32-bit RIFF size field.
  uint64_t ds64_offset_ = 0;         // Offset of the ds64/JUNK chunk id.
  uint64_t data_header_offset_ = 0;  // Offset of the `data` chunk id.
  uint64_t data_payload_offset_ = 0;
  uint64_t data_bytes_ = 0;
  uint64_t frames_written_ = 0;

  std::vector<uint8_t> scratch_;
};

}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_WRITER_H_
