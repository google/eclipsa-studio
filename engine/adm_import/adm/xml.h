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

// Minimal XML DOM parser, tailored to ADM `axml` payloads.
//
// ADM XML is plain element/attribute/text XML. This parser is deliberately
// small and tolerant: it skips the XML declaration, comments, DOCTYPE and
// processing instructions, decodes the standard entities, handles CDATA and
// self-closing tags, and strips namespace prefixes (`adm:audioObject` ->
// `audioObject`) so callers needn't care about namespacing. It is not a
// general-purpose or validating parser; it exists so we own the ADM read path
// without an external XML dependency.

#ifndef ADM2IAMF_ADM_XML_H_
#define ADM2IAMF_ADM_XML_H_

#include <string>
#include <utility>
#include <vector>

#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"

namespace adm2iamf {

struct XmlNode {
  std::string name;  // Local name, namespace prefix stripped.
  std::vector<std::pair<std::string, std::string>> attributes;
  std::string text;  // Concatenated direct text content (entity-decoded).
  std::vector<XmlNode> children;

  // Returns the value of `key`, or nullptr if the attribute is absent.
  const std::string* Attr(absl::string_view key) const;
  std::string AttrOr(absl::string_view key, absl::string_view fallback) const;

  // First direct child named `name`, or nullptr.
  const XmlNode* Child(absl::string_view name) const;
  // All direct children named `name` (in document order).
  std::vector<const XmlNode*> Children(absl::string_view name) const;

  // First descendant (depth-first, self included) named `name`, or nullptr.
  const XmlNode* FindDescendant(absl::string_view name) const;
};

// Parses `xml` and returns the root element.
absl::StatusOr<XmlNode> ParseXml(absl::string_view xml);

}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_XML_H_
