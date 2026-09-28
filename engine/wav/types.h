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
// Shared value types: containers, sample formats, stream info, chunk
// inventory entries and pass-through metadata.

#ifndef ECLIPSA_STUDIO_WAV_TYPES_H_
#define ECLIPSA_STUDIO_WAV_TYPES_H_

#include <cstdint>
#include <string>
#include <vector>

namespace wav {

enum class Container : uint8_t {
  kRiff,  // Classic RIFF/WAVE, 32-bit sizes.
  kRf64,  // EBU RF64: 64-bit sizes via a `ds64` chunk.
  kBw64,  // ITU-R BS.2088 BW64: RF64 sizing + ADM chunks (axml/chna).
};

enum class SampleFormat : uint8_t {
  kUint8,    // 8-bit offset-binary PCM.
  kInt16,    // 16-bit signed PCM.
  kInt24,    // 24-bit signed PCM, packed 3 bytes.
  kInt32,    // 32-bit signed PCM.
  kFloat32,  // IEEE float.
  kFloat64,  // IEEE double.
};

inline int BitsPerSample(SampleFormat f) {
  switch (f) {
    case SampleFormat::kUint8:
      return 8;
    case SampleFormat::kInt16:
      return 16;
    case SampleFormat::kInt24:
      return 24;
    case SampleFormat::kInt32:
    case SampleFormat::kFloat32:
      return 32;
    case SampleFormat::kFloat64:
      return 64;
  }
  return 0;
}

inline int BytesPerSample(SampleFormat f) { return BitsPerSample(f) / 8; }

inline bool IsFloatFormat(SampleFormat f) {
  return f == SampleFormat::kFloat32 || f == SampleFormat::kFloat64;
}

inline const char* SampleFormatName(SampleFormat f) {
  switch (f) {
    case SampleFormat::kUint8:
      return "uint8";
    case SampleFormat::kInt16:
      return "int16";
    case SampleFormat::kInt24:
      return "int24";
    case SampleFormat::kInt32:
      return "int32";
    case SampleFormat::kFloat32:
      return "float32";
    case SampleFormat::kFloat64:
      return "float64";
  }
  return "?";
}

// Resolved properties of an open WAV stream.
struct Info {
  Container container = Container::kRiff;
  SampleFormat format = SampleFormat::kInt16;
  uint16_t channels = 0;
  uint32_t sample_rate = 0;
  // Per-channel sample count of the `data` chunk.
  uint64_t num_frames = 0;
  // True when `fmt ` was WAVE_FORMAT_EXTENSIBLE (after resolving the
  // sub-format GUID into `format`).
  bool extensible = false;
  // dwChannelMask from an extensible `fmt `; 0 when absent or plain.
  uint32_t channel_mask = 0;
  // wValidBitsPerSample from an extensible `fmt ` (e.g. 24 for 24-in-32
  // files); 0 when absent or plain. Purely informational — decoding always
  // uses the container width.
  uint16_t valid_bits = 0;

  int bits_per_sample() const { return BitsPerSample(format); }
  int bytes_per_sample() const { return BytesPerSample(format); }
  uint32_t frame_bytes() const {
    return static_cast<uint32_t>(channels) *
           static_cast<uint32_t>(bytes_per_sample());
  }
};

// One entry of the chunk inventory, in file order.
struct ChunkInfo {
  std::string id;       // Four-character id, sanitized to printable ASCII.
  uint64_t offset = 0;  // Byte offset of the chunk payload.
  uint64_t size = 0;    // Payload size in bytes (excluding the pad byte).
};

// Pass-through metadata chunks. The library preserves these verbatim; it
// never parses ADM XML or broadcast-extension fields.
struct Metadata {
  std::string axml;           // ADM XML payload (`axml` chunk).
  std::vector<uint8_t> chna;  // Raw `chna` chunk bytes.
  std::vector<uint8_t> bext;  // Raw `bext` chunk bytes.

  bool empty() const { return axml.empty() && chna.empty() && bext.empty(); }
};

}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_TYPES_H_
