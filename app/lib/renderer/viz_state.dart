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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../meters/meter_provider.dart' show eclipsaStudioEngineProvider;
import 'viz_module.dart';

/// Per-module persisted state — enable flag + parameter values.
class VizModuleState {
  final bool enabled;
  final Map<String, double> values;

  const VizModuleState({required this.enabled, required this.values});

  VizModuleState copyWith({bool? enabled, Map<String, double>? values}) =>
      VizModuleState(
        enabled: enabled ?? this.enabled,
        values: values ?? this.values,
      );

  /// Serialize to a JSON-compatible map. Stored inside SessionModel —
  /// viz settings travel with each `.esp` file rather than a global
  /// preference, so switching between projects restores the matching
  /// visualizer setup.
  Map<String, Object> toJson() => {'enabled': enabled, ...values};

  /// Parse a persisted entry. Unknown keys are dropped silently; the
  /// module's declared defaults cover missing params.
  static VizModuleState fromJson(Object? raw, VizModule module) {
    if (raw is! Map) {
      return VizModuleState(enabled: module.enabledByDefault, values: const {});
    }
    // Defensive: a non-bool 'enabled' in a hand-edited or corrupted
    // session must fall back to the default, not TypeError out of the
    // whole session load.
    final enabled = raw['enabled'] is bool
        ? raw['enabled'] as bool
        : module.enabledByDefault;
    final values = <String, double>{};
    for (final p in module.params) {
      final v = raw[p.id];
      if (v is num) values[p.id] = v.toDouble();
    }
    return VizModuleState(enabled: enabled, values: values);
  }
}

/// Keyed by [VizModule.id]. Modules not yet seen are lazily
/// initialised from their declared defaults at read time.
typedef VizState = Map<String, VizModuleState>;

class VizStateNotifier extends Notifier<VizState> {
  bool _lastStatsNeeded = false;
  bool _hudNeedsStats = false;

  @override
  VizState build() {
    // Engine defaults the flag to off. We push the computed aggregate
    // once on next microtask so the engine reflects the declared
    // defaults — defensive against a future module shipping with
    // `enabledByDefault = true` and the audio thread quietly skipping
    // its stats pass until the first UI mutation. Deferred because
    // ref.read on providers that depend on this one inside build() is
    // not reliable.
    _lastStatsNeeded = false;
    final next = _defaultState();
    Future.microtask(_pushStatsFlag);
    return next;
  }

  /// Track HUD visibility separately — the HUD reads the same stats
  /// block, so it also forces the flag on when visible.
  void setHudNeedsStats(bool needed) {
    if (needed == _hudNeedsStats) return;
    _hudNeedsStats = needed;
    _pushStatsFlag();
  }

  /// Recompute the "any channel-viz module enabled OR HUD visible"
  /// gate and push to the audio engine when it flips. Called after
  /// every mutation that can toggle the gate.
  void _pushStatsFlag() {
    var anyChannel = false;
    for (final m in VizRegistry.modules) {
      if (m.domain != VizDomain.channel) continue;
      final s = state[m.id];
      final enabled = s?.enabled ?? m.enabledByDefault;
      if (enabled) {
        anyChannel = true;
        break;
      }
    }
    final needed = anyChannel || _hudNeedsStats;
    if (needed == _lastStatsNeeded) return;
    _lastStatsNeeded = needed;
    ref.read(eclipsaStudioEngineProvider)?.setChannelStatsEnabled(needed);
  }

  /// Build a fresh state map from each registered module's declared
  /// defaults. Used both for the initial build and for [resetToDefaults].
  static VizState _defaultState() {
    final state = <String, VizModuleState>{};
    for (final m in VizRegistry.modules) {
      state[m.id] = VizModuleState(
        enabled: m.enabledByDefault,
        values: const {},
      );
    }
    return state;
  }

  /// Replace the full state with what was saved in a session file.
  /// Missing modules fall back to their declared defaults so older
  /// sessions stay compatible as new modules ship.
  void apply(Map<String, dynamic>? json) {
    final next = <String, VizModuleState>{};
    for (final m in VizRegistry.modules) {
      next[m.id] = VizModuleState.fromJson(json?[m.id], m);
      // Clear any internal module state (pulses, EMA buffers) so the
      // next frame starts clean under the loaded parameter values.
      m.reset();
    }
    // Order matters: _pushStatsFlag reads `state`, so assign first.
    state = next;
    _pushStatsFlag();
  }

  /// Reset every module back to its declared defaults — used when the
  /// user starts a new (untitled) session.
  void resetToDefaults() {
    for (final m in VizRegistry.modules) {
      m.reset();
    }
    state = _defaultState();
    _pushStatsFlag();
  }

  /// Serialize the current state in a form suitable for embedding in
  /// a session file.
  Map<String, Object> snapshot() {
    final out = <String, Object>{};
    state.forEach((k, v) => out[k] = v.toJson());
    return out;
  }

  VizModuleState stateFor(String moduleId) {
    final s = state[moduleId];
    if (s != null) return s;
    final m = VizRegistry.find(moduleId);
    return VizModuleState(
      enabled: m?.enabledByDefault ?? false,
      values: const {},
    );
  }

  void setEnabled(String moduleId, bool enabled) {
    final cur = stateFor(moduleId);
    state = {...state, moduleId: cur.copyWith(enabled: enabled)};
    if (!enabled) {
      // Drop any internal pulse/pair state so the module doesn't pop
      // back to its last frame when re-enabled.
      VizRegistry.find(moduleId)?.reset();
    }
    _pushStatsFlag();
  }

  void setParam(String moduleId, String paramId, double value) {
    final cur = stateFor(moduleId);
    final nextValues = {...cur.values, paramId: value};
    state = {...state, moduleId: cur.copyWith(values: nextValues)};
  }

  void resetModule(String moduleId) {
    final m = VizRegistry.find(moduleId);
    state = {
      ...state,
      moduleId: VizModuleState(
        enabled: m?.enabledByDefault ?? false,
        values: const {},
      ),
    };
    m?.reset();
    _pushStatsFlag();
  }

  /// Build a [VizParamValues] snapshot for a module. Called every frame
  /// by the scene bridge, so keep it allocation-free where possible.
  VizParamValues paramsFor(VizModule m) {
    final s = stateFor(m.id);
    return VizParamValues(s.values, m.params);
  }
}

final vizStateProvider = NotifierProvider<VizStateNotifier, VizState>(
  VizStateNotifier.new,
);

/// Whether the per-element stats HUD is visible. Toggled from the
/// visualizer panel (no keyboard shortcut yet — rebinding Intents
/// inside the renderer view is a separate chore).
class VizHudVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => set(!state);
  void set(bool v) {
    if (state == v) return;
    state = v;
    // HUD reads the same stats block as channel modules — keep the
    // engine-side gate in sync so enabling the HUD with all modules
    // off still delivers live numbers.
    ref.read(vizStateProvider.notifier).setHudNeedsStats(v);
  }
}

final vizHudVisibleProvider = NotifierProvider<VizHudVisibleNotifier, bool>(
  VizHudVisibleNotifier.new,
);
