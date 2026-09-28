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

#include "adm_import/adm/adm_audit.h"

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

#include "absl/container/flat_hash_map.h"
#include "absl/strings/match.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "adm_import/adm/adm_vocabulary.h"
#include "adm_import/adm/json_escape.h"

namespace adm2iamf {
namespace adm {
namespace {

using vocab::ElementSpec;
using vocab::FindElement;
using vocab::ValueCheck;

// Depth-first search for `name`, recording the wrapper chain above the match.
const XmlNode* FindWithPath(const XmlNode& node, absl::string_view name,
                            std::vector<const XmlNode*>& chain) {
  if (node.name == name) return &node;
  chain.push_back(&node);
  for (const auto& c : node.children) {
    if (const XmlNode* hit = FindWithPath(c, name, chain)) return hit;
  }
  chain.pop_back();
  return nullptr;
}

// Block-child context prefix for a channel/pack typeDefinition, resolved from
// the textual attribute or the numeric typeLabel (same acceptance as
// ParseAxml). Empty when the type is undefined/unknown.
absl::string_view TypePrefix(const XmlNode& n) {
  const std::string td = n.AttrOr("typeDefinition", "");
  const std::string tl = n.AttrOr("typeLabel", "");
  if (td == "DirectSpeakers" || tl == "0001") return "ds";
  if (td == "Matrix" || tl == "0002") return "mtx";
  if (td == "Objects" || tl == "0003") return "obj";
  if (td == "HOA" || tl == "0004") return "hoa";
  if (td == "Binaural" || tl == "0005") return "bin";
  return "";
}

// Display id for a path segment: the element's own id-ish attribute.
std::string SegmentId(const XmlNode& n) {
  for (const auto& [k, v] : n.attributes) {
    if (absl::EndsWith(k, "ID") || k == "UID") return v;
  }
  return "";
}

// Upper bound on distinct enumerated findings. Purely a memory guard for
// hostile or badly-broken payloads -- AuditCounts stays exact past it, and
// AuditCounts::findings_dropped records the shortfall.
constexpr size_t kMaxFindings = 2000;

class Walker {
 public:
  explicit Walker(const AuditOptions& options)
      : cap_(options.tree_siblings_cap) {}

  AuditReport Run(const XmlNode& root) {
    std::vector<const XmlNode*> chain;
    const XmlNode* scope = FindWithPath(root, "audioFormatExtended", chain);
    if (scope == nullptr) {
      scope = &root;
      chain.clear();
    }
    for (size_t i = 0; i < chain.size(); ++i) {
      absl::StrAppend(&report_.wrapper_path, i ? "/" : "", chain[i]->name);
    }
    // The scope element itself is audited against its vocabulary entry when
    // it is audioFormatExtended; a bare root of any other name is walked as
    // an anonymous container (children looked up unqualified) so that files
    // with no wrapper still audit their ADM elements.
    const bool emit = cap_ > 0;
    const ElementSpec* spec = FindElement(scope->name);
    if (spec != nullptr) {
      WalkElement(*scope, *spec, scope->name, "", emit);
    } else {
      if (emit) {
        tree_ += "{\"n\":";
        AppendJsonString(tree_, scope->name);
        tree_ += ",\"c\":\"container\",\"a\":[],";
      }
      WalkCappedChildren(*scope, /*spec=*/nullptr, "", "", emit);
      if (emit) tree_ += "}";
    }
    report_.findings = std::move(findings_);
    report_.tree_json = std::move(tree_);
    return std::move(report_);
  }

