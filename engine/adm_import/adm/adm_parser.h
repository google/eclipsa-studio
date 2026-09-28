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

// Parses an ADM `axml` payload and a `chna` chunk into the in-memory Model.

#ifndef ADM2IAMF_ADM_ADM_PARSER_H_
#define ADM2IAMF_ADM_ADM_PARSER_H_

#include <cstdint>
#include <optional>
#include <vector>

#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "adm_import/adm/adm_model.h"
#include "adm_import/adm/xml.h"

namespace adm2iamf {
namespace adm {

// Parses a BS.2076-3 §5.13 timecode to seconds. Accepts all three spec
// forms — decimal "hh:mm:ss.zzzzz" (≥5 fractional digits),
// fractional-sample "hh:mm:ss.<samples>S<rate>", and shortform
// "<samples>S<rate>" — plus the documented leniencies (bare seconds,
// "mm:ss", short fractions). Returns nullopt for anything else; call
// sites fall back with value_or(0.0) and the audit reports the invalid.
std::optional<double> ParseTimecode(absl::string_view s);

// Builds a Model from an already-parsed XML tree, so callers that also
// audit the payload parse the XML once.
Model BuildModel(const XmlNode& root);

// Parses the `axml` XML text into a Model (without the chna table).
absl::StatusOr<Model> ParseAxml(absl::string_view axml);

// Parses a binary `chna` chunk (ITU-R BS.2088) into track-UID rows.
absl::StatusOr<std::vector<ChnaEntry>> ParseChna(
    absl::Span<const uint8_t> chna);

}  // namespace adm
}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_ADM_PARSER_H_
