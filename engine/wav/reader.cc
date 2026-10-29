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

#include "wav/reader.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <ios>
#include <limits>
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
using internal::ReadExactly;
using internal::ReadU16;
using internal::ReadU32;
using internal::ReadU64;
using internal::SanitizeChunkId;

// `fmt ` and `ds64` are small, spec-bounded chunks; a declared size beyond
// this is hostile, so reject it before the buffering allocation.
constexpr uint64_t kMaxStructuralChunkBytes = 4096;

std::string ChunkError(const char* id, const std::string& what) {
  return "Chunk '" + SanitizeChunkId(id) + "': " + what;
}

// Maps a resolved (tag, bits) pair to a SampleFormat, or an error.
Result<SampleFormat> ResolveFormat(uint16_t tag, uint16_t bits) {
  if (tag == kTagPcm) {
    switch (bits) {
      case 8:
        return SampleFormat::kUint8;
      case 16:
        return SampleFormat::kInt16;
      case 24:
        return SampleFormat::kInt24;
      case 32:
        return SampleFormat::kInt32;
      default:
        return Status::Error("Unsupported PCM bit depth: " +
                             std::to_string(bits));
    }
  }
  if (tag == kTagIeeeFloat) {
    switch (bits) {
      case 32:
        return SampleFormat::kFloat32;
      case 64:
        return SampleFormat::kFloat64;
      default:
        return Status::Error("Unsupported IEEE-float bit depth: " +
                             std::to_string(bits));
    }
  }
  return Status::Error("Unsupported format tag: " + std::to_string(tag));
}

int32_t SignExtend24(const uint8_t* p) {
  uint32_t u = static_cast<uint32_t>(p[0]) |
               (static_cast<uint32_t>(p[1]) << 8) |
               (static_cast<uint32_t>(p[2]) << 16);
  if (u & 0x800000u) u |= 0xFF000000u;
  return static_cast<int32_t>(u);
}

float ReadF32(const uint8_t* p) {
  const uint32_t bits = ReadU32(p);
  float v;
  std::memcpy(&v, &bits, sizeof(v));
  return v;
}

double ReadF64(const uint8_t* p) {
  const uint64_t bits = ReadU64(p);
  double v;
  std::memcpy(&v, &bits, sizeof(v));
  return v;
}

// Decodes interleaved raw bytes into planar destinations with a per-sample
// decoder. Works in tiles of kTile frames, one channel at a time within a
// tile, so each destination is written sequentially while the tile's source
// bytes stay in cache. At 54 channels of 24-bit audio this takes 0.41 ns per
// sample; a frame-by-frame loop that writes every channel per frame took
// 4.17 ns.
template <typename OutT, typename DecodeFn>
void DecodePlanar(const uint8_t* raw, uint16_t channels, int bytes_per_sample,
                  uint64_t frames, OutT* const* out, DecodeFn decode) {
  constexpr uint64_t kTile = 256;
  const size_t frame_bytes =
      static_cast<size_t>(channels) * static_cast<size_t>(bytes_per_sample);
  for (uint64_t n0 = 0; n0 < frames; n0 += kTile) {
    const uint64_t n1 = std::min<uint64_t>(frames, n0 + kTile);
    for (uint16_t c = 0; c < channels; ++c) {
      OutT* dst = out[c];
      const uint8_t* src = raw + static_cast<size_t>(c) * bytes_per_sample;
      for (uint64_t n = n0; n < n1; ++n) {
        dst[n] = decode(src + static_cast<size_t>(n) * frame_bytes);
      }
    }
  }
}

}  // namespace

