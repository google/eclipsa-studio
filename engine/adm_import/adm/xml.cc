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

#include "adm_import/adm/xml.h"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace {

// Maximum element nesting depth. ADM hierarchies are shallow (a handful of
// levels); this only exists to bound recursion against adversarial/deeply
// nested input. Capping parse depth also bounds the recursive ~XmlNode, so
// destroying the tree cannot overflow the stack either.
constexpr int kMaxDepth = 256;

bool IsSpace(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

// Strips a namespace prefix: "adm:audioObject" -> "audioObject".
absl::string_view LocalName(absl::string_view qname) {
  auto pos = qname.find(':');
  return pos == absl::string_view::npos ? qname : qname.substr(pos + 1);
}

void AppendUtf8(std::string& out, uint32_t cp) {
  if (cp <= 0x7F) {
    out.push_back(static_cast<char>(cp));
  } else if (cp <= 0x7FF) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp <= 0xFFFF) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

std::string DecodeEntities(absl::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size();) {
    if (s[i] != '&') {
      out.push_back(s[i++]);
      continue;
    }
    auto semi = s.find(';', i);
    if (semi == absl::string_view::npos) {
      out.push_back(s[i++]);
      continue;
    }
    absl::string_view ent = s.substr(i + 1, semi - i - 1);
    if (ent == "lt") {
      out.push_back('<');
    } else if (ent == "gt") {
      out.push_back('>');
    } else if (ent == "amp") {
      out.push_back('&');
    } else if (ent == "quot") {
      out.push_back('"');
    } else if (ent == "apos") {
      out.push_back('\'');
    } else if (!ent.empty() && ent[0] == '#') {
      // Numeric character reference. Validate strictly: reject non-digits,
      // overflow, and codepoints outside [0x1, 0x10FFFF] or in the UTF-16
      // surrogate range. Invalid -> keep the reference verbatim instead of
      // emitting malformed UTF-8 (this XML is handed to Dart as JSON).
      const bool hex = ent.size() > 1 && (ent[1] == 'x' || ent[1] == 'X');
      const uint32_t base = hex ? 16 : 10;
      size_t k = hex ? 2 : 1;
      bool valid = k < ent.size();  // require at least one digit
      uint32_t cp = 0;
      for (; valid && k < ent.size(); ++k) {
        const char c = ent[k];
        int digit;
        if (c >= '0' && c <= '9') {
          digit = c - '0';
        } else if (hex && c >= 'a' && c <= 'f') {
          digit = c - 'a' + 10;
        } else if (hex && c >= 'A' && c <= 'F') {
          digit = c - 'A' + 10;
        } else {
          valid = false;
          break;
        }
        cp = cp * base + static_cast<uint32_t>(digit);
        if (cp > 0x10FFFF) {  // out of range; also caps any overflow
          valid = false;
          break;
        }
      }
      const bool surrogate = cp >= 0xD800 && cp <= 0xDFFF;
      if (valid && cp >= 0x1 && !surrogate) {
        AppendUtf8(out, cp);
      } else {
        out.append(s.substr(i, semi - i + 1));  // keep verbatim
      }
    } else {
      // Unknown entity: keep verbatim.
      out.append(s.substr(i, semi - i + 1));
    }
    i = semi + 1;
  }
  return out;
}

std::string Trim(absl::string_view s) {
  size_t b = 0, e = s.size();
  while (b < e && IsSpace(s[b])) ++b;
  while (e > b && IsSpace(s[e - 1])) --e;
  return std::string(s.substr(b, e - b));
}

class Parser {
 public:
  explicit Parser(absl::string_view xml) : s_(xml) {}

  absl::StatusOr<XmlNode> Parse() {
    SkipBom();
    if (!SkipMisc()) return Fail("malformed prolog");
    if (pos_ >= s_.size() || s_[pos_] != '<') {
      return Fail("expected root element");
    }
    auto root = ParseElement(0);
    if (!root.ok()) return root.status();
    return root;
  }

 private:
  absl::Status Fail(absl::string_view msg) {
    return absl::InvalidArgumentError(
        absl::StrCat("XML parse error at byte ", pos_, ": ", msg));
  }

  void SkipBom() {
    if (s_.size() >= 3 && static_cast<unsigned char>(s_[0]) == 0xEF &&
        static_cast<unsigned char>(s_[1]) == 0xBB &&
        static_cast<unsigned char>(s_[2]) == 0xBF) {
      pos_ = 3;
    }
  }

  void SkipSpace() {
    while (pos_ < s_.size() && IsSpace(s_[pos_])) ++pos_;
  }

  // Skips whitespace, comments, the XML declaration, DOCTYPE and PIs.
  bool SkipMisc() {
    while (true) {
      SkipSpace();
      if (StartsWith("<!--")) {
        auto end = s_.find("-->", pos_ + 4);
        if (end == absl::string_view::npos) return false;
        pos_ = end + 3;
      } else if (StartsWith("<?")) {
        auto end = s_.find("?>", pos_ + 2);
        if (end == absl::string_view::npos) return false;
        pos_ = end + 2;
      } else if (StartsWith("<!DOCTYPE") || StartsWith("<!")) {
        auto end = s_.find('>', pos_);
        if (end == absl::string_view::npos) return false;
        pos_ = end + 1;
      } else {
        return true;
      }
    }
  }

