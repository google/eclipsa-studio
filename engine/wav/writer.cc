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

#include "wav/writer.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <ios>
#include <string>
#include <utility>
#include <vector>

#include "wav/convert.h"
#include "wav/internal.h"

namespace wav {
namespace {

using internal::kSize32Max;
using internal::kTagExtensible;
using internal::kTagIeeeFloat;
using internal::kTagPcm;
using internal::PutU16;
using internal::PutU32;
using internal::PutU64;

constexpr uint64_t kDs64PayloadBytes = 28;  // riff+data+sampleCount+table len.

// Ceiling on each metadata chunk the writer accepts — matches the reader's
// kMaxBufferedChunkBytes, so the writer never emits a file its own reader
// refuses to open.
constexpr uint64_t kMaxMetadataChunkBytes = uint64_t{1} << 28;

// Bounded conversion scratch: block frame count derived from this, so wide
// channel counts don't balloon memory.
constexpr size_t kScratchBytes = size_t{1} << 20;

void AppendBytes(std::vector<uint8_t>& v, const void* p, size_t n) {
  const auto* b = static_cast<const uint8_t*>(p);
  v.insert(v.end(), b, b + n);
}

void AppendU16(std::vector<uint8_t>& v, uint16_t x) {
  uint8_t b[2];
  PutU16(b, x);
  AppendBytes(v, b, 2);
}

void AppendU32(std::vector<uint8_t>& v, uint32_t x) {
  uint8_t b[4];
  PutU32(b, x);
  AppendBytes(v, b, 4);
}

// Appends a whole chunk (id + size + payload + pad byte when odd).
void AppendChunk(std::vector<uint8_t>& v, const char* id, const void* payload,
                 size_t n) {
  AppendBytes(v, id, 4);
  AppendU32(v, static_cast<uint32_t>(n));
  AppendBytes(v, payload, n);
  if (n & 1) v.push_back(0);
}

int OutBytesPerSample(WriteFormat f) {
  switch (f) {
    case WriteFormat::kPcm16:
      return 2;
    case WriteFormat::kPcm24:
      return 3;
    case WriteFormat::kPcm32:
    case WriteFormat::kFloat32:
      return 4;
  }
  return 2;
}

uint16_t FormatTag(WriteFormat f) {
  return f == WriteFormat::kFloat32 ? kTagIeeeFloat : kTagPcm;
}

}  // namespace

Result<Writer> Writer::Create(const std::string& path,
                              const WriterOptions& options) {
  if (options.channels == 0) {
    return Status::Error("Writer needs at least one channel.");
  }
  if (options.sample_rate == 0) {
    return Status::Error("Writer needs a non-zero sample rate.");
  }
  // The `fmt ` fields nBlockAlign (u16) and nAvgBytesPerSec (u32) must be
  // representable; beyond these bounds the WAV format cannot express the
  // stream and the header would silently wrap.
  const uint64_t frame_bytes = static_cast<uint64_t>(options.channels) *
                               OutBytesPerSample(options.format);
  if (frame_bytes > 0xFFFF) {
    return Status::Error("Channel count exceeds the WAV block-align limit.");
  }
  if (options.sample_rate * frame_bytes > 0xFFFFFFFFull) {
    return Status::Error("Sample rate x frame size exceeds the WAV limit.");
  }
  if (options.metadata.axml.size() > kMaxMetadataChunkBytes ||
      options.metadata.chna.size() > kMaxMetadataChunkBytes ||
      options.metadata.bext.size() > kMaxMetadataChunkBytes) {
    return Status::Error("Metadata chunk exceeds the size limit.");
  }

  Writer w;
  w.path_ = path;
  w.options_ = options;
  w.extensible_ = options.force_extensible || options.channels > 2 ||
                  options.channel_mask != 0;
  // No mask is guessed from the channel count: a 4-channel file can as
  // easily be first-order ambisonics as quad, and a wrong loudspeaker
  // claim misroutes the file in third-party tools. Mask 0 is the spec's
  // "unspecified" and every consumer accepts it; callers that know the
  // layout pass channel_mask explicitly.
  w.channel_mask_ = options.channel_mask;

  internal::OpenBinaryOutput(w.file_, path);
  if (!w.file_) {
    return Status::Error("Cannot create WAV file: " + path);
  }
  w.open_ = true;
  if (auto s = w.WriteHeader(); !s.ok()) return s;
  return w;
}

Writer::Writer(Writer&& other) noexcept
    : path_(std::move(other.path_)),
      file_(std::move(other.file_)),
      options_(std::move(other.options_)),
      open_(other.open_),
      finalized_(other.finalized_),
      extensible_(other.extensible_),
      upgraded_(other.upgraded_),
      channel_mask_(other.channel_mask_),
      size_limit_(other.size_limit_),
      riff_size_offset_(other.riff_size_offset_),
      ds64_offset_(other.ds64_offset_),
      data_header_offset_(other.data_header_offset_),
      data_payload_offset_(other.data_payload_offset_),
      data_bytes_(other.data_bytes_),
      frames_written_(other.frames_written_),
      scratch_(std::move(other.scratch_)) {
  // The source no longer owns the file: mark it closed so pushes fail and
  // its destructor doesn't try to finalize.
  other.open_ = false;
  other.finalized_ = true;
}

Writer::~Writer() {
  // Best-effort finalize; a moved-from writer's stream is no longer open.
  if (open_ && !finalized_ && file_.is_open()) {
    Finalize();
  }
}

Container Writer::container() const {
  if (!upgraded_) return Container::kRiff;
  const bool bw64 =
      options_.container == WriterOptions::ContainerPolicy::kBw64 ||
      (options_.container == WriterOptions::ContainerPolicy::kAuto &&
       !options_.metadata.empty());
  return bw64 ? Container::kBw64 : Container::kRf64;
}

Status Writer::WriteHeader() {
  const bool forced64 =
      options_.container != WriterOptions::ContainerPolicy::kAuto;
  upgraded_ = forced64;

  std::vector<uint8_t> h;
  h.reserve(256 + options_.metadata.axml.size() +
            options_.metadata.chna.size() + options_.metadata.bext.size());

  // RIFF header. Sizes are placeholders; PatchHeader() fills them in.
  AppendBytes(
      h,
      upgraded_ ? (container() == Container::kBw64 ? "BW64" : "RF64") : "RIFF",
      4);
  AppendU32(h, upgraded_ ? kSize32Max : 0);
  AppendBytes(h, "WAVE", 4);

  // ds64 (64-bit containers) or an equal-sized JUNK placeholder that an
  // upgrade converts in place.
  ds64_offset_ = h.size();
  AppendBytes(h, upgraded_ ? "ds64" : "JUNK", 4);
  AppendU32(h, static_cast<uint32_t>(kDs64PayloadBytes));
  h.insert(h.end(), kDs64PayloadBytes, 0);

  // Metadata chunks ahead of fmt, so their offsets never move.
  const Metadata& md = options_.metadata;
  if (!md.bext.empty()) AppendChunk(h, "bext", md.bext.data(), md.bext.size());
  if (!md.axml.empty()) AppendChunk(h, "axml", md.axml.data(), md.axml.size());
  if (!md.chna.empty()) AppendChunk(h, "chna", md.chna.data(), md.chna.size());

  // fmt chunk.
  const uint16_t bits =
      static_cast<uint16_t>(OutBytesPerSample(options_.format) * 8);
  const uint16_t block_align = static_cast<uint16_t>(
      options_.channels * OutBytesPerSample(options_.format));
  const uint32_t byte_rate = options_.sample_rate * block_align;
  const uint16_t tag = FormatTag(options_.format);
  if (extensible_) {
    AppendBytes(h, "fmt ", 4);
    AppendU32(h, 40);
    AppendU16(h, kTagExtensible);
    AppendU16(h, options_.channels);
    AppendU32(h, options_.sample_rate);
    AppendU32(h, byte_rate);
    AppendU16(h, block_align);
    AppendU16(h, bits);
    AppendU16(h, 22);    // cbSize
    AppendU16(h, bits);  // wValidBitsPerSample
    AppendU32(h, channel_mask_);
    // Sub-format GUID: tag in the first two bytes, then the fixed
    // KSDATAFORMAT media-subtype tail.
    AppendU16(h, tag);
    static constexpr uint8_t kGuidTail[14] = {0x00, 0x00, 0x00, 0x00, 0x10,
                                              0x00, 0x80, 0x00, 0x00, 0xAA,
                                              0x00, 0x38, 0x9B, 0x71};
    AppendBytes(h, kGuidTail, sizeof(kGuidTail));
  } else {
    // Plain fmt. Non-PCM formats carry the (zero) cbSize field per spec.
    const bool with_cb = tag != kTagPcm;
    AppendBytes(h, "fmt ", 4);
    AppendU32(h, with_cb ? 18 : 16);
    AppendU16(h, tag);
    AppendU16(h, options_.channels);
    AppendU32(h, options_.sample_rate);
    AppendU32(h, byte_rate);
    AppendU16(h, block_align);
    AppendU16(h, bits);
    if (with_cb) AppendU16(h, 0);
  }

  // data chunk header; payload streams from here.
  data_header_offset_ = h.size();
  AppendBytes(h, "data", 4);
  AppendU32(h, upgraded_ ? kSize32Max : 0);
  data_payload_offset_ = h.size();

  return WriteBytes(h.data(), h.size());
}

Status Writer::WriteBytes(const uint8_t* p, size_t n) {
  file_.write(reinterpret_cast<const char*>(p),
              static_cast<std::streamsize>(n));
  if (!file_) {
    return Status::Error("Write failed (disk full?): " + path_);
  }
  return Status();
}

Status Writer::PushConverted(uint64_t frames, const float* const* fch,
                             const int32_t* const* ich) {
  if (!open_ || finalized_ || !file_.is_open()) {
    return Status::Error("Writer is closed.");
  }
  if (fch == nullptr && ich == nullptr) {
    return Status::Error("Null sample pointers.");
  }
  if (frames == 0) return Status();

  const uint16_t nch = options_.channels;
  const int out_bps = OutBytesPerSample(options_.format);
  const size_t frame_bytes = static_cast<size_t>(nch) * out_bps;
  const uint64_t block_frames =
      std::max<uint64_t>(1, kScratchBytes / frame_bytes);
  scratch_.resize(static_cast<size_t>(std::min<uint64_t>(frames, block_frames) *
                                      frame_bytes));

  uint64_t done = 0;
  while (done < frames) {
    const uint64_t n = std::min(frames - done, block_frames);
    uint8_t* dst = scratch_.data();
    for (uint64_t i = 0; i < n; ++i) {
      for (uint16_t c = 0; c < nch; ++c) {
        uint8_t* out = dst + (static_cast<size_t>(i) * nch + c) * out_bps;
        int32_t code = 0;
        float fval = 0.0f;
        switch (options_.format) {
          case WriteFormat::kPcm16:
            code = fch ? FloatToInt16Code(fch[c][done + i])
                       : Int32LjToInt16Code(ich[c][done + i]);
            PutU16(out, static_cast<uint16_t>(static_cast<int16_t>(code)));
            break;
          case WriteFormat::kPcm24:
            code = fch ? FloatToInt24Code(fch[c][done + i])
                       : Int32LjToInt24Code(ich[c][done + i]);
            out[0] = static_cast<uint8_t>(code & 0xFF);
            out[1] = static_cast<uint8_t>((code >> 8) & 0xFF);
            out[2] = static_cast<uint8_t>((code >> 16) & 0xFF);
            break;
          case WriteFormat::kPcm32:
            code = fch ? FloatToInt32Code(fch[c][done + i]) : ich[c][done + i];
            PutU32(out, static_cast<uint32_t>(code));
            break;
          case WriteFormat::kFloat32: {
            // Sanitize even though no quantizer runs on this path: the
            // documented contract is NaN -> 0 / ±inf saturated, and one
            // unsanitized NaN in a bounce would permanently poison the
            // deliverable for every downstream consumer.
            fval = fch ? SanitizeFloatSample(fch[c][done + i])
                       : Int32LjToFloat(ich[c][done + i]);
            uint32_t b;
            std::memcpy(&b, &fval, sizeof(b));
            PutU32(out, b);
            break;
          }
        }
      }
    }
    if (auto s =
            WriteBytes(scratch_.data(), static_cast<size_t>(n) * frame_bytes);
        !s.ok()) {
      return s;
    }
    data_bytes_ += n * frame_bytes;
    frames_written_ += n;
    done += n;
  }
  return Status();
}

Status Writer::PushPlanarFloat(const float* const* channels, uint64_t frames) {
  return PushConverted(frames, channels, nullptr);
}

Status Writer::PushPlanarFloat(
    const std::vector<std::vector<float>>& channels) {
  if (channels.size() != options_.channels) {
    return Status::Error("Channel count mismatch in PushPlanarFloat.");
  }
  std::vector<const float*> ptrs(channels.size());
  uint64_t frames = channels.empty() ? 0 : channels[0].size();
  for (size_t c = 0; c < channels.size(); ++c) {
    if (channels[c].size() != frames) {
      return Status::Error("Ragged channel lengths in PushPlanarFloat.");
    }
    ptrs[c] = channels[c].data();
  }
  return PushPlanarFloat(ptrs.data(), frames);
}

Status Writer::PushPlanarInt32LeftJustified(const int32_t* const* channels,
                                            uint64_t frames) {
  return PushConverted(frames, nullptr, channels);
}

Status Writer::PushPlanarInt32LeftJustified(
    const std::vector<std::vector<int32_t>>& channels) {
  if (channels.size() != options_.channels) {
    return Status::Error(
        "Channel count mismatch in PushPlanarInt32LeftJustified.");
  }
  std::vector<const int32_t*> ptrs(channels.size());
  uint64_t frames = channels.empty() ? 0 : channels[0].size();
  for (size_t c = 0; c < channels.size(); ++c) {
    if (channels[c].size() != frames) {
      return Status::Error(
          "Ragged channel lengths in PushPlanarInt32LeftJustified.");
    }
    ptrs[c] = channels[c].data();
  }
  return PushPlanarInt32LeftJustified(ptrs.data(), frames);
}

Status Writer::PatchHeader(bool pad_on_disk) {
  const uint64_t pad = pad_on_disk ? (data_bytes_ & 1) : 0;
  const uint64_t data_end = data_payload_offset_ + data_bytes_;
  const uint64_t riff_size = data_end + pad - 8;

  // >= keeps the 0xFFFFFFFF sentinel value itself unrepresentable as a real
  // size. The data_bytes_ clause is belt-and-braces: riff_size necessarily
  // crosses the limit first (the header precedes the data).
  if (!upgraded_ && (riff_size >= size_limit_ || data_bytes_ >= size_limit_)) {
    upgraded_ = true;  // Sticky: a file never downgrades.
  }

  uint8_t buf[kDs64PayloadBytes];
  if (upgraded_) {
    const bool bw64 = container() == Container::kBw64;
    file_.seekp(static_cast<std::streamoff>(riff_size_offset_) - 4);
    file_.write(bw64 ? "BW64" : "RF64", 4);
    PutU32(buf, kSize32Max);
    file_.write(reinterpret_cast<const char*>(buf), 4);

    file_.seekp(static_cast<std::streamoff>(ds64_offset_));
    file_.write("ds64", 4);
    PutU32(buf, static_cast<uint32_t>(kDs64PayloadBytes));
    file_.write(reinterpret_cast<const char*>(buf), 4);
    PutU64(buf, riff_size);
    PutU64(buf + 8, data_bytes_);
    PutU64(buf + 16, frames_written_);
    PutU32(buf + 24, 0);  // ds64 table length.
    file_.write(reinterpret_cast<const char*>(buf), kDs64PayloadBytes);

    file_.seekp(static_cast<std::streamoff>(data_header_offset_ + 4));
    PutU32(buf, kSize32Max);
    file_.write(reinterpret_cast<const char*>(buf), 4);
  } else {
    file_.seekp(static_cast<std::streamoff>(riff_size_offset_));
    PutU32(buf, static_cast<uint32_t>(riff_size));
    file_.write(reinterpret_cast<const char*>(buf), 4);

    file_.seekp(static_cast<std::streamoff>(data_header_offset_ + 4));
    PutU32(buf, static_cast<uint32_t>(data_bytes_));
    file_.write(reinterpret_cast<const char*>(buf), 4);
  }

  // Back to the append position for subsequent pushes.
  file_.seekp(static_cast<std::streamoff>(data_end + pad));
  if (!file_) {
    return Status::Error("Header patch failed: " + path_);
  }
  return Status();
}

Status Writer::Flush() {
  if (!open_ || finalized_ || !file_.is_open()) {
    return Status::Error("Writer is closed.");
  }
  if (auto s = PatchHeader(/*pad_on_disk=*/false); !s.ok()) return s;
  file_.flush();
  if (!file_) {
    return Status::Error("Flush failed: " + path_);
  }
  return Status();
}

Status Writer::Finalize() {
  if (finalized_) return Status();
  if (!open_ || !file_.is_open()) {
    return Status::Error("Writer is closed.");
  }
  finalized_ = true;  // Even a failed finalize ends the writer's life.
  if (data_bytes_ & 1) {
    const uint8_t zero = 0;
    if (auto s = WriteBytes(&zero, 1); !s.ok()) return s;
  }
  if (auto s = PatchHeader(/*pad_on_disk=*/true); !s.ok()) return s;
  file_.close();
  open_ = false;
  if (!file_) {
    return Status::Error("Close failed: " + path_);
  }
  return Status();
}

}  // namespace wav
