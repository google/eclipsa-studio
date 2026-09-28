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

// Audit pass over a parsed axml tree: classifies every element and attribute
// against the ADM spec vocabulary (adm_vocabulary.h) without changing what
// the parser does. This is the visibility layer behind strict-EBU import —
// it reports what a file carries that is outside the spec (and would be
// discarded), which spec fields the importer ignores, and where values fall
// outside their domains (and get fallbacks).
//
// The audit walks the same scope ParseAxml() reads: the audioFormatExtended
// element (or the document root when that wrapper is absent). Wrapper
// elements above it (ebuCoreMain/...) are recorded as a path, not audited.

#ifndef ADM2IAMF_ADM_ADM_AUDIT_H_
#define ADM2IAMF_ADM_ADM_AUDIT_H_

#include <string>
#include <vector>

#include "adm_import/adm/xml.h"

namespace adm2iamf {
namespace adm {

enum class AuditClass {
  kSpecIgnored,   // In the spec vocabulary; this importer does not read it.
  kUnknown,       // Not in the spec vocabulary; discarded on import.
  kInvalidValue,  // Spec field whose value is outside its domain; a
                  // fallback is substituted on import.
  kLenientValue,  // Spec field whose value is not the spec form but is
                  // accepted through a documented leniency.
};

// One deduplicated audit finding. Identical findings (same class, kind,
// subject and note) are collapsed into one entry with a count; `path`
// keeps the first occurrence.
struct AuditFinding {
  AuditClass cls;
  bool is_attribute = false;  // Subject is an attribute (vs an element).
  std::string subject;        // Element name, or "element@attr".
  std::string path;   // First occurrence, e.g. "audioObject[AO_1001]/gain".
  std::string value;  // Offending value (invalid/lenient), else empty.
  std::string note;   // Explanation with spec reference.
  int count = 1;
};

struct AuditCounts {
  int elements = 0;    // Elements visited.
  int attributes = 0;  // Attributes visited (xmlns declarations skipped).
  int ok = 0;          // Spec-valid and consumed by the importer.
  int spec_ignored = 0;
  int unknown = 0;
  int invalid_value = 0;
  int lenient_value = 0;
  // Distinct findings the walker declined to enumerate because it hit its
  // internal ceiling. The counts above still include them.
  int findings_dropped = 0;
};

struct AuditOptions {
  // When > 0, `AuditReport::tree_json` is populated with the annotated
  // element tree, keeping at most this many same-named children per parent
  // node; the surplus is still audited (counts/findings are exact) but
  // summarized in the tree as a per-name skipped count. 0 disables the tree.
  int tree_siblings_cap = 0;
};

struct AuditReport {
  // Wrapper chain above the audited scope, "/"-joined ("" when the root
  // itself is audioFormatExtended or no wrapper was found).
  std::string wrapper_path;
  AuditCounts counts;
  std::vector<AuditFinding> findings;

  // Annotated element tree as a JSON object (see AuditOptions); empty when
  // not requested. Shape: {"n":name, "c":class, "a":[{"k","v","c"}...],
  // "t":text, "k":[children...], "s":{name:skipped_count}}.
  std::string tree_json;

  // Serializes the report as a JSON object (same hand-built style as the
  // probe JSON). Includes "tree" when tree_json is non-empty.
  std::string ToJson() const;
};

// Audits the parsed axml document rooted at `root`.
AuditReport AuditAxml(const XmlNode& root, const AuditOptions& options = {});

}  // namespace adm
}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_ADM_AUDIT_H_
