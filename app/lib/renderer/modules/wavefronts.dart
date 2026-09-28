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

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:vector_math/vector_math.dart';

import '../coordinate_utils.dart';
import '../viz_layer.dart';
import '../viz_module.dart';

/// Expanding spherical wavefronts emitted when a channel's transient
/// onset flag rises. Each pulse originates at its channel's speaker
/// position and expands radially at a configurable speed, fading out
/// over its lifetime.
///
/// Holds internal pulse state between frames — so the module is not
/// a pure function. [reset] clears all active pulses (invoked when
/// the user toggles the module off).
class WavefrontsModule extends ChannelVizModule {
  @override
  String get id => 'wavefronts';

  @override
  String get displayName => 'Transient wavefronts';

  @override
  String get description =>
      'Expanding translucent shells emitted from each channel when '
      'its transient onset fires.';

  @override
  bool get enabledByDefault => false;

  static const _pSpeed = VizParam(
    id: 'speed',
    label: 'Expansion speed',
    min: 0.2,
    max: 4.0,
    defaultValue: 1.6,
    unit: '/s',
  );
  static const _pLifetime = VizParam(
    id: 'lifetime',
    label: 'Lifetime',
    min: 0.15,
    max: 2.5,
    defaultValue: 0.9,
    unit: 's',
  );
  static const _pMaxRadius = VizParam(
    id: 'max_radius',
    label: 'Max radius',
    min: 1.0,
    max: 4.0,
    defaultValue: 2.4,
  );
  static const _pThickness = VizParam(
    id: 'thickness',
    label: 'Shell width',
    min: 0.01,
    max: 0.2,
    defaultValue: 0.04,
  );
  static const _pAlphaGain = VizParam(
    id: 'alpha',
    label: 'Peak opacity',
    min: 0.0,
    max: 1.0,
    defaultValue: 0.5,
  );
  static const _pMaxPulses = VizParam(
    id: 'max_pulses',
    label: 'Max pulses',
    min: 8,
    max: 128,
    defaultValue: 48,
  );

  @override
  List<VizParam> get params => const [
    _pSpeed,
    _pLifetime,
    _pMaxRadius,
    _pThickness,
    _pAlphaGain,
    _pMaxPulses,
  ];

  // ── Internal pulse state (per-frame integration) ────────────────────
  // Queue instead of List so dropping the oldest pulse when the pool
  // overflows is O(1) — List.removeAt(0) would be O(n) and gets called
  // every time maxPulses is hit.
  final Queue<_Pulse> _pulses = Queue<_Pulse>();

  // Rising-edge detection state: one uint8 per (elementId, channel).
  // The engine sets the onset flag sticky for ~80 ms — we still only
  // want one pulse per rising edge, so remember the last observed flag.
  final Map<int, List<int>> _lastOnset = {};

  @override
  List<VizLayer> build(ChannelVizInput input, VizParamValues p) {
    if (input.elements.isEmpty && _pulses.isEmpty) return const [];

    final speed = p.get(_pSpeed.id);
    final lifetime = p.get(_pLifetime.id);
    final maxRadius = p.get(_pMaxRadius.id);
    final thickness = p.get(_pThickness.id);
    final alphaGain = p.get(_pAlphaGain.id);
    final maxPulses = p.get(_pMaxPulses.id).round();

    // Emit new pulses on rising edges.
    for (final e in input.elements) {
      final stats = e.stats;
      if (stats.isEmpty) continue;

      final n = math.min(stats.channelCount, e.layout.speakers.length);
      final last = _lastOnset.putIfAbsent(
        e.element.id,
        () => List<int>.filled(n, 0),
      );
      if (last.length < n) {
        last.addAll(List<int>.filled(n - last.length, 0));
      }

      final color = Color(e.element.color);
      for (var c = 0; c < n; c++) {
        final spk = e.layout.speakers[c];
        if (spk.isLFE) continue;
        final cur = stats.onset[c];
        final rising = cur != 0 && last[c] == 0;
        last[c] = cur;
        if (!rising) continue;

        // Weight the pulse's peak opacity by current channel energy
        // so quiet transients don't flood the scene.
        final e2 = stats.energy[c];
        if (e2 <= 0) continue;
        final intensity = (math.sqrt(e2 * 50).clamp(0.0, 1.0)).toDouble();

        // Pulse origin is the speaker's actual position (ADM distance
        // baked in), so wavefronts visually emanate from the speaker
        // rather than from the center of the scene.
        final origin = CoordinateUtils.sphericalToVisualizer(
          spk.azDeg,
          spk.elDeg,
          spk.distance,
        );

        _pulses.add(
          _Pulse(origin: origin, age: 0.0, intensity: intensity, color: color),
        );
      }
    }

    // Prune rising-edge state for elements that no longer exist —
    // bounded by the element cap either way, but stale ids would
    // otherwise sit in the map for the rest of the session. The guard
    // keeps the steady state allocation-free.
    if (_lastOnset.length > input.elements.length) {
      final live = {for (final e in input.elements) e.element.id};
      _lastOnset.removeWhere((id, _) => !live.contains(id));
    }

    // Clamp the pulse pool — drop the oldest when we exceed maxPulses.
    // Queue.removeFirst() is O(1).
    while (_pulses.length > maxPulses) {
      _pulses.removeFirst();
    }

    // Advance + build the layer. Expire from the head (oldest first)
    // as soon as we stop finding expired pulses — relies on pulses
    // being enqueued in time order so a single pass is enough.
    while (_pulses.isNotEmpty && _pulses.first.age >= lifetime) {
      _pulses.removeFirst();
    }
    final out = <Wavefront>[];
    for (final pulse in _pulses) {
      pulse.age += input.dtSec;
      if (pulse.age >= lifetime) continue;
      final tNorm = pulse.age / lifetime;
      final radius = math.min(pulse.age * speed, maxRadius);
      // Fade curve — quick attack, long decay — sin(π t)^0.7.
      final env = math.pow(math.sin(math.pi * tNorm), 0.7).toDouble();
      final alpha = alphaGain * pulse.intensity * env;
      if (alpha <= 0.001) continue;
      out.add(
        Wavefront(
          origin: pulse.origin,
          radius: radius,
          thickness: thickness,
          color: pulse.color,
          alpha: alpha,
        ),
      );
    }

    if (out.isEmpty && _pulses.isEmpty) return const [];
    return [WavefrontLayer(id: id, pulses: out)];
  }

  @override
  void reset() {
    _pulses.clear();
    _lastOnset.clear();
  }
}

class _Pulse {
  final Vector3 origin;
  double age;
  final double intensity;
  final Color color;

  _Pulse({
    required this.origin,
    required this.age,
    required this.intensity,
    required this.color,
  });
}
