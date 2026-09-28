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

/// Capability flags declared by each renderer backend.
class RendererCapabilities {
  final String name;
  final String description;
  final bool supportsVertexColors;
  final bool supportsWireframe;
  final bool supportsTransparency;
  final bool supportsOrbitCamera;
  final bool supportsDynamicMeshUpdate;
  final bool requiresImpeller;
  final bool requiresWebView;

  const RendererCapabilities({
    required this.name,
    required this.description,
    this.supportsVertexColors = false,
    this.supportsWireframe = false,
    this.supportsTransparency = false,
    this.supportsOrbitCamera = false,
    this.supportsDynamicMeshUpdate = false,
    this.requiresImpeller = false,
    this.requiresWebView = false,
  });
}
