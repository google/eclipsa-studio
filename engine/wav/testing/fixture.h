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
// Test fixture generator: builds WAV files byte-by-byte, independently of
// wav::Writer, across the conformance matrix — container × sample format ×
// fmt variant × channel count — plus knobs for ds64 placement, chunk order
// and metadata. Payloads are deterministic ramps so decoded values are
// predictable exactly.
//
// Header-only, testonly. Fixtures are generated at test time; no binary
// blobs live in the repo.

#ifndef ECLIPSA_STUDIO_WAV_TESTING_FIXTURE_H_
#define ECLIPSA_STUDIO_WAV_TESTING_FIXTURE_H_

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "wav/types.h"

namespace wav {
namespace testing {

struct FixtureSpec {
  Container container = Container::kRiff;
  SampleFormat format = SampleFormat::kInt16;
  bool extensible = false;
  uint16_t channels = 1;
  uint32_t sample_rate = 48000;
  uint32_t num_frames = 48;

  // ds64 placement (RF64/BW64 only; ignored for RIFF).
  //   kDefault:   first chunk, `data` size field = 0xFFFFFFFF (spec layout).
  //   kNone:      no ds64; all size fields hold real 32-bit values
  //               (BW64 spec allows this for files under 4 GiB).
  //   kLate:      after `fmt `, before `data` — still accepted.
  //   kAfterData: after `data`, whose size field is 0xFFFFFFFF — rejected.
  enum class Ds64Mode { kDefault, kNone, kLate, kAfterData };
  Ds64Mode ds64 = Ds64Mode::kDefault;

