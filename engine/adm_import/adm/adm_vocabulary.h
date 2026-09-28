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

// ADM spec vocabulary (BS.2076-3): the allowlist of elements, attributes and
// value domains the importer recognizes, used by the audit pass (adm_audit.h)
// to classify everything an axml payload carries.
//
// The tables in adm_vocabulary.cc are transcribed from the published ITU-R
// recommendations (freely downloadable from itu.int; the PDFs are not
// vendored); each entry carries its spec section. Entries also
// record whether ParseAxml() actually consumes the field, so the audit can
// distinguish "spec, implemented" from "spec, ignored by this importer".

#ifndef ADM2IAMF_ADM_ADM_VOCABULARY_H_
#define ADM2IAMF_ADM_ADM_VOCABULARY_H_

#include <optional>

#include "absl/strings/string_view.h"
#include "absl/types/span.h"

namespace adm2iamf {
namespace adm {
namespace vocab {

// Value domain of an attribute value or a leaf element's text content.
struct ValueDomain {
  enum class Kind {
    kAny,           // No constraint beyond being present.
    kId,            // ADM id; `pattern` gives the shape, e.g. "AP_hhhhhhhh".
    kTimecode,      // BS.2076-3 timecode grammar (incl. fractional-sample).
    kFloat,         // Decimal in [min, max].
    kInt,           // Integer in [min, max].
    kBool,          // "0" or "1".
    kEnum,          // One of `enums` (pipe-separated).
    kSpeakerLabel,  // BS.2051 loudspeaker label grammar.
  };
  Kind kind = Kind::kAny;
  double min = 0.0;
  double max = 0.0;
  const char* enums = nullptr;    // kEnum: "linear|dB".
  const char* pattern = nullptr;  // kId: 'h' = hex digit, rest literal.
};

// Outcome of checking a value against its domain.
enum class ValueCheck {
  kValid,    // Matches the spec grammar/range.
  kLenient,  // Not the spec form, but a documented importer leniency
             // accepts it (e.g. bare-seconds timecode).
  kInvalid,  // Outside the domain; the importer substitutes a fallback.
};

ValueCheck CheckValue(const ValueDomain& domain, absl::string_view value);

struct AttrSpec {
  const char* name;
  ValueDomain domain;
  bool consumed;  // ParseAxml() reads this attribute.
};

// One element in a specific context. `key` is the lookup key used by the
// audit walker: usually the plain element name; where the same name has
// different content per context, a qualified key is used —
// "ds/position" vs "obj/position" (audioBlockFormat children by
// typeDefinition prefix: ds/obj/hoa/mtx/bin) and "parent/name" elsewhere.
struct ElementSpec {
  const char* key;
  bool consumed;  // ParseAxml() reads this element at all.
  ValueDomain text;
  absl::Span<const AttrSpec> attrs;
  // Allowed child element names (unqualified). The walker re-qualifies
  // them by context before lookup.
  absl::Span<const char* const> children;
  const char* spec_ref;  // e.g. "BS.2076-3 §5.4.1".
};

// Looks up a context key; nullptr if the vocabulary does not define it.
const ElementSpec* FindElement(absl::string_view key);

// The whole element table, for tooling and the vocabulary self-tests
// (e.g. asserting every allowed child name resolves to a spec).
absl::Span<const ElementSpec> AllElements();

// True if `name` is a spec element name in *any* context — used to word
// findings ("misplaced ADM element" vs "not an ADM element").
bool IsKnownElementName(absl::string_view name);

// Strips the BS.2094-2 §4.1.1 URN wrapper
// ("urn:itu:bs:2051:<version>:speaker:M+030" → "M+030"). Non-URN input and
// malformed URNs are returned verbatim.
absl::string_view StripSpeakerLabelUrn(absl::string_view label);

// True if `label` is one of the loudspeaker labels the specs actually
// enumerate: BS.2051-3 Table 1 ∪ BS.2094-2 Tables 1A/1B, plus the three LFE
// spellings. This is an allowlist, not a grammar — "M+023" parses
// structurally but is not a real BS.2051 label, so it is false here.
// Accepts both the bare and the URN spelling.
bool IsSpecSpeakerLabel(absl::string_view label);

// A structurally decomposed BS.2051 label: a layer prefix, a sign, and
// either an azimuth magnitude or the screen-edge marker.
struct SpeakerLabelParts {
  absl::string_view layer;  // "M", "U", "UH", "B" or "T".
  int sign = 1;             // +1 for '+', -1 for '-'.
  bool screen = false;      // The M±SC screen-edge pair.
  int azimuth = 0;          // Magnitude in degrees; unset when `screen`.
};

// Parses the BS.2051 label grammar "[M|U|UH|B|T][+-](NNN|SC)". This is the
// shape check only — a label can parse here and still not be one the specs
// enumerate (see IsSpecSpeakerLabel). The importer's own label→position
// resolution (scene/layouts.cc) is built on this, so the audit can tell
// "shape the importer accepts" apart from "value outside the spec".
std::optional<SpeakerLabelParts> ParseSpeakerLabelGrammar(
    absl::string_view label);

}  // namespace vocab
}  // namespace adm
}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_ADM_VOCABULARY_H_
