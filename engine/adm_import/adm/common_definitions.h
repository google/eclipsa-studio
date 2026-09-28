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

// BS.2094 common-definition resolution.
//
// EBU/ITU ADM files reference ITU-R BS.2094 "common definitions" -- standard
// audioPackFormat / audioChannelFormat IDs (AP_0001xxxx / AC_0001xxxx, the
// 'xxxx' <= 0x0FFF namespace) -- WITHOUT inlining them in the axml. A bed then
// appears only as an object's pack reference plus chna track bindings, with no
// positions anywhere in the file. (Verified on a real EBU master: a 7.1.2 bed
// carried as one object referencing AP_00010016, channels AC_0001xxxx.)
//
// This pass synthesizes the missing common-definition DirectSpeakers packs and
// channels into the model so the profile-blind scene adapter renders the bed
// unchanged. Each synthesized channel carries only its ITU speaker label (e.g.
// "M+030"); position resolution stays in the layout table, the single source of
// truth. Run it after parsing axml + chna, before building the scene.

#ifndef ADM2IAMF_ADM_COMMON_DEFINITIONS_H_
#define ADM2IAMF_ADM_COMMON_DEFINITIONS_H_

#include <string>
#include <vector>

#include "adm_import/adm/adm_model.h"

namespace adm2iamf {
namespace adm {

// Fills in referenced-but-missing common-definition DirectSpeakers packs and
// channels in `model`, deriving each pack's channel list (in order) from the
// referencing object's track UIDs via the chna table. Returns the common-def
// channel IDs referenced but absent from the BS.2094 table -- left unresolved
// (never mis-placed), for diagnostics.
std::vector<std::string> ResolveCommonDefinitions(Model& model);

}  // namespace adm
}  // namespace adm2iamf

#endif  // ADM2IAMF_ADM_COMMON_DEFINITIONS_H_
