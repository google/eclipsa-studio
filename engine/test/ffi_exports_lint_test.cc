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

// Lint: every extern "C" symbol Dart can look up must be listed in
// eclipsa_studio_engine_exports.def, and every .def entry must still exist in
// a header. MSVC exports nothing by default, so a symbol missing from
// the .def builds and links fine everywhere and then throws
// ArgumentError from Dart's lookupFunction on Windows only — a bug
// class macOS CI cannot catch at link time (it shipped twice:
// eclipsa_studio_mix_renderer_set_object_position and
// eclipsa_studio_element_set_object_position, fixed in ES-484's PR).
//
// The scan is textual: comments are stripped, then every
// `eclipsa_studio_*(` / `adm2iamf_*(` identifier-before-paren in the FFI
// headers is treated as a declared export. All exported symbols must
// be declared in one of the headers below (engine.cc-only definitions
// are not allowed — declare them in engine.h so this list stays the
// single source of truth).

#include <cstdlib>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "gtest/gtest.h"

namespace {

// Headers that declare the dylib's C FFI surface, as workspace-relative
// paths (also the runfiles layout under TEST_SRCDIR/_main).
const char* const kFfiHeaders[] = {
    "engine.h",
    "engine_log.h",
    "video/video_ffi.h",
    "adm_import/ffi/adm2iamf_ffi.h",
    "iamf/iamf_probe_ffi.h",
    "io/wav_probe_ffi.h",
    "waveform/peak_compute.h",
    "dsp/sh_decode.h",
};

const char kDefFile[] = "eclipsa_studio_engine_exports.def";

std::string ReadFileOrDie(const std::string& rel_path) {
  const char* srcdir = std::getenv("TEST_SRCDIR");
  const std::string candidates[] = {
      srcdir ? std::string(srcdir) + "/_main/" + rel_path : rel_path,
      rel_path,
  };
  for (const auto& path : candidates) {
    std::ifstream in(path, std::ios::binary);
    if (in) {
      std::ostringstream ss;
      ss << in.rdbuf();
      return ss.str();
    }
  }
  ADD_FAILURE() << "cannot open " << rel_path;
  return {};
}

// Remove // and /* */ comments so symbol names quoted in prose don't
// count as declarations.
std::string StripComments(const std::string& src) {
  std::string out;
  out.reserve(src.size());
  for (size_t i = 0; i < src.size();) {
    if (src.compare(i, 2, "//") == 0) {
      while (i < src.size() && src[i] != '\n') ++i;
    } else if (src.compare(i, 2, "/*") == 0) {
      i += 2;
      while (i + 1 < src.size() && src.compare(i, 2, "*/") != 0) ++i;
      i = (i + 2 <= src.size()) ? i + 2 : src.size();
      out += ' ';  // keep tokens separated
    } else {
      out += src[i++];
    }
  }
  return out;
}

std::set<std::string> HeaderSymbols() {
  std::set<std::string> symbols;
  // Identifier followed (possibly across lines) by an open paren. \s
  // matches newlines in ECMAScript regexes, so multi-line declarations
  // split between the name and the parameter list still match.
  const std::regex decl(R"(\b((?:eclipsa|adm2iamf)_[a-z0-9_]+)\s*\()");
  for (const char* header : kFfiHeaders) {
    const std::string text = StripComments(ReadFileOrDie(header));
    for (std::sregex_iterator it(text.begin(), text.end(), decl), end;
         it != end; ++it) {
      symbols.insert((*it)[1].str());
    }
  }
  return symbols;
}

std::set<std::string> DefSymbols() {
  std::set<std::string> symbols;
  std::istringstream in(ReadFileOrDie(kDefFile));
  std::string line;
  while (std::getline(in, line)) {
    const size_t comment = line.find(';');
    if (comment != std::string::npos) line.erase(comment);
    const size_t begin = line.find_first_not_of(" \t\r");
    if (begin == std::string::npos) continue;
    const size_t end = line.find_last_not_of(" \t\r");
    const std::string name = line.substr(begin, end - begin + 1);
    if (name == "EXPORTS") continue;
    symbols.insert(name);
  }
  return symbols;
}

TEST(FfiExportsLint, EveryDeclaredSymbolIsExported) {
  const std::set<std::string> declared = HeaderSymbols();
  const std::set<std::string> exported = DefSymbols();
  ASSERT_GT(declared.size(), 50u) << "header scan looks broken";
  for (const auto& name : declared) {
    EXPECT_TRUE(exported.count(name))
        << name << " is declared in an FFI header but missing from " << kDefFile
        << " — Dart lookupFunction will throw on Windows";
  }
}

TEST(FfiExportsLint, EveryExportedSymbolIsDeclared) {
  const std::set<std::string> declared = HeaderSymbols();
  const std::set<std::string> exported = DefSymbols();
  ASSERT_GT(exported.size(), 50u) << "def scan looks broken";
  for (const auto& name : exported) {
    EXPECT_TRUE(declared.count(name))
        << name << " is listed in " << kDefFile
        << " but no FFI header declares it — stale entry, or declare "
           "the symbol in engine.h";
  }
}

}  // namespace