  bool fmt_after_data = false;       // Malformed: `fmt ` follows `data`.
  bool include_extra_chunk = false;  // Odd-sized "dbmd" chunk before `fmt `.
  bool include_axml = false;
  bool include_chna = false;
  bool include_bext = false;
};

// Built file plus the byte offsets tests need for surgical corruption.
struct FixtureFile {
  std::vector<uint8_t> bytes;
  size_t riff_size_offset = 4;
  // SIZE_MAX marks "not present in this fixture" — patching such an offset
  // is a test bug and faults loudly instead of scribbling over the header.
  static constexpr size_t kAbsent = static_cast<size_t>(-1);
  size_t ds64_size_field_offset = kAbsent;
  size_t fmt_size_field_offset = 0;
  size_t data_size_field_offset = 0;
  size_t data_payload_offset = 0;
  size_t extra_size_field_offset = kAbsent;  // Set by include_extra_chunk.
};

// Reference metadata payloads used when the include_* knobs are set. The
// axml payload is deliberately odd-length so metadata chunks exercise the
// RIFF pad byte.
inline const char* kFixtureAxml() { return "<audioFormatExtended />"; }
inline std::vector<uint8_t> FixtureChna() {
  return {0x01, 0x00, 0x00, 0x00, 0x41, 0x54,
          0x55, 0x5F, 0x30, 0x30, 0x30, 0x31};
}
inline std::vector<uint8_t> FixtureBext() {
  return {0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9};
}

// The deterministic ramp: the integer code stored for (frame, channel).
// Float formats use a 24-bit code range so every value is exact in both
// float32 and float64.
inline int64_t RampCode(SampleFormat f, uint64_t frame, uint16_t ch) {
  const int code_bits = IsFloatFormat(f) ? 24 : BitsPerSample(f);
  const uint64_t range = uint64_t{1} << code_bits;
  const uint64_t h =
      frame * 2654435761ull + static_cast<uint64_t>(ch) * 97003ull + 12345ull;
  return static_cast<int64_t>(h % range) - static_cast<int64_t>(range >> 1);
}

// The exact value Reader::ReadPlanarFloat must produce for (frame, channel).
inline float ExpectedFloat(SampleFormat f, uint64_t frame, uint16_t ch) {
  const int64_t code = RampCode(f, frame, ch);
  switch (f) {
    case SampleFormat::kUint8:
      return static_cast<float>(code) / 128.0f;
    case SampleFormat::kInt16:
      return static_cast<float>(code) / 32768.0f;
    case SampleFormat::kInt24:
      return static_cast<float>(code) / 8388608.0f;
    case SampleFormat::kInt32:
      return static_cast<float>(static_cast<double>(code) / 2147483648.0);
    case SampleFormat::kFloat32:
    case SampleFormat::kFloat64:
      return static_cast<float>(static_cast<double>(code) / 16777216.0);
  }
  return 0.0f;
}

// The exact value Reader::ReadPlanarInt32LeftJustified must produce.
inline int32_t ExpectedInt32Lj(SampleFormat f, uint64_t frame, uint16_t ch) {
  const int64_t code = RampCode(f, frame, ch);
  switch (f) {
    case SampleFormat::kUint8:
      return static_cast<int32_t>(code * (int64_t{1} << 24));
    case SampleFormat::kInt16:
      return static_cast<int32_t>(code * (int64_t{1} << 16));
    case SampleFormat::kInt24:
      return static_cast<int32_t>(code * (int64_t{1} << 8));
    case SampleFormat::kInt32:
      return static_cast<int32_t>(code);
    case SampleFormat::kFloat32:
    case SampleFormat::kFloat64:
      // value * 2^31 = code / 2^24 * 2^31 = code * 2^7, exactly.
      return static_cast<int32_t>(code * (int64_t{1} << 7));
  }
  return 0;
}

// The channel mask the extensible-fmt fixtures declare.
inline uint32_t FixtureChannelMask(uint16_t channels) {
  return channels <= 18 ? ((uint32_t{1} << channels) - 1) : 0;
}

namespace fixture_internal {

inline void PutU16At(std::vector<uint8_t>& v, size_t off, uint16_t x) {
  v[off] = static_cast<uint8_t>(x & 0xFF);
  v[off + 1] = static_cast<uint8_t>(x >> 8);
}

inline void PutU32At(std::vector<uint8_t>& v, size_t off, uint32_t x) {
  for (int i = 0; i < 4; ++i)
    v[off + i] = static_cast<uint8_t>((x >> (8 * i)) & 0xFF);
}

inline void PutU64At(std::vector<uint8_t>& v, size_t off, uint64_t x) {
  for (int i = 0; i < 8; ++i)
    v[off + i] = static_cast<uint8_t>((x >> (8 * i)) & 0xFF);
}

inline void AppendU16(std::vector<uint8_t>& v, uint16_t x) {
  v.push_back(static_cast<uint8_t>(x & 0xFF));
  v.push_back(static_cast<uint8_t>(x >> 8));
}

inline void AppendU32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 0; i < 4; ++i)
    v.push_back(static_cast<uint8_t>((x >> (8 * i)) & 0xFF));
}

inline void AppendU64(std::vector<uint8_t>& v, uint64_t x) {
  for (int i = 0; i < 8; ++i)
    v.push_back(static_cast<uint8_t>((x >> (8 * i)) & 0xFF));
}

inline void AppendId(std::vector<uint8_t>& v, const char* id) {
  v.insert(v.end(), id, id + 4);
}

inline void AppendSample(std::vector<uint8_t>& v, SampleFormat f,
                         int64_t code) {
  switch (f) {
    case SampleFormat::kUint8:
      v.push_back(static_cast<uint8_t>(code + 128));
      break;
    case SampleFormat::kInt16:
      AppendU16(v, static_cast<uint16_t>(static_cast<int16_t>(code)));
      break;
    case SampleFormat::kInt24: {
      const auto u = static_cast<uint32_t>(static_cast<int32_t>(code));
      v.push_back(static_cast<uint8_t>(u & 0xFF));
      v.push_back(static_cast<uint8_t>((u >> 8) & 0xFF));
      v.push_back(static_cast<uint8_t>((u >> 16) & 0xFF));
      break;
    }
    case SampleFormat::kInt32:
      AppendU32(v, static_cast<uint32_t>(static_cast<int32_t>(code)));
      break;
    case SampleFormat::kFloat32: {
      const auto val =
          static_cast<float>(static_cast<double>(code) / 16777216.0);
      uint32_t bits;
      std::memcpy(&bits, &val, sizeof(bits));
      AppendU32(v, bits);
      break;
    }
    case SampleFormat::kFloat64: {
      const double val = static_cast<double>(code) / 16777216.0;
      uint64_t bits;
      std::memcpy(&bits, &val, sizeof(bits));
      AppendU64(v, bits);
      break;
    }
  }
}

}  // namespace fixture_internal

