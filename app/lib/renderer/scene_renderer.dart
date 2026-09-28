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

import 'package:flutter/widgets.dart';

import 'renderable_scene.dart';
import 'renderer_capabilities.dart';

/// Abstract 3D renderer — each library implements this.
///
/// Renderers are thin adapters that translate [RenderableScene] into
/// library-specific draw calls. Adding a new renderer means implementing
/// this class and registering it via [RendererRegistry].
abstract class SceneRenderer {
  /// Declares what this renderer supports.
  RendererCapabilities get capabilities;

  /// Build the renderer widget. Called once, lives in the widget tree.
  Widget buildWidget({Key? key});

  /// Push new scene data. Called every frame (60fps).
  void updateScene(RenderableScene scene);

  /// Set camera position (if not handled by built-in orbit controls).
  void setCamera(double azRad, double elRad, double distance);

  /// Clean up resources.
  void dispose();
}
