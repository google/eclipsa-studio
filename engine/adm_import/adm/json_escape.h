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

// JSON string emission for the hand-rolled probe/audit JSON (the repo stays
// dependency-light; no JSON dep). File-derived text — chunk ids, ADM names,
// attribute values — flows through here on its way to the Dart side, whose
// UTF-8 decoder throws on malformed input, so this is also the sanitation
// point: bytes that do not form well-formed UTF-8 are replaced with U+FFFD.

#ifndef ADM2IAMF_ADM_JSON_ESCAPE_H_
#define ADM2IAMF_ADM_JSON_ESCAPE_H_

#include <string>

#include "absl/strings/string_view.h"

namespace adm2iamf {
namespace adm {

// Appends `s` to `out` as a quoted, escaped JSON string. Control characters
// are \u-escaped; any byte sequence that is not well-formed UTF-8 (RFC 3629:
// overlongs, surrogates and truncated tails included) is replaced with one
// U+FFFD per offending byte, so the output is always valid UTF-8.
void AppendJsonString(std::string& out, absl::string_view s);

}  // namespace adm
}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_JSON_ESCAPE_H_
