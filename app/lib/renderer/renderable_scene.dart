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

import 'dart:ui' show Color;
import 'package:vector_math/vector_math.dart';

import 'viz_layer.dart';

export 'viz_layer.dart';

/// Renderer-agnostic scene description.
///
/// Everything a renderer needs to draw one frame. No library-specific types.
/// Built by [SceneState.toRenderable()] each frame.
class RenderableScene {
  final double cameraAzRad;
  final double cameraElRad;
  final double cameraDistance;

  final List<RenderableObject> objects;
  final List<RenderableSpeaker> speakers;

  /// SH coefficients from the scene encoder (for Mollweide overlay).
  final List<double>? shCoeffs;

  /// Ambisonic order used for encoding.
  final int shOrder;

  final bool showAxes;

  /// Viz layers emitted by enabled [VizModule]s (channel + scene).
  /// Unknown layer types are ignored by the renderer, so new modules
  /// plug in without renderer changes.
  final List<VizLayer> layers;

  const RenderableScene({
    this.cameraAzRad = 0,
    this.cameraElRad = 0.4,
    this.cameraDistance = 4.0,
    this.objects = const [],
    this.speakers = const [],
    this.shCoeffs,
    this.shOrder = 3,
    this.showAxes = true,
    this.layers = const [],
  });
}

/// A spatial audio object (mono or stereo pair).
class RenderableObject {
  /// Stable identifier for mesh reuse across frame updates.
  final int id;

  /// Position in visualizer coordinates.
  final Vector3 position;

  /// Base radius (Phase A: 0.08 fixed; Phase B: modulated by amplitude).
  final double radius;

  /// Color (Phase A: fixed per type; Phase B: from level).
  final Color color;

  /// Right channel position for stereo pairs, or null for mono.
  final Vector3? positionR;

  /// Arc points connecting stereo pair, or null for mono.
  final List<Vector3>? arcPoints;

  const RenderableObject({
    required this.id,
    required this.position,
    this.radius = 0.08,
    required this.color,
    this.positionR,
    this.arcPoints,
  });
}

/// A loudspeaker in the scene.
class RenderableSpeaker {
  final Vector3 position;
  final Vector3 lookAtOrigin;
  final Color color;
  final String label;
  final double width;
  final double height;
  final double depth;

  /// Output channel level (linear 0..1+) for level-driven coloring.
  final double level;

  const RenderableSpeaker({
    required this.position,
    required this.lookAtOrigin,
    required this.color,
    required this.label,
    this.width = 0.08,
    this.height = 0.12,
    this.depth = 0.06,
    this.level = 0.0,
  });
}
