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

import '../viz_layer.dart';
import '../viz_module.dart';

/// Legacy ambient particle cloud, packaged as a first-class module.
///
/// The dipole-strain dynamics live in the three_js renderer (they
/// depend on the scene's speaker positions and levels, not just this
/// module's output). This module simply emits a layer that turns the
/// renderer's particles on and carries tuning knobs.
class AmbientParticlesModule extends ChannelVizModule {
  @override
  String get id => 'ambient_particles';

  @override
  String get displayName => 'Ambient particles';

  @override
  String get description =>
      'Elastic particle cloud that stretches toward loud speakers. '
      'Legacy look, reintroduced as an opt-in layer.';

  @override
  bool get enabledByDefault => false;

  static const _pIntensity = VizParam(
    id: 'intensity',
    label: 'Intensity',
    min: 0.0,
    max: 2.0,
    defaultValue: 1.0,
  );
  static const _pVisibleRatio = VizParam(
    id: 'visible_ratio',
    label: 'Visible ratio',
    min: 0.0,
    max: 1.0,
    defaultValue: 1.0,
  );
  static const _pSize = VizParam(
    id: 'size',
    label: 'Point size',
    min: 0.01,
    max: 0.15,
    defaultValue: 0.05,
  );
  static const _pOpacity = VizParam(
    id: 'opacity',
    label: 'Opacity',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.85,
  );

  @override
  List<VizParam> get params => const [
    _pIntensity,
    _pVisibleRatio,
    _pSize,
    _pOpacity,
  ];

  @override
  List<VizLayer> build(ChannelVizInput input, VizParamValues p) {
    // The particle dynamics read per-speaker levels directly from the
    // scene — we don't need channel-based elements to be present here.
    // Emit the layer unconditionally so the renderer can keep the
    // cloud alive during silence / between elements.
    return [
      AmbientParticlesLayer(
        id: id,
        intensity: p.get(_pIntensity.id),
        visibleRatio: p.get(_pVisibleRatio.id),
        pointSize: p.get(_pSize.id),
        opacity: p.get(_pOpacity.id),
      ),
    ];
  }
}
