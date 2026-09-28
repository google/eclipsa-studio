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

// Front-end adapter: ADM model -> canonical Scene.
//
// DirectSpeakers beds reached from the programme/object graph become static
// Sources at their canonical (az, el); Objects packs become dynamic
// ObjectSources with keyframe timelines. Bed channels resolve
// position-first per BS.2076/2094 (frequency LFE marker, explicit polar,
// spec labels, cube-grid positions, physical fallback) and every channel's
// outcome is recorded in Scene::resolutions.

#ifndef ADM2IAMF_SCENE_ADM_ADAPTER_H_
#define ADM2IAMF_SCENE_ADM_ADAPTER_H_

#include "absl/status/statusor.h"
#include "adm_import/adm/adm_model.h"
#include "adm_import/scene/scene.h"

namespace adm2iamf {

// Builds the canonical scene of static bed sources and dynamic objects
// from `model`.
absl::StatusOr<Scene> BuildSceneFromAdm(const adm::Model& model);

}  // namespace adm2iamf

#endif  // ADM2IAMF_SCENE_ADM_ADAPTER_H_
