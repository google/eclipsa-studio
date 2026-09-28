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

import '../ffi_bridge.dart' show EclipsaStudioEngine;
import '../state.dart' show AudioElement;
import 'element_stats.dart';
import 'speaker_layout.dart';
import 'viz_layer.dart';

/// Which class of content a module consumes.
///
/// `channel` — modules that read channel-based element stats + speaker
/// layouts (energy, correlation, onsets, etc.).
///
/// `scene` — modules that read ambisonic element SH coefficients and
/// ambisonic order. Object-based elements get a future domain when
/// needed.
enum VizDomain { channel, scene }

/// Base module type — shared metadata / registry interface. Concrete
/// modules extend either [ChannelVizModule] or [SceneVizModule] for
/// the domain-specific build signature.
abstract class VizModule {
  /// Stable id used for persistence / registry lookup.
  String get id;

  /// Human-readable label shown in the visualizer panel.
  String get displayName;

  /// One-line description shown under the module toggle.
  String get description;

  /// Exposed tuning knobs — the panel auto-builds sliders for these.
  List<VizParam> get params;

  /// Is this module enabled by default when the user hasn't touched it?
  bool get enabledByDefault => false;

  /// Which content type this module reads.
  VizDomain get domain;

  /// Called when the user disables the module. Release any retained
  /// state here (e.g. wavefront pulse lists) so the next enable
  /// doesn't pop back to the previous view.
  void reset() {}
}

/// One tunable knob on a module.
class VizParam {
  final String id;
  final String label;
  final double min;
  final double max;
  final double defaultValue;
  final String unit;

  /// When true, slider interpolates in log space — pass the log base
  /// (e.g. 10) if you want log scaling, leave null for linear.
  final double? logBase;

  const VizParam({
    required this.id,
    required this.label,
    required this.min,
    required this.max,
    required this.defaultValue,
    this.unit = '',
    this.logBase,
  });
}

/// Resolved parameter values for one module, keyed by [VizParam.id].
/// Missing keys fall back to [VizParam.defaultValue].
class VizParamValues {
  final Map<String, double> _values;
  final List<VizParam> _params;

  const VizParamValues(this._values, this._params);

  /// Read a param by id. Returns the module's declared default when the
  /// key is missing from persisted state — so modules can rely on this
  /// call never returning null.
  double get(String id) {
    final v = _values[id];
    if (v != null) return v;
    for (final p in _params) {
      if (p.id == id) return p.defaultValue;
    }
    return 0.0;
  }
}

// ── Channel-based modules ───────────────────────────────────────────

/// Immutable snapshot of one channel-based element's state at frame N.
class ChannelVizElement {
  final AudioElement element;
  final SpeakerLayout layout;

  /// Post-DSP per-channel peak (linear 0..1+). Same data the meters use.
  final List<double> peaks;

  /// Stats block from the engine (see [ElementStats]).
  final ElementStats stats;

  const ChannelVizElement({
    required this.element,
    required this.layout,
    required this.peaks,
    required this.stats,
  });
}

/// Per-frame input for channel modules.
class ChannelVizInput {
  final List<ChannelVizElement> elements;
  final double timeSec;
  final double dtSec;

  const ChannelVizInput({
    required this.elements,
    required this.timeSec,
    required this.dtSec,
  });
}

/// A pluggable channel-viz module. Given a frame input and its current
/// parameter values, produces zero or more [VizLayer]s.
abstract class ChannelVizModule extends VizModule {
  @override
  VizDomain get domain => VizDomain.channel;

  /// Build layers for the current frame.
  List<VizLayer> build(ChannelVizInput input, VizParamValues p);
}

// ── Scene-based (ambisonic) modules ─────────────────────────────────

/// Immutable snapshot of one ambisonic element at frame N.
class SceneVizElement {
  final AudioElement element;

  /// Ambisonic order for this element (1 = FOA, 3 = TOA).
  final int order;

  /// Per-channel SH-domain active intensity snapshot, in ACN order.
  /// ch[0] = E[W²] (total energy); ch[c>0] = E[W·ch_c] (signed
  /// correlation with W — first-order components map to intensity
  /// vector axes in ADM Cartesian).
  final List<double> shSnapshots;

  const SceneVizElement({
    required this.element,
    required this.order,
    required this.shSnapshots,
  });
}

/// Per-frame input for scene modules.
class SceneVizInput {
  final List<SceneVizElement> elements;

  /// Summed ACN-order SH coefficients across all scene elements
  /// (convenience — modules that want the combined soundfield don't
  /// need to re-sum). Length = kCoeffCount(maxOrder).
  final List<double> combinedCoeffs;

  /// Max ambisonic order represented in [combinedCoeffs].
  final int combinedOrder;

  /// Native engine handle. Scene modules that need to run the SH
  /// decoder (soundfield sphere) read this; modules that only touch
  /// coefficients directly (intensity vector, order energy) ignore it.
  final EclipsaStudioEngine? engine;

  final double timeSec;
  final double dtSec;

  const SceneVizInput({
    required this.elements,
    required this.combinedCoeffs,
    required this.combinedOrder,
    required this.engine,
    required this.timeSec,
    required this.dtSec,
  });
}

/// A pluggable scene-viz module.
abstract class SceneVizModule extends VizModule {
  @override
  VizDomain get domain => VizDomain.scene;

  /// Build layers for the current frame.
  List<VizLayer> build(SceneVizInput input, VizParamValues p);
}

// ── Registry ────────────────────────────────────────────────────────

/// Unified module registry. Adding a new module is
/// "write one file + append to this list."
class VizRegistry {
  VizRegistry._();

  static final List<VizModule> _modules = <VizModule>[];

  /// All registered modules, in registration order.
  static List<VizModule> get modules => List.unmodifiable(_modules);

  /// Filter to just the modules of a given domain.
  static List<VizModule> ofDomain(VizDomain d) =>
      _modules.where((m) => m.domain == d).toList(growable: false);

  /// Register a module. Must be called before the scene bridge builds
  /// its first frame — typically from `main()`. Duplicate ids replace
  /// the prior entry.
  static void register(VizModule module) {
    _modules.removeWhere((m) => m.id == module.id);
    _modules.add(module);
  }

  /// Look up by id. Returns null if not registered.
  static VizModule? find(String id) {
    for (final m in _modules) {
      if (m.id == id) return m;
    }
    return null;
  }
}
