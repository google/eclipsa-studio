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

/// Renderer-agnostic output of a [ChannelVizModule]. Each concrete
/// subclass describes one kind of overlay; [three_js_renderer] pattern-
/// matches on the runtime type to decide how to draw it.
///
/// Modules emit zero or more layers per frame; the renderer is free to
/// ignore layer types it doesn't know how to draw — which is how new
/// visualizations can be prototyped without touching the renderer.
sealed class VizLayer {
  /// Stable id used by the renderer to reuse meshes across frames.
  final String id;

  const VizLayer(this.id);
}

/// Deformable sphere shaded by a radial energy field.
///
/// Vertices are displaced outward along their normal by [displacement]
/// (same length as [vertices]). Per-vertex colors follow [vertexColors].
/// Faces are triangle indices into [vertices].
class EnergyShellLayer extends VizLayer {
  final List<Vector3> vertices;
  final List<(int, int, int)> faces;
  final List<double> displacement;
  final List<Color> vertexColors;
  final double baseRadius;
  final double alpha;

  const EnergyShellLayer({
    required String id,
    required this.vertices,
    required this.faces,
    required this.displacement,
    required this.vertexColors,
    required this.baseRadius,
    required this.alpha,
  }) : super(id);
}

/// Inter-channel correlation ribbons — one bezier per speaker pair
/// that exceeds a min-correlation threshold.
class CorrelationRibbonLayer extends VizLayer {
  final List<CorrelationRibbon> ribbons;

  /// Scales how far the ribbon bends away from the straight line.
  /// 0 = straight chord, 1 ≈ arc passing through (or opposite) the origin.
  final double curvature;

  /// Number of samples along the bezier — renderer-side detail control.
  final int segments;

  const CorrelationRibbonLayer({
    required String id,
    required this.ribbons,
    this.curvature = 0.6,
    this.segments = 20,
  }) : super(id);
}

class CorrelationRibbon {
  final Vector3 a;
  final Vector3 b;
  final double thickness;
  final double curvatureSign; // +1 bows through origin, -1 bows outward
  final Color color;
  final double alpha;

  const CorrelationRibbon({
    required this.a,
    required this.b,
    required this.thickness,
    required this.curvatureSign,
    required this.color,
    required this.alpha,
  });
}

/// Expanding translucent spherical shells emitted on transient onsets.
class WavefrontLayer extends VizLayer {
  final List<Wavefront> pulses;

  const WavefrontLayer({required String id, required this.pulses}) : super(id);
}

class Wavefront {
  final Vector3 origin;
  final double radius;
  final double thickness;
  final Color color;
  final double alpha;

  const Wavefront({
    required this.origin,
    required this.radius,
    required this.thickness,
    required this.color,
    required this.alpha,
  });
}

/// Ambisonic soundfield sphere — tessellated mesh with per-face
/// SH-decoded colors. The module emits this layer; the renderer
/// binds it into the existing icosahedron dispatch.
class SoundfieldSphereLayer extends VizLayer {
  final List<Vector3> vertices;
  final List<(int, int, int)> faces;
  final List<Color> faceColors;
  final double radius;
  final double alpha;
  final bool showWireframe;

  const SoundfieldSphereLayer({
    required String id,
    required this.vertices,
    required this.faces,
    required this.faceColors,
    required this.radius,
    required this.alpha,
    this.showWireframe = true,
  }) : super(id);
}

/// Active-intensity vector — one 3D arrow per scene element rooted at
/// the origin, pointing toward the dominant incoming direction.
class IntensityVectorLayer extends VizLayer {
  final List<IntensityArrow> arrows;

  const IntensityVectorLayer({required String id, required this.arrows})
    : super(id);
}

class IntensityArrow {
  /// Tail position (usually origin).
  final Vector3 origin;

  /// Tip of the arrow (origin + direction * length).
  final Vector3 tip;

  /// Shaft thickness.
  final double thickness;

  final Color color;
  final double alpha;

  const IntensityArrow({
    required this.origin,
    required this.tip,
    required this.thickness,
    required this.color,
    required this.alpha,
  });
}

/// Ambient-particle cloud — 3000-point dipole-strain sphere that
/// reacts to speaker levels. Kept in the renderer as a built-in
/// effect; this layer just carries the tuning values the module
/// wants applied this frame.
class AmbientParticlesLayer extends VizLayer {
  /// Scales total displacement amplitude. 1.0 matches the legacy look.
  final double intensity;

  /// Clamp on visible-particle ratio (0..1). The renderer caps it
  /// against its internal [_maxParticles] constant.
  final double visibleRatio;

  /// Point size in world units (passed to PointsMaterial.size).
  final double pointSize;

  /// Base opacity of the particle material.
  final double opacity;

  const AmbientParticlesLayer({
    required String id,
    this.intensity = 1.0,
    this.visibleRatio = 1.0,
    this.pointSize = 0.05,
    this.opacity = 0.85,
  }) : super(id);
}