Result<Reader> Reader::Open(const std::string& path, OpenMode mode) {
  const bool lenient = mode == OpenMode::kLenient;
  Reader reader;
  internal::OpenBinaryInput(reader.file_, path);
  if (!reader.file_) {
    return Status::Error("Cannot open WAV file: " + path);
  }
  std::istream& in = reader.file_;

  // File size up front, to validate every chunk's declared size before
  // trusting it: a hostile or truncated chunk header can declare a payload
  // far larger than the file, which would otherwise drive a huge allocation
  // or a silently short parse.
  in.seekg(0, std::ios::end);
  const std::streampos end_pos = in.tellg();
  if (end_pos < 0) {
    return Status::Error("Cannot determine WAV file size.");
  }
  const auto file_size = static_cast<uint64_t>(end_pos);
  in.seekg(0, std::ios::beg);

  // RIFF/RF64/BW64 header: magic(4), size(4), "WAVE"(4).
  std::array<char, 12> header = {};
  if (!ReadExactly(in, header.data(), 12)) {
    return Status::Error("File too small for a RIFF header.");
  }
  if (std::memcmp(header.data(), "RIFF", 4) == 0) {
    reader.info_.container = Container::kRiff;
  } else if (std::memcmp(header.data(), "RF64", 4) == 0) {
    reader.info_.container = Container::kRf64;
  } else if (std::memcmp(header.data(), "BW64", 4) == 0) {
    reader.info_.container = Container::kBw64;
  } else {
    return Status::Error("Missing RIFF/RF64/BW64 magic.");
  }
  if (std::memcmp(header.data() + 8, "WAVE", 4) != 0) {
    return Status::Error("Missing WAVE form type.");
  }
  const bool is64 = reader.info_.container != Container::kRiff;

  bool have_ds64 = false;
  bool have_fmt = false;
  bool have_data = false;
  uint64_t ds64_data_size = 0;

  // Walk the chunk list.
  while (true) {
    std::array<char, 8> ch = {};
    in.read(ch.data(), 8);
    const std::streamsize got = in.gcount();
    // A genuine I/O error (badbit) is not EOF — fail closed rather than
    // treating a truncated-by-error read as the end of the chunk list.
    if (in.bad()) {
      return Status::Error("I/O error while reading WAV chunks.");
    }
    if (got == 0) break;  // Clean EOF between chunks.
    if (got < 8) {
      // 1–7 stray bytes cannot be a chunk; RIFF word alignment means a
      // well-formed file never ends this way. Lenient: once `data` is
      // in hand, a stray tail is cosmetic — stop the walk instead.
      if (lenient && have_data) {
        reader.recovered_ = true;
        break;
      }
      return Status::Error("Trailing bytes after the last chunk.");
    }
    const char* id = ch.data();
    uint64_t size = ReadU32(reinterpret_cast<const uint8_t*>(ch.data() + 4));
    const std::streampos chunk_pos = in.tellg();
    if (chunk_pos < 0) {
      return Status::Error("Cannot determine WAV chunk position.");
    }
    const auto payload_pos = static_cast<uint64_t>(chunk_pos);
    const uint64_t remaining =
        payload_pos <= file_size ? file_size - payload_pos : 0;

    auto is = [&](const char* tag) { return std::memcmp(id, tag, 4) == 0; };
    auto ensure_fits = [&](uint64_t n) -> Status {
      if (n > remaining) {
        return Status::Error(ChunkError(
            id, "declares " + std::to_string(n) + " bytes but only " +
                    std::to_string(remaining) + " remain in the file."));
      }
      return Status();
    };
    auto ensure_bufferable = [&](uint64_t n) -> Status {
      if (auto s = ensure_fits(n); !s.ok()) return s;
      if (n > kMaxBufferedChunkBytes) {
        return Status::Error(
            ChunkError(id, "exceeds the buffered-chunk limit."));
      }
      return Status();
    };

    // The per-chunk handling reports through a Status so lenient mode
    // can turn "malformed chunk after `data` is already in hand" into a
    // clean end of the walk (keeping everything parsed so far) instead
    // of failing the open.
    const auto parse_chunk = [&]() -> Status {
      if (is("data")) {
        if (have_data) return Status::Error("Duplicate `data` chunk.");
        if (!have_fmt) {
          return Status::Error("`fmt ` chunk must precede `data`.");
        }
        // The data-size recoveries below apply to plain RIFF only.
        // Absorbing "the rest of the file" into the payload swallows
        // any chunk after `data` — and in the 64-bit containers that
        // is where broadcast tools put `axml`/`chna`, so a damaged
        // BW64/RF64 master would come back as a longer plain WAV with
        // its ADM metadata decoded as audio. Those containers fail
        // even leniently; RIFF (where trailing metadata is rare and
        // unpatched streaming headers are common) recovers.
        if (size == kSize32Max) {
          if (is64 && have_ds64) {
            size = ds64_data_size;
          } else if (lenient && !is64) {
            // Non-seekable streaming writers leave the 0xFFFFFFFF
            // placeholder unpatched; the payload is the rest of the file.
            size = remaining;
            reader.recovered_ = true;
          } else if (!is64) {
            return Status::Error("RIFF `data` chunk of unknown size.");
          } else {
            return Status::Error(
                "RF64/BW64 `data` of unknown size needs a `ds64` chunk "
                "before it.");
          }
        }
        // Validate against the file so num_frames cannot claim more frames
        // than exist. Lenient RIFF: a payload declaring more than remains
        // on disk (interrupted recording, partial copy) is clamped to what
        // exists — recoverable data loss, not a parse failure.
        if (size > remaining) {
          if (lenient && !is64) {
            size = remaining;
            reader.recovered_ = true;
          } else if (auto s = ensure_fits(size); !s.ok()) {
            return s;
          }
        }
        have_data = true;
        reader.data_offset_ = payload_pos;
        reader.data_size_ = size;
      } else if (is("fmt ")) {
        if (have_fmt) return Status::Error("Duplicate `fmt ` chunk.");
        if (auto s = ensure_bufferable(size); !s.ok()) return s;
        if (size < 16) {
          return Status::Error("Truncated `fmt ` chunk.");
        }
        if (size > kMaxStructuralChunkBytes) {
          return Status::Error("Implausibly large `fmt ` chunk.");
        }
        std::vector<char> buf(static_cast<size_t>(size));
        if (!ReadExactly(in, buf.data(), static_cast<std::streamsize>(size))) {
          return Status::Error("Truncated `fmt ` chunk.");
        }
        const auto* p = reinterpret_cast<const uint8_t*>(buf.data());
        uint16_t tag = ReadU16(p);
        const uint16_t channels = ReadU16(p + 2);
        const uint32_t sample_rate = ReadU32(p + 4);
        const uint16_t bits = ReadU16(p + 14);
        if (tag == kTagExtensible) {
          // A real WAVE_FORMAT_EXTENSIBLE `fmt ` is >= 40 bytes; a shorter one
          // is malformed. Reject it rather than silently treating its (unread)
          // sub-format as integer PCM.
          if (size < 40) {
            return Status::Error(
                "Truncated WAVE_FORMAT_EXTENSIBLE `fmt ` chunk.");
          }
          reader.info_.extensible = true;
          reader.info_.valid_bits = ReadU16(p + 18);
          reader.info_.channel_mask = ReadU32(p + 20);
          // The sub-format GUID's first 2 bytes carry the real tag.
          tag = ReadU16(p + 24);
        }
        if (channels == 0) {
          return Status::Error("Invalid `fmt ` chunk: zero channels.");
        }
        if (sample_rate == 0) {
          return Status::Error("Invalid `fmt ` chunk: zero sample rate.");
        }
        auto format = ResolveFormat(tag, bits);
        if (!format.ok()) return format.status();
        reader.info_.format = *format;
        reader.info_.channels = channels;
        reader.info_.sample_rate = sample_rate;
        have_fmt = true;
      } else if (is("ds64") && is64) {
        if (have_ds64) return Status::Error("Duplicate `ds64` chunk.");
        if (auto s = ensure_bufferable(size); !s.ok()) return s;
        // riffSize(8), dataSize(8), sampleCount(8), tableLength(4).
        if (size < 28) {
          return Status::Error("Truncated `ds64` chunk.");
        }
        if (size > kMaxStructuralChunkBytes) {
          return Status::Error("Implausibly large `ds64` chunk.");
        }
        std::vector<char> buf(static_cast<size_t>(size));
        if (!ReadExactly(in, buf.data(), static_cast<std::streamsize>(size))) {
          return Status::Error("Truncated `ds64` chunk.");
        }
        ds64_data_size =
            ReadU64(reinterpret_cast<const uint8_t*>(buf.data()) + 8);
        have_ds64 = true;
      } else if (is("axml") && reader.axml_.empty()) {
        // Metadata chunks read into a local, assigned only on success:
        // a failed read must never leave a zero-padded partial payload
        // visible through the accessors (a lenient open can survive
        // the failure via the walk-stop below).
        if (auto s = ensure_bufferable(size); !s.ok()) return s;
        std::string buf(static_cast<size_t>(size), '\0');
        if (size > 0 &&
            !ReadExactly(in, buf.data(), static_cast<std::streamsize>(size))) {
          return Status::Error("Truncated `axml` chunk.");
        }
        reader.axml_ = std::move(buf);
      } else if (is("chna") && reader.chna_.empty()) {
        if (auto s = ensure_bufferable(size); !s.ok()) return s;
        std::vector<uint8_t> buf(static_cast<size_t>(size));
        if (size > 0 && !ReadExactly(in, reinterpret_cast<char*>(buf.data()),
                                     static_cast<std::streamsize>(size))) {
          return Status::Error("Truncated `chna` chunk.");
        }
        reader.chna_ = std::move(buf);
      } else if (is("bext") && reader.bext_.empty()) {
        if (auto s = ensure_bufferable(size); !s.ok()) return s;
        std::vector<uint8_t> buf(static_cast<size_t>(size));
        if (size > 0 && !ReadExactly(in, reinterpret_cast<char*>(buf.data()),
                                     static_cast<std::streamsize>(size))) {
          return Status::Error("Truncated `bext` chunk.");
        }
        reader.bext_ = std::move(buf);
      } else {
        // Unknown chunks (and JUNK / a RIFF-container ds64 / duplicate
        // metadata chunks) are skipped, but their declared size must still
        // fit the file — fail closed instead of silently ending the walk on
        // a bogus size.
        if (auto s = ensure_fits(size); !s.ok()) return s;
      }
      return Status();
    };
    const Status chunk_status = parse_chunk();
    if (!chunk_status.ok()) {
      // A genuine I/O error (badbit) fails even leniently: a
      // "recovered" open over a failing stream would only deliver
      // zeros from the latched-bad file on every subsequent read.
      if (lenient && have_data && !in.bad()) {
        // Malformed tail after the audio: a truncated final metadata
        // chunk or a bogus trailing size. Everything that matters is
        // already parsed — end the walk instead of failing the open.
        // If the chunk we stopped on announced itself as ADM metadata,
        // record the loss so callers (the probe / ADM detection) can
        // refuse to treat the file as a plain WAV.
        reader.recovered_ = true;
        if (is("axml") || is("chna")) reader.metadata_dropped_ = true;
        break;
      }
      return chunk_status;
    }

    ++reader.chunks_seen_;
    if (reader.chunks_.size() < kMaxChunkInfos) {
      reader.chunks_.push_back(
          ChunkInfo{SanitizeChunkId(id), payload_pos, size});
    }

    // Advance to the next chunk: payload + RIFF word-alignment pad byte.
    // A final odd-sized chunk may lack its pad byte at EOF — seeking one
    // byte past the end still succeeds and the next read returns 0 bytes,
    // ending the walk cleanly. Only eof/fail state (from short final reads)
    // is cleared; badbit was already handled above.
    const auto advance = static_cast<std::streamoff>(size + (size & 1));
    in.clear(in.rdstate() & std::ios::badbit);
    in.seekg(static_cast<std::streamoff>(payload_pos) + advance);
    if (!in) {
      if (lenient && have_data && !in.bad()) {
        reader.recovered_ = true;
        break;
      }
      return Status::Error("Seek failed while walking WAV chunks.");
    }
  }

  if (!have_fmt) {
    return Status::Error("Missing `fmt ` chunk.");
  }
  if (!have_data) {
    return Status::Error("Missing `data` chunk.");
  }
  // Note: the declared nBlockAlign/nAvgBytesPerSec fields are intentionally
  // ignored — frame size is derived from channels × container width, which
  // is authoritative; real-world files routinely get those fields wrong.
  const uint32_t frame_bytes = reader.info_.frame_bytes();
  if (reader.data_size_ % frame_bytes != 0) {
    if (lenient) {
      // A dangling partial frame (truncated write, or the clamp above
      // landing mid-frame): drop the fraction and keep the whole
      // frames. Note the `data` entry in chunks() keeps the unfloored
      // size — the inventory reports what the walk saw, data_size() is
      // the readable payload.
      reader.data_size_ -= reader.data_size_ % frame_bytes;
      reader.recovered_ = true;
    } else {
      return Status::Error("`data` size is not a whole number of frames (" +
                           std::to_string(reader.data_size_) + " bytes, " +
                           std::to_string(frame_bytes) + "-byte frames).");
    }
  }
  reader.info_.num_frames = reader.data_size_ / frame_bytes;
  return reader;
}