  bool StartsWith(absl::string_view lit) const {
    return s_.substr(pos_, lit.size()) == lit;
  }

  // Element names have their namespace prefix stripped; attribute names are
  // kept verbatim so the audit pass (adm_audit.cc) can tell namespace
  // plumbing (`xmlns`, `xmlns:adm`, `xsi:schemaLocation`) apart from real
  // metadata attributes. Parser lookups only use unprefixed names, which
  // real-world files never prefix.
  std::string ReadName(bool strip_prefix) {
    size_t start = pos_;
    while (pos_ < s_.size() && !IsSpace(s_[pos_]) && s_[pos_] != '>' &&
           s_[pos_] != '/' && s_[pos_] != '=') {
      ++pos_;
    }
    absl::string_view raw = s_.substr(start, pos_ - start);
    return std::string(strip_prefix ? LocalName(raw) : raw);
  }

  absl::StatusOr<XmlNode> ParseElement(int depth) {
    if (depth > kMaxDepth) return Fail("element nesting too deep");
    ++pos_;  // consume '<'
    XmlNode node;
    node.name = ReadName(/*strip_prefix=*/true);

    // Attributes.
    while (true) {
      SkipSpace();
      if (pos_ >= s_.size()) return Fail("unterminated start tag");
      char c = s_[pos_];
      if (c == '>' || c == '/') break;
      std::string attr_name = ReadName(/*strip_prefix=*/false);
      SkipSpace();
      if (pos_ >= s_.size() || s_[pos_] != '=') {
        // Valueless attribute; skip.
        node.attributes.emplace_back(std::move(attr_name), "");
        continue;
      }
      ++pos_;  // '='
      SkipSpace();
      if (pos_ >= s_.size() || (s_[pos_] != '"' && s_[pos_] != '\'')) {
        return Fail("expected quoted attribute value");
      }
      char quote = s_[pos_++];
      size_t vstart = pos_;
      while (pos_ < s_.size() && s_[pos_] != quote) ++pos_;
      if (pos_ >= s_.size()) return Fail("unterminated attribute value");
      absl::string_view raw = s_.substr(vstart, pos_ - vstart);
      ++pos_;  // closing quote
      node.attributes.emplace_back(std::move(attr_name), DecodeEntities(raw));
    }

    if (s_[pos_] == '/') {
      ++pos_;
      if (pos_ >= s_.size() || s_[pos_] != '>') return Fail("malformed '/>'");
      ++pos_;
      return node;  // Self-closing.
    }
    ++pos_;  // consume '>'

    // Content.
    std::string text;
    while (true) {
      if (pos_ >= s_.size()) return Fail("unterminated element content");
      if (StartsWith("<![CDATA[")) {
        size_t cstart = pos_ + 9;
        auto end = s_.find("]]>", cstart);
        if (end == absl::string_view::npos) return Fail("unterminated CDATA");
        text.append(s_.substr(cstart, end - cstart));
        pos_ = end + 3;
      } else if (StartsWith("<!--")) {
        auto end = s_.find("-->", pos_ + 4);
        if (end == absl::string_view::npos) return Fail("unterminated comment");
        pos_ = end + 3;
      } else if (StartsWith("</")) {
        pos_ += 2;
        if (ReadName(/*strip_prefix=*/true) != node.name) {
          return Fail("end tag does not match its start tag");
        }
        SkipSpace();
        if (pos_ >= s_.size() || s_[pos_] != '>')
          return Fail("malformed end tag");
        ++pos_;
        break;
      } else if (s_[pos_] == '<') {
        auto child = ParseElement(depth + 1);
        if (!child.ok()) return child.status();
        node.children.push_back(*std::move(child));
      } else {
        size_t tstart = pos_;
        while (pos_ < s_.size() && s_[pos_] != '<') ++pos_;
        text.append(DecodeEntities(s_.substr(tstart, pos_ - tstart)));
      }
    }
    node.text = Trim(text);
    return node;
  }

  absl::string_view s_;
  size_t pos_ = 0;
};

}  // namespace

const std::string* XmlNode::Attr(absl::string_view key) const {
  for (const auto& [k, v] : attributes) {
    if (k == key) return &v;
  }
  return nullptr;
}

std::string XmlNode::AttrOr(absl::string_view key,
                            absl::string_view fallback) const {
  const std::string* v = Attr(key);
  return v ? *v : std::string(fallback);
}

const XmlNode* XmlNode::Child(absl::string_view name) const {
  for (const auto& c : children) {
    if (c.name == name) return &c;
  }
  return nullptr;
}

std::vector<const XmlNode*> XmlNode::Children(absl::string_view name) const {
  std::vector<const XmlNode*> out;
  for (const auto& c : children) {
    if (c.name == name) out.push_back(&c);
  }
  return out;
}

const XmlNode* XmlNode::FindDescendant(absl::string_view name) const {
  if (this->name == name) return this;
  for (const auto& c : children) {
    if (const XmlNode* found = c.FindDescendant(name)) return found;
  }
  return nullptr;
}

absl::StatusOr<XmlNode> ParseXml(absl::string_view xml) {
  Parser p(xml);
  return p.Parse();
}

}  // namespace adm2iamf
