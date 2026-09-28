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

import '../colormap.dart';
import '../sh_decode_helper.dart';
import '../sh_utils.dart' show ShDirectivity;
import '../viz_layer.dart';
import '../viz_module.dart';

/// Ambisonic soundfield visualized as a tessellated sphere whose face
/// colors encode the SH-decoded energy landing in each direction.
///
/// Replaces the legacy auto-built RenderableSoundfield path. All tuning
/// happens through this module's parameters.
class SoundfieldSphereModule extends SceneVizModule {
  @override
  String get id => 'soundfield_sphere';

  @override
  String get displayName => 'Soundfield sphere';

  @override
  String get description =>
      'Icosahedron mesh colored by SH-decoded energy per direction.';

  @override
  bool get enabledByDefault => false;

  static const _pSubdivisions = VizParam(
    id: 'subdivisions',
    label: 'Tessellation',
    min: 2,
    max: 4,
    defaultValue: 4,
  );
  static const _pFloorDb = VizParam(
    id: 'floor_db',
    label: 'Noise floor',
    min: -80,
    max: -20,
    defaultValue: -48,
    unit: 'dB',
  );
  static const _pAlphaGain = VizParam(
    id: 'alpha',
    label: 'Opacity',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.5,
  );
  static const _pRadius = VizParam(
    id: 'radius',
    label: 'Radius',
    min: 0.3,
    max: 1.4,
    defaultValue: 0.8,
  );

  // Reused per-face color buffer (energy_shell pattern): resized only
  // when the tessellation changes, mutated in place every frame so the
  // 60 Hz build path stays allocation-free. The renderer consumes it
  // before the next build on the single UI isolate.
  List<Color> _faceColors = const [];

  /// Directivity stored as a discrete index 0..2 → basic / maxRe / inPhase.
  static const _pDirectivity = VizParam(
    id: 'directivity',
    label: 'Directivity (0=basic 1=maxRe 2=inPhase)',
    min: 0,
    max: 2,
    defaultValue: 2,
  );

  @override
  List<VizParam> get params => const [
    _pSubdivisions,
    _pFloorDb,
    _pAlphaGain,
    _pRadius,
    _pDirectivity,
  ];

  @override
  List<VizLayer> build(SceneVizInput input, VizParamValues p) {
    if (input.engine == null) return const [];
    if (input.combinedCoeffs.isEmpty) return const [];

    final subs = p.get(_pSubdivisions.id).round().clamp(2, 4);
    final floorDb = p.get(_pFloorDb.id);
    final alphaGain = p.get(_pAlphaGain.id).clamp(0.0, 1.0);
    final radius = p.get(_pRadius.id);
    final dirIdx = p.get(_pDirectivity.id).round().clamp(0, 2);
    final directivity = switch (dirIdx) {
      0 => ShDirectivity.basic,
      1 => ShDirectivity.maxRe,
      _ => ShDirectivity.inPhase,
    };

    final result = ShDecodeHelper.decode(
      engine: input.engine!,
      coeffs: input.combinedCoeffs,
      order: input.combinedOrder,
      subdivisions: subs,
      directivity: directivity,
    );

    final lut = Colormap.audioMeter.lut;
    final invFloor = 1.0 / -floorDb;
    const ln10inv = 10.0 / math.ln10;

    if (_faceColors.length != result.mesh.faceCount) {
      _faceColors = List<Color>.filled(
        result.mesh.faceCount,
        const Color(0xFF000000),
      );
    }
    final faceColors = _faceColors;
    for (var i = 0; i < result.mesh.faceCount; i++) {
      final e = result.energies[i];
      if (e <= 0 || !e.isFinite) {
        faceColors[i] = const Color(0xFF000000);
        continue;
      }
      final db = (ln10inv * math.log(e)).clamp(floorDb, 0.0);
      if (db <= floorDb) {
        faceColors[i] = const Color(0xFF000000);
        continue;
      }
      final t = ((db - floorDb) * invFloor).clamp(0.0, 1.0);
      faceColors[i] = Color(lut[(t * 255).round().clamp(0, 255)]);
    }

    // Accumulate average normalised energy for a slight alpha floor
    // boost when the soundfield is active.
    var sumNorm = 0.0;
    for (final e in result.energies) {
      if (e <= 0 || !e.isFinite) continue;
      final db = (ln10inv * math.log(e)).clamp(floorDb, 0.0);
      sumNorm += ((db - floorDb) * invFloor).clamp(0.0, 1.0);
    }
    final avgNorm = sumNorm / math.max(result.energies.length, 1);
    final alpha = (alphaGain * (0.25 + 0.75 * avgNorm)).clamp(0.0, 1.0);

    return [
      SoundfieldSphereLayer(
        id: id,
        vertices: result.mesh.vertices,
        faces: result.mesh.faces,
        faceColors: faceColors,
        radius: radius,
        alpha: alpha,
      ),
    ];
  }
}