Status Reader::ReadRaw(uint64_t start_frame, uint64_t count, uint64_t& frames) {
  frames = 0;
  if (start_frame >= info_.num_frames) return Status();
  frames = std::min(count, info_.num_frames - start_frame);

  const uint32_t frame_bytes = info_.frame_bytes();
  // `frames` is bounded by num_frames (validated against the file size in
  // Open), so this product fits the file; guard the size_t narrowing
  // regardless for 32-bit targets.
  const uint64_t raw_bytes = frames * static_cast<uint64_t>(frame_bytes);
  if (raw_bytes > std::numeric_limits<size_t>::max()) {
    return Status::Error("PCM read size overflows size_t.");
  }
  // The scratch only grows; steady-state fixed-size reads are
  // allocation-free (see ReserveReadScratch).
  if (raw_scratch_.size() < raw_bytes) {
    raw_scratch_.resize(static_cast<size_t>(raw_bytes));
  }

  // Clear eof/fail from a previous tail read, but keep badbit: a genuine
  // I/O error stays latched instead of being silently retried.
  file_.clear(file_.rdstate() & std::ios::badbit);
  const uint64_t offset = data_offset_ + start_frame * frame_bytes;
  // Sequential reads (the playback case) continue where the last one
  // ended, so the seek and its syscall are skipped.
  if (stream_pos_ < 0 || static_cast<uint64_t>(stream_pos_) != offset) {
    file_.seekg(static_cast<std::streamoff>(offset));
  }
  if (!ReadExactly(file_, reinterpret_cast<char*>(raw_scratch_.data()),
                   static_cast<std::streamsize>(raw_bytes))) {
    frames = 0;
    stream_pos_ = -1;
    // 15 characters: fits the small-string buffer of both libc++ and
    // libstdc++, so this error path allocates nothing either.
    return Status::Error("Short PCM read.");
  }
  stream_pos_ = static_cast<int64_t>(offset + raw_bytes);
  return Status();
}