inline FixtureFile BuildFixture(const FixtureSpec& spec) {
  using namespace fixture_internal;  // NOLINT(build/namespaces)

  // Interleaved ramp payload.
  std::vector<uint8_t> data;
  for (uint64_t n = 0; n < spec.num_frames; ++n) {
    for (uint16_t c = 0; c < spec.channels; ++c) {
      AppendSample(data, spec.format, RampCode(spec.format, n, c));
    }
  }

  const bool is64 = spec.container != Container::kRiff;
  const bool has_ds64 = is64 && spec.ds64 != FixtureSpec::Ds64Mode::kNone;
  const int bits = BitsPerSample(spec.format);
  const int bps = BytesPerSample(spec.format);
  const uint16_t tag_base =
      IsFloatFormat(spec.format) ? uint16_t{3} : uint16_t{1};

  FixtureFile out;
  auto& v = out.bytes;

  switch (spec.container) {
    case Container::kRiff:
      AppendId(v, "RIFF");
      break;
    case Container::kRf64:
      AppendId(v, "RF64");
      break;
    case Container::kBw64:
      AppendId(v, "BW64");
      break;
  }
  AppendU32(v, 0);  // RIFF size, patched below.
  AppendId(v, "WAVE");

  auto append_ds64 = [&]() {
    AppendId(v, "ds64");
    out.ds64_size_field_offset = v.size();
    AppendU32(v, 28);
    AppendU64(v, 0);  // riffSize, patched below.
    AppendU64(v, data.size());
    AppendU64(v, spec.num_frames);
    AppendU32(v, 0);  // Table length.
  };

  auto append_fmt = [&]() {
    AppendId(v, "fmt ");
    out.fmt_size_field_offset = v.size();
    AppendU32(v, spec.extensible ? 40 : 16);
    AppendU16(v, spec.extensible ? uint16_t{0xFFFE} : tag_base);
    AppendU16(v, spec.channels);
    AppendU32(v, spec.sample_rate);
    AppendU32(v, spec.sample_rate * spec.channels * bps);  // Byte rate.
    AppendU16(v, static_cast<uint16_t>(spec.channels * bps));
    AppendU16(v, static_cast<uint16_t>(bits));
    if (spec.extensible) {
      AppendU16(v, 22);  // cbSize.
      AppendU16(v, static_cast<uint16_t>(bits));
      AppendU32(v, FixtureChannelMask(spec.channels));
      AppendU16(v, tag_base);
      const uint8_t guid_tail[14] = {0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80,
                                     0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
      v.insert(v.end(), guid_tail, guid_tail + 14);
    }
  };

  auto append_data = [&]() {
    AppendId(v, "data");
    out.data_size_field_offset = v.size();
    AppendU32(v, has_ds64 ? 0xFFFFFFFFu : static_cast<uint32_t>(data.size()));
    out.data_payload_offset = v.size();
    v.insert(v.end(), data.begin(), data.end());
    if (data.size() & 1) v.push_back(0);
  };

  if (has_ds64 && spec.ds64 == FixtureSpec::Ds64Mode::kDefault) append_ds64();

  if (spec.include_extra_chunk) {
    AppendId(v, "dbmd");
    out.extra_size_field_offset = v.size();
    AppendU32(v, 7);  // Odd size: exercises pad-byte handling.
    for (uint8_t i = 1; i <= 7; ++i) v.push_back(i);
    v.push_back(0);  // Pad.
  }
  // One padded emitter for all metadata chunks, so an odd-length payload
  // always gets its RIFF pad byte.
  auto append_metadata_chunk = [&](const char* id, const void* payload,
                                   size_t n) {
    AppendId(v, id);
    AppendU32(v, static_cast<uint32_t>(n));
    const auto* b = static_cast<const uint8_t*>(payload);
    v.insert(v.end(), b, b + n);
    if (n & 1) v.push_back(0);
  };
  if (spec.include_bext) {
    const auto bext = FixtureBext();
    append_metadata_chunk("bext", bext.data(), bext.size());
  }
  if (spec.include_axml) {
    const std::string axml = kFixtureAxml();
    append_metadata_chunk("axml", axml.data(), axml.size());
  }
  if (spec.include_chna) {
    const auto chna = FixtureChna();
    append_metadata_chunk("chna", chna.data(), chna.size());
  }

  if (spec.fmt_after_data) {
    append_data();
    append_fmt();
  } else {
    append_fmt();
    if (has_ds64 && spec.ds64 == FixtureSpec::Ds64Mode::kLate) append_ds64();
    append_data();
  }
  if (has_ds64 && spec.ds64 == FixtureSpec::Ds64Mode::kAfterData) {
    append_ds64();
  }

  // Patch the top-level sizes now that the layout is complete.
  PutU32At(v, out.riff_size_offset,
           has_ds64 ? 0xFFFFFFFFu : static_cast<uint32_t>(v.size() - 8));
  if (has_ds64) {
    PutU64At(v, out.ds64_size_field_offset + 4, v.size() - 8);
  }
  return out;
}

// ── Raw-`fmt ` escape hatch ────────────────────────────────────────────────
// A structurally valid RIFF/WAVE wrapped around an arbitrary `fmt ` body —
// any tag, any length, including deliberately truncated extensible bodies —
// with a zero-filled `data` payload. For rejection-path tests that need
// formats the typed FixtureSpec cannot express (compressed tags, malformed
// extensible chunks).

// A basic 16-byte WAVEFORMATEX body with the given tag.
inline std::vector<uint8_t> FmtBody(uint16_t tag, uint16_t channels,
                                    uint32_t sample_rate, uint16_t bits) {
  using namespace fixture_internal;  // NOLINT(build/namespaces)
  const uint16_t block_align = channels * (bits / 8);
  std::vector<uint8_t> b;
  AppendU16(b, tag);
  AppendU16(b, channels);
  AppendU32(b, sample_rate);
  AppendU32(b, sample_rate * block_align);  // byte rate (reader ignores it)
  AppendU16(b, block_align);
  AppendU16(b, bits);
  return b;  // 16 bytes
}

// A full 40-byte WAVE_FORMAT_EXTENSIBLE body whose SubFormat GUID begins
// with `subformat_tag` (the only part of the GUID the reader inspects) —
// the channel mask is 0 and the GUID tail is zero filler, unlike
// BuildFixture's spec-shaped extensible fmt. Truncate the result for
// malformed-extensible tests.
inline std::vector<uint8_t> FmtBodyExtensible(uint16_t channels,
                                              uint32_t sample_rate,
                                              uint16_t bits,
                                              uint16_t subformat_tag) {
  using namespace fixture_internal;  // NOLINT(build/namespaces)
  std::vector<uint8_t> b = FmtBody(0xFFFE, channels, sample_rate, bits);
  AppendU16(b, 22);             // cbSize
  AppendU16(b, bits);           // valid bits per sample
  AppendU32(b, 0);              // channel mask
  AppendU16(b, subformat_tag);  // first 2 bytes of the SubFormat GUID
  b.insert(b.end(), 14, 0);     // remainder of the GUID
  return b;                     // 16 + 2 + 2 + 4 + 16 = 40 bytes
}

// A minimal RIFF/WAVE: header + the given `fmt ` body (padded if odd) + a
// zeroed `data` chunk of `data_bytes`. The data payload is emitted
// verbatim — keeping `data_bytes` even (a whole number of frames) is the
// caller's responsibility; an odd final chunk gets no pad byte.
inline std::vector<uint8_t> BuildRawFmtWav(const std::vector<uint8_t>& fmt_body,
                                           uint32_t data_bytes) {
  using namespace fixture_internal;  // NOLINT(build/namespaces)
  std::vector<uint8_t> v;
  AppendId(v, "RIFF");
  AppendU32(v, 0);  // patched below
  AppendId(v, "WAVE");
  AppendId(v, "fmt ");
  AppendU32(v, static_cast<uint32_t>(fmt_body.size()));
  v.insert(v.end(), fmt_body.begin(), fmt_body.end());
  if (fmt_body.size() % 2 != 0) v.push_back(0);  // RIFF pad byte
  AppendId(v, "data");
  AppendU32(v, data_bytes);
  v.insert(v.end(), data_bytes, 0);
  PutU32At(v, 4, static_cast<uint32_t>(v.size() - 8));
  return v;
}

// ── File plumbing ──────────────────────────────────────────────────────────

// Bazel's per-test temporary directory, or /tmp outside Bazel.
inline std::string TempDir() {
  const char* td = std::getenv("TEST_TMPDIR");
  if (td != nullptr && td[0] != '\0') return std::string(td);
  return "/tmp";
}

inline bool WriteBytes(const std::string& path,
                       const std::vector<uint8_t>& bytes) {
  std::ofstream f(path, std::ios::binary | std::ios::trunc);
  f.write(reinterpret_cast<const char*>(bytes.data()),
          static_cast<std::streamsize>(bytes.size()));
  return static_cast<bool>(f);
}

// Builds the fixture and writes it to TempDir()/<name>.wav.
inline std::string WriteFixture(const std::string& name,
                                const FixtureSpec& spec) {
  const std::string path = TempDir() + "/" + name + ".wav";
  WriteBytes(path, BuildFixture(spec).bytes);
  return path;
}

}  // namespace testing
}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_TESTING_FIXTURE_H_
