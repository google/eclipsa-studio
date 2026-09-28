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

/// Mollweide projection overlay.
///
/// The drawing happens in the 2D layer of the renderer view (outside
/// three_js), so this module doesn't emit a 3D VizLayer — it exists
/// to appear in the visualizer panel so its enable flag and
/// directivity setting can be tuned alongside the 3D modules.
/// [renderer_view] reads `vizNotifier.stateFor('mollweide').enabled`
/// and the directivity param directly.
class MollweideOverlayModule extends SceneVizModule {
  static const String kId = 'mollweide';

  @override
  String get id => kId;

  @override
  String get displayName => 'Mollweide overlay';

  @override
  String get description =>
      '2D flat-map projection of the soundfield, pinned to the '
      'bottom-right of the renderer view.';

  @override
  bool get enabledByDefault => false;

  /// Discrete 0..2 → basic / maxRe / inPhase. Mirrored from
  /// [SoundfieldSphereModule] so both paths can share a preset feel.
  static const pDirectivity = VizParam(
    id: 'directivity',
    label: 'Directivity (0=basic 1=maxRe 2=inPhase)',
    min: 0,
    max: 2,
    defaultValue: 2,
  );

  @override
  List<VizParam> get params => const [pDirectivity];

  @override
  List<VizLayer> build(SceneVizInput input, VizParamValues p) {
    // No 3D geometry — the Mollweide is a 2D overlay drawn by the
    // renderer view directly. The panel's enable/param state is the
    // entire output.
    return const [];
  }
}
