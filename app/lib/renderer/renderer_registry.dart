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

import 'scene_renderer.dart';

/// Factory registry for runtime renderer switching.
///
/// Each renderer self-registers on import. The demo app can then list
/// available renderers and instantiate them by ID.
class RendererRegistry {
  static final Map<String, SceneRenderer Function()> _factories = {};

  RendererRegistry._();

  /// Register a renderer factory. Call from renderer's static initializer.
  static void register(String id, SceneRenderer Function() factory) {
    _factories[id] = factory;
  }

  /// List of registered renderer IDs.
  static List<String> get availableRenderers =>
      List.unmodifiable(_factories.keys);

  /// Create a renderer by ID. Throws if not registered.
  static SceneRenderer create(String id) {
    final factory = _factories[id];
    if (factory == null) {
      throw ArgumentError(
        'No renderer registered with id "$id". '
        'Available: ${_factories.keys.join(', ')}',
      );
    }
    return factory();
  }

  /// Check if a renderer is registered.
  static bool has(String id) => _factories.containsKey(id);
}
