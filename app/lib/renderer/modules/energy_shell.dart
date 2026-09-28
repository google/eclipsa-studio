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

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:vector_math/vector_math.dart';

import '../../theme.dart';
import '../colormap.dart';
import '../coordinate_utils.dart';
import '../icosahedron.dart';
import '../viz_layer.dart';
import '../viz_module.dart';

/// Deforms a tessellated sphere radially by the per-direction energy
/// field reconstructed from channel-based elements.
///
/// For each icosahedron vertex direction `v`, the displacement is the
/// energy that *would* land at `v` under a simple cosine-panning model:
///
///     E(v) = Σ_i Σ_c max(cos θ_ic, 0)^p · energy_ic
///
/// where θ_ic is the angle between `v` and the speaker direction for
/// (element i, channel c). This is a cheap proxy for VBAP/ambisonic
/// energy without actually running the renderer — good enough to feel
/// "physical" and cheap enough to run every frame.
class EnergyShellModule extends ChannelVizModule {
  @override
  String get id => 'energy_shell';

  @override
  String get displayName => 'Energy shell';

  @override
  String get description =>
      'Deformed sphere that bulges toward where the audio is. '
      'Replaces the ambient particle cloud.';

  @override
  bool get enabledByDefault => false;

  // ── Params ──────────────────────────────────────────────────────────
  static const _pGain = VizParam(
    id: 'gain',
    label: 'Displacement gain',
    min: 0.0,
    max: 2.0,
    defaultValue: 0.9,
  );
  static const _pExponent = VizParam(
    id: 'exponent',
    label: 'Directivity',
    min: 1.0,
    max: 16.0,
    defaultValue: 4.0,
    unit: '',
  );
  static const _pBaseRadius = VizParam(
    id: 'base_radius',
    label: 'Base radius',
    min: 0.3,
    max: 1.4,
    defaultValue: 0.85,
  );
  static const _pAlpha = VizParam(
    id: 'alpha',
    label: 'Opacity',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.35,
  );
  static const _pFloorDb = VizParam(
    id: 'floor_db',
    label: 'Noise floor',
    min: -80.0,
    max: -20.0,
    defaultValue: -48.0,
    unit: 'dB',
  );
  static const _pSubdivisions = VizParam(
    id: 'subdivisions',
    label: 'Tessellation',
    min: 2,
    max: 4,
    defaultValue: 3,
  );

  @override
  List<VizParam> get params => const [
    _pGain,
    _pExponent,
    _pBaseRadius,
    _pAlpha,
    _pFloorDb,
    _pSubdivisions,
  ];

  // Mesh cache keyed by subdivision level. Building the icosahedron
  // costs a few ms at level 4, so never rebuild on a hot path.
  final Map<int, Icosahedron> _meshCache = {};

  // Per-vertex instance buffers. All three are resized only when the
  // tessellation changes and reused in place on every frame, so the
  // build path is allocation-free after the first call.
  List<double> _prevDisp = const [];
  List<double> _disp = const [];
  List<Color> _colors = const [];

  // Channel-source scratch. Upper-bounded by
  // kEclipsaStudioMaxElements * kEclipsaStudioMaxChannelsPerElement = 784, but
  // realistically we see a few dozen. Grown with length assignments
  // rather than add() so the underlying storage is reused across frames.
  final List<Vector3> _dirs = <Vector3>[];
  final List<double> _weights = <double>[];

  Icosahedron _mesh(int subs) => _meshCache.putIfAbsent(
    subs,
    () => Icosahedron.generate(subdivisions: subs),
  );

  @override
  List<VizLayer> build(ChannelVizInput input, VizParamValues p) {
    if (input.elements.isEmpty) return const [];

    final subs = p.get(_pSubdivisions.id).round().clamp(2, 4);
    final gain = p.get(_pGain.id);
    final exponent = p.get(_pExponent.id);
    final baseRadius = p.get(_pBaseRadius.id);
    final alpha = p.get(_pAlpha.id).clamp(0.0, 1.0);
    final floorDb = p.get(_pFloorDb.id);

    final mesh = _mesh(subs);
    final nVerts = mesh.vertices.length;

    // Gather (direction, weight) pairs for every active channel across
    // all channel-based elements. Reuses instance buffers — the lists
    // grow to the high-water mark then stay there across frames.
    var srcN = 0;
    for (final e in input.elements) {
      final stats = e.stats;
      final useStats = !stats.isEmpty;
      final chN = math.min(
        e.layout.speakers.length,
        useStats ? stats.channelCount : e.peaks.length,
      );
      for (var c = 0; c < chN; c++) {
        final spk = e.layout.speakers[c];
        // LFE is omnidirectional-ish — skip its directional contribution
        // so a big kick doesn't pretend to be front-center.
        if (spk.isLFE) continue;
        final w = useStats ? stats.energy[c] : _peakToPower(e.peaks[c]);
        if (w <= 0) continue;
        final dir = CoordinateUtils.sphericalToVisualizer(
          spk.azDeg,
          spk.elDeg,
          1.0,
        );
        dir.normalize();
        if (srcN < _dirs.length) {
          _dirs[srcN] = dir;
          _weights[srcN] = w;
        } else {
          _dirs.add(dir);
          _weights.add(w);
        }
        srcN++;
      }
    }

    // Resize instance buffers when subdivision changes. Otherwise zero
    // the reused displacement buffer in place so the next frame starts
    // fresh. Color and prevDisp are unconditionally overwritten below.
    if (_prevDisp.length != nVerts) {
      _prevDisp = List<double>.filled(nVerts, 0.0);
      _disp = List<double>.filled(nVerts, 0.0);
      _colors = List<Color>.filled(nVerts, T.bgBase);
    }
    final disp = _disp;
    final colors = _colors;
    final lut = Colormap.audioMeter.lut;

    // Reusable normalization: convert energy to 0..1 via dB mapping
    // with a user-adjustable floor. Same convention as the soundfield
    // painter so the two feel consistent.
    final invFloor = 1.0 / -floorDb;
    const ln10inv = 10.0 / math.ln10;

    for (var v = 0; v < nVerts; v++) {
      final dv = mesh.vertices[v]; // already unit-length
      var sum = 0.0;
      for (var k = 0; k < srcN; k++) {
        final d = _dirs[k].dot(dv);
        if (d <= 0) continue;
        sum += math.pow(d, exponent).toDouble() * _weights[k];
      }

      // Convert raw power to a 0..1 visual amount via a floor-based
      // dB mapping, then EMA-smooth toward it for stability.
      var t = 0.0;
      if (sum > 0) {
        final db = (ln10inv * math.log(sum)).clamp(floorDb, 0.0);
        t = ((db - floorDb) * invFloor).clamp(0.0, 1.0);
      }
      final smoothed = 0.35 * t + 0.65 * _prevDisp[v];
      _prevDisp[v] = smoothed;

      disp[v] = smoothed * gain;
      final lutIdx = (smoothed * 255).round().clamp(0, 255);
      colors[v] = Color(lut[lutIdx]);
    }

    return [
      EnergyShellLayer(
        id: id,
        vertices: mesh.vertices,
        faces: mesh.faces,
        displacement: disp,
        vertexColors: colors,
        baseRadius: baseRadius,
        alpha: alpha,
      ),
    ];
  }

  @override
  void reset() {
    for (var i = 0; i < _prevDisp.length; i++) {
      _prevDisp[i] = 0.0;
    }
  }

  /// Convert a linear peak amplitude to an energy-like scalar. Used as
  /// a fallback when stats aren't yet available (e.g. first few frames).
  double _peakToPower(double peak) => peak * peak;
}
