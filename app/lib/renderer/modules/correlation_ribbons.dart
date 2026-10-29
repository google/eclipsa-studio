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

import 'package:vector_math/vector_math.dart';

import '../../ffi_bridge.dart' show kStatsCorrMaxChannels;
import '../../theme.dart';
import '../coordinate_utils.dart';
import '../viz_layer.dart';
import '../viz_module.dart';

/// Inter-channel correlation ribbons.
///
/// For each channel-based element, draws a ribbon for every speaker
/// pair (i, j) whose correlation magnitude exceeds [_pMinCorr] and
/// whose shared energy exceeds [_pMinEnergy]. Ribbons are bezier arcs
/// between the two speaker positions, bulging *through* the origin
/// when ρ > 0 (phantom source) and *away* from the origin when ρ < 0
/// (anti-phantom — out-of-phase pair).
///
/// Thickness tracks min(E_i, E_j) in the dB-normalised space so only
/// shared content shows up; opacity tracks |ρ|² so the weakest
/// correlations fade out rather than vanishing at the threshold.
class CorrelationRibbonsModule extends ChannelVizModule {
  @override
  String get id => 'corr_ribbons';

  @override
  String get displayName => 'Correlation ribbons';

  @override
  String get description =>
      'Arcs between speaker pairs: thick for shared energy, '
      'bright for strong correlation, curved through origin when '
      'in phase.';

  @override
  bool get enabledByDefault => false;

  static const _pMinCorr = VizParam(
    id: 'min_corr',
    label: 'Min |ρ|',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.15,
  );
  static const _pMinEnergyDb = VizParam(
    id: 'min_energy_db',
    label: 'Min pair energy',
    min: -80.0,
    max: -20.0,
    defaultValue: -42.0,
    unit: 'dB',
  );
  static const _pThickness = VizParam(
    id: 'thickness',
    label: 'Thickness',
    min: 0.002,
    max: 0.04,
    defaultValue: 0.012,
  );
  static const _pAlphaGain = VizParam(
    id: 'alpha',
    label: 'Opacity',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.6,
  );
  static const _pCurvature = VizParam(
    id: 'curvature',
    label: 'Curvature',
    min: 0.0,
    max: 1.2,
    defaultValue: 0.6,
  );

  @override
  List<VizParam> get params => const [
    _pMinCorr,
    _pMinEnergyDb,
    _pThickness,
    _pAlphaGain,
    _pCurvature,
  ];

  // Per-element scratch, sized once to the correlation channel cap and
  // reused across elements and frames (energy_shell pattern) so the
  // 60 Hz build path allocates only the ribbons it actually emits.
  final List<Vector3?> _positions = List<Vector3?>.filled(
    kStatsCorrMaxChannels,
    null,
  );
  final List<double> _energies = List<double>.filled(
    kStatsCorrMaxChannels,
    0.0,
  );

  @override
  List<VizLayer> build(ChannelVizInput input, VizParamValues p) {
    if (input.elements.isEmpty) return const [];

    final minCorr = p.get(_pMinCorr.id);
    final minEnergy = _dbToLin(p.get(_pMinEnergyDb.id));
    final thick = p.get(_pThickness.id);
    final alphaGain = p.get(_pAlphaGain.id);
    final curvature = p.get(_pCurvature.id);

    final ribbons = <CorrelationRibbon>[];

    for (final e in input.elements) {
      final stats = e.stats;
      if (stats.isEmpty) continue;
      final n = math.min(stats.channelCount, kStatsCorrMaxChannels);
      if (n < 2) continue;

      final color = aeTypeColor(e.element.type);

      // Precompute speaker positions so we don't recompute per pair.
      // Clear the reused scratch for this element's channel range.
      final positions = _positions;
      final energies = _energies;
      for (var c = 0; c < n; c++) {
        positions[c] = null;
        energies[c] = 0.0;
      }
      for (var c = 0; c < n && c < e.layout.speakers.length; c++) {
        final spk = e.layout.speakers[c];
        if (spk.isLFE) continue;
        positions[c] = CoordinateUtils.sphericalToVisualizer(
          spk.azDeg,
          spk.elDeg,
          1.0,
        );
        energies[c] = stats.energy[c];
      }

      for (var i = 0; i < n; i++) {
        final a = positions[i];
        if (a == null) continue;
        for (var j = i + 1; j < n; j++) {
          final b = positions[j];
          if (b == null) continue;
          final rho = stats.correlation(i, j);
          if (rho.abs() < minCorr) continue;
          final sharedE = math.min(energies[i], energies[j]);
          if (sharedE < minEnergy) continue;

          // Thickness — min(Ei, Ej) mapped through a square-root so
          // quieter content still reads while loud peaks don't dominate.
          final tScale = math.sqrt(
            (sharedE / (minEnergy * 50)).clamp(0.0, 1.0).toDouble(),
          );
          final thickness = thick * (0.5 + tScale);

          // Opacity follows |ρ|² so weak correlations fade out smoothly.
          final alpha = (alphaGain * rho * rho).clamp(0.0, 1.0);

          ribbons.add(
            CorrelationRibbon(
              a: a,
              b: b,
              thickness: thickness,
              curvatureSign: rho >= 0 ? 1.0 : -1.0,
              color: color,
              alpha: alpha,
            ),
          );
        }
      }
    }

    if (ribbons.isEmpty) return const [];
    return [
      CorrelationRibbonLayer(id: id, ribbons: ribbons, curvature: curvature),
    ];
  }
}

double _dbToLin(double db) => math.pow(10.0, db / 10.0).toDouble();