 private:
  void Add(AuditClass cls, bool is_attr, absl::string_view subject,
           absl::string_view path, absl::string_view value,
           absl::string_view note) {
    switch (cls) {
      case AuditClass::kSpecIgnored:
        ++report_.counts.spec_ignored;
        break;
      case AuditClass::kUnknown:
        ++report_.counts.unknown;
        break;
      case AuditClass::kInvalidValue:
        ++report_.counts.invalid_value;
        break;
      case AuditClass::kLenientValue:
        ++report_.counts.lenient_value;
        break;
    }
    // Value-class findings dedup per distinct value (each bad value matters
    // — e.g. every distinct non-spec speaker label); the other classes dedup
    // per subject to stay compact on files with thousands of blocks.
    const bool per_value =
        cls == AuditClass::kInvalidValue || cls == AuditClass::kLenientValue;
    const std::string key =
        absl::StrCat(static_cast<int>(cls), "|", is_attr ? "a" : "e", "|",
                     subject, "|", per_value ? value : "", "|", note);
    auto it = dedup_.find(key);
    if (it != dedup_.end()) {
      ++findings_[it->second].count;
      return;
    }
    // Value-class findings key on the value, so a file whose per-block
    // timecodes or positions are all distinct and all non-spec would
    // otherwise mint one finding per block. The counts above stay exact;
    // only the enumerated detail is bounded.
    if (findings_.size() >= kMaxFindings) {
      ++report_.counts.findings_dropped;
      return;
    }
    AuditFinding f;
    f.cls = cls;
    f.is_attribute = is_attr;
    f.subject = std::string(subject);
    f.path = std::string(path);
    f.value = std::string(value);
    f.note = std::string(note);
    dedup_.emplace(key, findings_.size());
    findings_.push_back(std::move(f));
  }

  // Appends one attribute entry to the tree ("a" array), comma-managed via
  // `first`.
  void EmitAttr(absl::string_view name, absl::string_view value,
                absl::string_view cls, bool* first) {
    if (!*first) tree_ += ",";
    *first = false;
    tree_ += "{\"k\":";
    AppendJsonString(tree_, name);
    tree_ += ",\"v\":";
    AppendJsonString(tree_, value);
    tree_ += ",\"c\":";
    AppendJsonString(tree_, cls);
    tree_ += "}";
  }

  // Audits one attribute of an element whose spec is known; when `emit`,
  // appends its tree entry.
  void WalkAttr(const ElementSpec& spec, const std::string& path,
                absl::string_view elem_name, absl::string_view name,
                absl::string_view value, bool emit, bool* first_attr) {
    // Namespace plumbing is not metadata: xmlns declarations and xsi schema
    // attributes are skipped silently (xml.cc keeps prefixed attribute names
    // verbatim). Shown greyed-out ("ns") in the tree.
    if (name == "xmlns" || absl::StartsWith(name, "xmlns:") ||
        absl::StartsWith(name, "xsi:")) {
      if (emit) EmitAttr(name, value, "ns", first_attr);
      return;
    }
    ++report_.counts.attributes;
    const std::string subject = absl::StrCat(elem_name, "@", name);
    if (absl::StrContains(name, ':')) {
      Add(AuditClass::kUnknown, true, subject, path, value,
          "foreign-namespaced attribute; discarded");
      if (emit) EmitAttr(name, value, "unknown", first_attr);
      return;
    }
    for (const auto& a : spec.attrs) {
      if (name != a.name) continue;
      absl::string_view cls = a.consumed ? "ok" : "ignored";
      bool reported = false;
      switch (vocab::CheckValue(a.domain, value)) {
        case ValueCheck::kValid:
          break;
        case ValueCheck::kLenient:
          Add(AuditClass::kLenientValue, true, subject, path, value,
              "accepted through a documented leniency, not the spec form");
          cls = "lenient";
          reported = true;
          break;
        case ValueCheck::kInvalid:
          Add(AuditClass::kInvalidValue, true, subject, path, value,
              "value outside the spec domain; fallback substituted");
          cls = "invalid";
          reported = true;
          break;
      }
      if (!reported && !a.consumed) {
        Add(AuditClass::kSpecIgnored, true, subject, path, value,
            absl::StrCat("spec attribute not read by this importer (",
                         spec.spec_ref, ")"));
      } else if (cls == "ok") {
        ++report_.counts.ok;
      }
      if (emit) EmitAttr(name, value, cls, first_attr);
      return;
    }
    Add(AuditClass::kUnknown, true, subject, path, value,
        absl::StrCat("attribute not defined by ", spec.spec_ref,
                     "; discarded"));
    if (emit) EmitAttr(name, value, "unknown", first_attr);
  }

  // Resolves the vocabulary entry for a child element name in context.
  // Lookup order: block-type-qualified, parent-qualified, plain.
  static const ElementSpec* ResolveChild(absl::string_view name,
                                         absl::string_view parent_name,
                                         absl::string_view block_prefix) {
    if (!block_prefix.empty()) {
      if (const ElementSpec* s =
              FindElement(absl::StrCat(block_prefix, "/", name))) {
        return s;
      }
    }
    if (const ElementSpec* s =
            FindElement(absl::StrCat(parent_name, "/", name))) {
      return s;
    }
    return FindElement(name);
  }

