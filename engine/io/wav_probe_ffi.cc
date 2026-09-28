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

#include "io/wav_probe_ffi.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "wav/reader.h"
#include "wav/types.h"

namespace {

// JSON string escape. Quotes and backslashes get their short forms; any
// control character (legal in POSIX filenames, and file paths are embedded
// in the parser's error messages verbatim) is emitted as \u00XX so Dart's
// jsonDecode never chokes on a legal-but-odd filename.
std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (const char c : s) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char esc[8];
          snprintf(esc, sizeof(esc), "\\u%04x",
                   static_cast<unsigned>(static_cast<unsigned char>(c)));
          out += esc;
        } else {
          out.push_back(c);
        }
    }
  }
  return out;
}

const char* ContainerName(wav::Container c) {
  switch (c) {
    case wav::Container::kRiff:
      return "riff";
    case wav::Container::kRf64:
      return "rf64";
    case wav::Container::kBw64:
      return "bw64";
  }
  return "?";
}

char* HeapString(const std::string& s) {
  auto* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

// Allocation-free fallback for the catch-all path: strdup of a literal
// cannot throw, and nullptr on OOM is part of the probe's contract.
char* HeapLiteral(const char* s) {
  const size_t n = std::strlen(s) + 1;
  auto* out = static_cast<char*>(std::malloc(n));
  if (out == nullptr) return nullptr;
  std::memcpy(out, s, n);
  return out;
}

char* ProbeImpl(const char* path) {
  // Lenient, matching playback and the waveform scan: the probe backs
  // the UI's "can this file be used?" answer, and a damaged file whose
  // intact prefix plays should probe as usable. `recovered` is surfaced
  // in the JSON so callers can tell. Export and ADM import re-open
  // strictly on their own paths.
  auto r = wav::Reader::Open(path, wav::OpenMode::kLenient);
  if (!r.ok()) {
    return HeapString(std::string(R"({"ok":false,"error":")") +
                      JsonEscape(r.error()) + "\"}");
  }
  const wav::Info& info = r->info();
  std::string json = "{\"ok\":true";
  json += std::string(",\"recovered\":") + (r->recovered() ? "true" : "false");
  json += std::string(",\"metadata_dropped\":") +
          (r->metadata_dropped() ? "true" : "false");
  json +=
      std::string(",\"container\":\"") + ContainerName(info.container) + "\"";
  json += ",\"channels\":" + std::to_string(info.channels);
  json += ",\"sample_rate\":" + std::to_string(info.sample_rate);
  json += ",\"bits_per_sample\":" + std::to_string(info.bits_per_sample());
  json += std::string(",\"is_float\":") +
          (wav::IsFloatFormat(info.format) ? "true" : "false");
  json += ",\"num_frames\":" + std::to_string(info.num_frames);
  json += ",\"data_offset\":" + std::to_string(r->data_offset());
  json += ",\"data_size\":" + std::to_string(r->data_size());
  json += ",\"axml_bytes\":" + std::to_string(r->axml().size());
  json += ",\"chna_bytes\":" + std::to_string(r->chna().size());
  json += "}";
  return HeapString(json);
}

}  // namespace

extern "C" char* eclipsa_studio_wav_probe_json(const char* path) {
  // Catch-all: a C++ exception (e.g. bad_alloc while buffering a large
  // axml chunk) must never cross the C ABI — that is undefined behavior
  // and would tear down the host process. Same discipline as GuardAbi in
  // adm2iamf_ffi.cc; the fallback string is built without allocating.
  try {
    if (path == nullptr) {
      return HeapString(R"({"ok":false,"error":"null path"})");
    }
    return ProbeImpl(path);
  } catch (...) {
    return HeapLiteral(R"({"ok":false,"error":"internal error"})");
  }
}
