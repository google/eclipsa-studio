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
// Private helpers shared by reader.cc and writer.cc: little-endian byte
// access, exact-length stream reads, chunk-id sanitizing and UTF-8-safe
// file opening on Windows. Not part of the public API.

#ifndef ECLIPSA_STUDIO_WAV_INTERNAL_H_
#define ECLIPSA_STUDIO_WAV_INTERNAL_H_

#include <cstdint>
#include <fstream>
#include <ios>
#include <istream>
#include <string>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace wav {
namespace internal {

// WAVE format tags and the 32-bit "unknown / see ds64" size sentinel,
// shared by reader.cc and writer.cc.
constexpr uint16_t kTagPcm = 1;
constexpr uint16_t kTagIeeeFloat = 3;
constexpr uint16_t kTagExtensible = 0xFFFE;
constexpr uint32_t kSize32Max = 0xFFFFFFFFu;

// ── Little-endian readers over an in-memory byte span ─────────────────────

inline uint16_t ReadU16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) |
         static_cast<uint16_t>(static_cast<uint16_t>(p[1]) << 8);
}

inline uint32_t ReadU32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

inline uint64_t ReadU64(const uint8_t* p) {
  return static_cast<uint64_t>(ReadU32(p)) |
         (static_cast<uint64_t>(ReadU32(p + 4)) << 32);
}

// ── Little-endian writers into an in-memory byte span ─────────────────────

inline void PutU16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v & 0xFF);
  p[1] = static_cast<uint8_t>(v >> 8);
}

inline void PutU32(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v & 0xFF);
  p[1] = static_cast<uint8_t>((v >> 8) & 0xFF);
  p[2] = static_cast<uint8_t>((v >> 16) & 0xFF);
  p[3] = static_cast<uint8_t>((v >> 24) & 0xFF);
}

inline void PutU64(uint8_t* p, uint64_t v) {
  PutU32(p, static_cast<uint32_t>(v & 0xFFFFFFFFu));
  PutU32(p + 4, static_cast<uint32_t>(v >> 32));
}

// ── Streams ────────────────────────────────────────────────────────────────

inline bool ReadExactly(std::istream& in, char* dst, std::streamsize n) {
  in.read(dst, n);
  return in.gcount() == n;
}

// A chunk id is four arbitrary bytes on disk and ends up in user-visible
// inventories and error messages. Non-printable and non-ASCII bytes are
// replaced with '?' so a corrupt file cannot smuggle invalid UTF-8 or
// control characters downstream.
inline std::string SanitizeChunkId(const char* id) {
  std::string out(4, '?');
  for (int i = 0; i < 4; ++i) {
    const auto c = static_cast<unsigned char>(id[i]);
    if (c >= 0x20 && c < 0x7F) out[i] = static_cast<char>(c);
  }
  return out;
}

// std::fstream's char* open uses the active code page on Windows; convert
// UTF-8 paths to UTF-16 and use the wchar_t* overload (an MSVC extension)
// so non-ASCII paths keep working.
#if defined(_WIN32)
inline std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(n), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                        &wide[0], n);
  return wide;
}
#endif

inline void OpenBinaryInput(std::ifstream& f, const std::string& path) {
#if defined(_WIN32)
  f.open(Utf8ToWide(path).c_str(), std::ios::binary);
#else
  f.open(path, std::ios::binary);
#endif
}

inline void OpenBinaryOutput(std::ofstream& f, const std::string& path) {
#if defined(_WIN32)
  f.open(Utf8ToWide(path).c_str(), std::ios::binary | std::ios::trunc);
#else
  f.open(path, std::ios::binary | std::ios::trunc);
#endif
}

}  // namespace internal
}  // namespace wav

#endif  // ECLIPSA_STUDIO_WAV_INTERNAL_H_