  // Audits one child element. `parent_spec` may be null (anonymous root
  // container: any vocabulary element is allowed). Unknown subtrees are
  // reported once and not walked further. When `emit`, exactly one tree node
  // is appended (the caller manages commas).
  void WalkChild(const XmlNode& child, const ElementSpec* parent_spec,
                 absl::string_view parent_name, absl::string_view block_prefix,
                 const std::string& base_path, bool emit) {
    ++report_.counts.elements;
    const std::string id = SegmentId(child);
    std::string path = absl::StrCat(base_path, child.name);
    if (!id.empty()) absl::StrAppend(&path, "[", id, "]");

    bool allowed = parent_spec == nullptr;
    if (parent_spec != nullptr) {
      for (const char* c : parent_spec->children) {
        if (child.name == c) {
          allowed = true;
          break;
        }
      }
    }
    const ElementSpec* spec =
        ResolveChild(child.name, parent_name, block_prefix);
    if (!allowed || spec == nullptr) {
      const char* note =
          vocab::IsKnownElementName(child.name)
              ? "ADM element not allowed in this context; subtree discarded"
              : "element not defined by BS.2076-3; subtree discarded";
      Add(AuditClass::kUnknown, false, child.name, path, "", note);
      if (emit) {
        tree_ += "{\"n\":";
        AppendJsonString(tree_, child.name);
        tree_ += ",\"c\":\"unknown\"}";
      }
      return;
    }
    WalkElement(child, *spec, path, block_prefix, emit);
  }

  void WalkElement(const XmlNode& node, const ElementSpec& spec,
                   const std::string& path, absl::string_view block_prefix,
                   bool emit) {
    if (emit) {
      tree_ += "{\"n\":";
      AppendJsonString(tree_, node.name);
      tree_ += ",\"a\":[";
    }
    bool first_attr = true;
    for (const auto& [name, value] : node.attributes) {
      WalkAttr(spec, path, node.name, name, value, emit, &first_attr);
    }
    if (emit) tree_ += "]";

    // Leaf text content. Position values get coordinate-dependent ranges:
    // azimuth ±180, elevation ±90, distance >= 0 (BS.2076-3 Table A1-17);
    // X/Y/Z keep the finiteness-only check.
    vocab::ValueDomain text_domain = spec.text;
    if (node.name == "position") {
      const std::string coord = node.AttrOr("coordinate", "");
      if (coord == "azimuth") {
        text_domain.min = -180;
        text_domain.max = 180;
      } else if (coord == "elevation") {
        text_domain.min = -90;
        text_domain.max = 90;
      } else if (coord == "distance") {
        text_domain.min = 0;
      }
    }
    absl::string_view cls = spec.consumed ? "ok" : "ignored";
    bool reported = false;
    if (text_domain.kind != vocab::ValueDomain::Kind::kAny ||
        !node.text.empty()) {
      switch (vocab::CheckValue(text_domain, node.text)) {
        case ValueCheck::kValid:
          break;
        case ValueCheck::kLenient:
          Add(AuditClass::kLenientValue, false, node.name, path, node.text,
              "accepted through a documented leniency, not the spec form");
          cls = "lenient";
          reported = true;
          break;
        case ValueCheck::kInvalid:
          Add(AuditClass::kInvalidValue, false, node.name, path, node.text,
              "value outside the spec domain; fallback substituted");
          cls = "invalid";
          reported = true;
          break;
      }
    }
    // As in WalkAttr: a value finding already describes this element, so
    // don't also file it as spec-ignored.
    if (!reported && !spec.consumed) {
      Add(AuditClass::kSpecIgnored, false, node.name, path, "",
          absl::StrCat("spec element not read by this importer (",
                       spec.spec_ref, ")"));
    } else if (cls == "ok") {
      ++report_.counts.ok;
    }
    if (emit) {
      if (!node.text.empty()) {
        tree_ += ",\"t\":";
        AppendJsonString(tree_, node.text);
      }
      tree_ += ",\"c\":";
      AppendJsonString(tree_, cls);
    }

    // Channel and pack formats set the block-child context for descendants.
    absl::string_view prefix = block_prefix;
    if (node.name == "audioChannelFormat" || node.name == "audioPackFormat") {
      prefix = TypePrefix(node);
    }
    const std::string base_path = absl::StrCat(path, "/");
    if (emit) tree_ += ",";
    WalkCappedChildren(node, &spec, prefix, base_path, emit);
    if (emit) tree_ += "}";
  }