void Reader::ReserveReadScratch(uint64_t max_frames) {
  const uint64_t bytes = max_frames * info_.frame_bytes();
  if (bytes <= std::numeric_limits<size_t>::max() &&
      raw_scratch_.size() < bytes) {
    raw_scratch_.resize(static_cast<size_t>(bytes));
  }
}

namespace {

// Output adapters for DecodeToPlanar: each maps every source format's
// natural intermediate (byte→value decode happens once, in the switch
// below) onto one destination sample type. Adding a format touches the
// switch plus one line per adapter.
struct FloatOut {
  using Sample = float;
  static float Uint8(uint8_t v) { return Uint8CodeToFloat(v); }
  static float Int16(int16_t v) { return Int16CodeToFloat(v); }
  static float Int24(int32_t v) { return Int24CodeToFloat(v); }
  static float Int32(int32_t v) { return Int32CodeToFloat(v); }
  static float Float32(float v) { return SanitizeFloatSample(v); }
  static float Float64(double v) { return SanitizeDoubleSample(v); }
};

struct Int32LjOut {
  using Sample = int32_t;
  static int32_t Uint8(uint8_t v) { return Uint8ToInt32Lj(v); }
  static int32_t Int16(int16_t v) { return Int16ToInt32Lj(v); }
  static int32_t Int24(int32_t v) { return Int24ToInt32Lj(v); }
  static int32_t Int32(int32_t v) { return v; }  // Already left-justified.
  static int32_t Float32(float v) { return FloatToInt32Lj(v); }
  static int32_t Float64(double v) { return DoubleToInt32Lj(v); }
};

// The single per-format decode: raw little-endian bytes → the format's
// intermediate → Out's sample type, planar.
template <typename Out>
void DecodeToPlanar(SampleFormat format, const uint8_t* raw, uint16_t nch,
                    int bps, uint64_t frames,
                    typename Out::Sample* const* out) {
  using Sample = typename Out::Sample;
  switch (format) {
    case SampleFormat::kUint8:
      DecodePlanar<Sample>(raw, nch, bps, frames, out,
                           [](const uint8_t* p) { return Out::Uint8(*p); });
      break;
    case SampleFormat::kInt16:
      DecodePlanar<Sample>(raw, nch, bps, frames, out, [](const uint8_t* p) {
        return Out::Int16(static_cast<int16_t>(ReadU16(p)));
      });
      break;
    case SampleFormat::kInt24:
      DecodePlanar<Sample>(raw, nch, bps, frames, out, [](const uint8_t* p) {
        return Out::Int24(SignExtend24(p));
      });
      break;
    case SampleFormat::kInt32:
      DecodePlanar<Sample>(raw, nch, bps, frames, out, [](const uint8_t* p) {
        return Out::Int32(static_cast<int32_t>(ReadU32(p)));
      });
      break;
    case SampleFormat::kFloat32:
      DecodePlanar<Sample>(raw, nch, bps, frames, out, [](const uint8_t* p) {
        return Out::Float32(ReadF32(p));
      });
      break;
    case SampleFormat::kFloat64:
      DecodePlanar<Sample>(raw, nch, bps, frames, out, [](const uint8_t* p) {
        return Out::Float64(ReadF64(p));
      });
      break;
  }
}

}  // namespace

