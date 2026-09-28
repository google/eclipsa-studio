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

import '../coordinate_utils.dart';
import '../viz_layer.dart';
import '../viz_module.dart';

/// 3D arrow showing the active intensity vector — the dominant
/// direction energy is arriving from in an ambisonic field.
///
/// For each scene element, reads first-order SH coefficients from the
/// engine's snapshot (already in cross-product form: `E[W·ch_c]`).
/// ACN/SN3D convention puts:
///
///   sh[1] ∝ E[W·Y]  → ADM +X (left)
///   sh[2] ∝ E[W·Z]  → ADM +Y (up)
///   sh[3] ∝ E[W·X]  → ADM +Z (front)
///
/// Vector length maps to localization: |I|/E where E = sh[0].
/// A point source gives |I|/E → 1; a diffuse field → 0.
class IntensityVectorModule extends SceneVizModule {
  @override
  String get id => 'intensity_vector';

  @override
  String get displayName => 'Intensity vector';

  @override
  String get description =>
      'Arrow pointing to the dominant direction of incoming energy. '
      'Length encodes how focused the sound is.';

  @override
  bool get enabledByDefault => false;

  static const _pGain = VizParam(
    id: 'gain',
    label: 'Length gain',
    min: 0.2,
    max: 3.0,
    defaultValue: 1.5,
  );
  static const _pMinMag = VizParam(
    id: 'min_mag',
    label: 'Min localization',
    min: 0.0,
    max: 0.9,
    defaultValue: 0.05,
  );
  static const _pThickness = VizParam(
    id: 'thickness',
    label: 'Thickness',
    min: 0.004,
    max: 0.05,
    defaultValue: 0.016,
  );
  static const _pAlpha = VizParam(
    id: 'alpha',
    label: 'Opacity',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.95,
  );
  static const _pFloorDb = VizParam(
    id: 'floor_db',
    label: 'Energy floor',
    min: -80,
    max: -20,
    defaultValue: -50,
    unit: 'dB',
  );

  @override
  List<VizParam> get params => const [
    _pGain,
    _pMinMag,
    _pThickness,
    _pAlpha,
    _pFloorDb,
  ];

  @override
  List<VizLayer> build(SceneVizInput input, VizParamValues p) {
    if (input.elements.isEmpty) return const [];

    final gain = p.get(_pGain.id);
    final minMag = p.get(_pMinMag.id);
    final thickness = p.get(_pThickness.id);
    final alphaGain = p.get(_pAlpha.id).clamp(0.0, 1.0);
    final floorLin = math.pow(10.0, p.get(_pFloorDb.id) / 10.0).toDouble();

    final arrows = <IntensityArrow>[];
    for (final e in input.elements) {
      final sh = e.shSnapshots;
      if (sh.length < 4) continue;
      final energy = sh[0];
      if (energy <= floorLin) continue;

      // First-order → ADM Cartesian.
      final adm = Vector3(sh[1], sh[2], sh[3]);
      final mag = adm.length;
      if (mag <= 0) continue;
      final localization = (mag / energy).clamp(0.0, 1.0);
      if (localization < minMag) continue;

      // Direction (unit) in ADM → visualizer.
      final unitAdm = adm.scaled(1 / mag);
      final dirViz = CoordinateUtils.audioToVisualizer(unitAdm);

      // Tip length scales with localization (0..1) and the gain knob,
      // so focused sources punch out while diffuse fields stay short.
      final tipLen = (0.4 + 0.8 * localization) * gain;

      arrows.add(
        IntensityArrow(
          origin: Vector3.zero(),
          tip: dirViz..scale(tipLen),
          thickness: thickness,
          color: Color(e.element.color),
          alpha: alphaGain,
        ),
      );
    }

    if (arrows.isEmpty) return const [];
    return [IntensityVectorLayer(id: id, arrows: arrows)];
  }
}