  // Walks `node`'s children with the same-named-sibling cap, emitting the
  // "k":[...] array plus a per-name "s" skipped summary when `emit` is set.
  // The surplus is audited but only summarized so huge block lists stay
  // viewable. `spec` is the parent's spec — null for an anonymous root
  // container, whose children are looked up unqualified; the cap applies
  // either way.
  void WalkCappedChildren(const XmlNode& node, const ElementSpec* spec,
                          absl::string_view prefix,
                          const std::string& base_path, bool emit) {
    if (emit) tree_ += "\"k\":[";
    absl::flat_hash_map<std::string, int> name_counts;
    absl::flat_hash_map<std::string, int> skipped;
    bool first_child = true;
    for (const auto& c : node.children) {
      const bool child_emit = emit && ++name_counts[c.name] <= cap_;
      if (emit && !child_emit) ++skipped[c.name];
      if (child_emit) {
        if (!first_child) tree_ += ",";
        first_child = false;
      }
      WalkChild(c, spec, node.name, prefix, base_path, child_emit);
    }
    if (!emit) return;
    tree_ += "]";
    if (!skipped.empty()) {
      tree_ += ",\"s\":{";
      bool first_s = true;
      for (const auto& [name, count] : skipped) {
        if (!first_s) tree_ += ",";
        first_s = false;
        AppendJsonString(tree_, name);
        absl::StrAppend(&tree_, ":", count);
      }
      tree_ += "}";
    }
  }

  const int cap_;
  AuditReport report_;
  std::vector<AuditFinding> findings_;
  absl::flat_hash_map<std::string, size_t> dedup_;
  std::string tree_;
};

absl::string_view ClassName(AuditClass cls) {
  switch (cls) {
    case AuditClass::kSpecIgnored:
      return "spec_ignored";
    case AuditClass::kUnknown:
      return "unknown";
    case AuditClass::kInvalidValue:
      return "invalid_value";
    case AuditClass::kLenientValue:
      return "lenient_value";
  }
  return "?";
}

}  // namespace

AuditReport AuditAxml(const XmlNode& root, const AuditOptions& options) {
  return Walker(options).Run(root);
}

std::string AuditReport::ToJson() const {
  std::string out = "{\"wrapper_path\":";
  AppendJsonString(out, wrapper_path);
  absl::StrAppend(&out, ",\"counts\":{\"elements\":", counts.elements,
                  ",\"attributes\":", counts.attributes, ",\"ok\":", counts.ok,
                  ",\"spec_ignored\":", counts.spec_ignored,
                  ",\"unknown\":", counts.unknown,
                  ",\"invalid_value\":", counts.invalid_value,
                  ",\"lenient_value\":", counts.lenient_value,
                  ",\"findings_dropped\":", counts.findings_dropped, "}");
  out += ",\"findings\":[";
  for (size_t i = 0; i < findings.size(); ++i) {
    const AuditFinding& f = findings[i];
    if (i) out.push_back(',');
    out += "{\"class\":";
    AppendJsonString(out, ClassName(f.cls));
    absl::StrAppend(&out, ",\"kind\":\"",
                    f.is_attribute ? "attribute" : "element",
                    "\",\"subject\":");
    AppendJsonString(out, f.subject);
    out += ",\"path\":";
    AppendJsonString(out, f.path);
    out += ",\"value\":";
    AppendJsonString(out, f.value);
    out += ",\"note\":";
    AppendJsonString(out, f.note);
    absl::StrAppend(&out, ",\"count\":", f.count, "}");
  }
  out += "]";
  if (!tree_json.empty()) {
    absl::StrAppend(&out, ",\"tree\":", tree_json);
  }
  out += "}";
  return out;
}

}  // namespace adm
}  // namespace adm2iamf