Result<uint64_t> Reader::ReadPlanarFloatInto(uint64_t start_frame,
                                             uint64_t count,
                                             float* const* out) {
  uint64_t frames = 0;
  if (auto s = ReadRaw(start_frame, count, frames); !s.ok()) return s;
  if (frames > 0) {
    DecodeToPlanar<FloatOut>(info_.format, raw_scratch_.data(), info_.channels,
                             info_.bytes_per_sample(), frames, out);
  }
  return frames;
}

Result<uint64_t> Reader::ReadPlanarFloat(uint64_t start_frame, uint64_t count,
                                         std::vector<std::vector<float>>& out) {
  out.resize(info_.channels);
  uint64_t frames = 0;
  const Status s = ReadRaw(start_frame, count, frames);
  for (auto& c : out) c.resize(static_cast<size_t>(frames));
  if (!s.ok()) return s;
  if (frames == 0) return uint64_t{0};

  std::vector<float*> ptrs(info_.channels);
  for (uint16_t c = 0; c < info_.channels; ++c) ptrs[c] = out[c].data();
  DecodeToPlanar<FloatOut>(info_.format, raw_scratch_.data(), info_.channels,
                           info_.bytes_per_sample(), frames, ptrs.data());
  return frames;
}

Result<uint64_t> Reader::ReadPlanarInt32LeftJustified(
    uint64_t start_frame, uint64_t count,
    std::vector<std::vector<int32_t>>& out) {
  out.resize(info_.channels);
  uint64_t frames = 0;
  const Status s = ReadRaw(start_frame, count, frames);
  for (auto& c : out) c.resize(static_cast<size_t>(frames));
  if (!s.ok()) return s;
  if (frames == 0) return uint64_t{0};

  std::vector<int32_t*> ptrs(info_.channels);
  for (uint16_t c = 0; c < info_.channels; ++c) ptrs[c] = out[c].data();
  DecodeToPlanar<Int32LjOut>(info_.format, raw_scratch_.data(), info_.channels,
                             info_.bytes_per_sample(), frames, ptrs.data());
  return frames;
}

}  // namespace wav
