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

import 'dart:typed_data';
import 'dart:ui';

/// Color lookup table for mapping normalized values (0..1) to colors.
///
/// Supports multiple named colormaps commonly used in scientific visualization.
class Colormap {
  final String name;
  final List<Color> _stops;

  const Colormap._(this.name, this._stops);

  /// Sample the colormap at position [t] (0..1).
  Color sample(double t) {
    final tc = t.clamp(0.0, 1.0);
    if (tc <= 0) return _stops.first;
    if (tc >= 1) return _stops.last;

    final pos = tc * (_stops.length - 1);
    final i = pos.floor();
    final frac = pos - i;

    if (i >= _stops.length - 1) return _stops.last;
    return Color.lerp(_stops[i], _stops[i + 1], frac)!;
  }

  /// Default dB floor for energy-based LUT sampling.
  static const defaultFloorDb = -60.0;

  /// Default alpha fade range in dB (from the floor upward).
  static const defaultFadeDb = 15.0;

  Color _sampleWithFade(double t, double fadeThreshold) {
    final color = sample(t);
    if (t < fadeThreshold) {
      final local = t / fadeThreshold;
      return color.withValues(alpha: local * local);
    }
    return color;
  }

  // ── LUT-based fast path ──

  /// 256-entry ARGB lookup table, built lazily.
  /// Stored in a static cache keyed by colormap name since the
  /// class uses const constructors.
  static final Map<String, Uint32List> _lutCache = {};

  /// Get or build the ARGB LUT for this colormap.
  Uint32List get lut => _lutCache.putIfAbsent(name, _buildLut);

  Uint32List _buildLut() {
    const n = 256;
    final table = Uint32List(n);
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      table[i] = _sampleWithFade(t, defaultFadeDb / -defaultFloorDb).toARGB32();
    }
    return table;
  }

  // ── Named colormaps ──

  /// Green → Yellow → Red (classic audio meter)
  static const audioMeter = Colormap._('audioMeter', [
    Color(0xFF10B981), // green
    Color(0xFF34D399), // light green
    Color(0xFFFBBF24), // yellow
    Color(0xFFF59E0B), // amber
    Color(0xFFEF4444), // red
  ]);

  /// Blue → Cyan → Green → Yellow → Red (plasma-like)
  static const plasma = Colormap._('plasma', [
    Color(0xFF0D0887), // deep purple
    Color(0xFF6A00A8), // purple
    Color(0xFFB12A90), // magenta
    Color(0xFFE16462), // salmon
    Color(0xFFFCA636), // orange
    Color(0xFFF0F921), // yellow
  ]);

  /// Black → Purple → Pink → White (Eclipsa Studio brand)
  static const eclipsa = Colormap._('eclipsa', [
    Color(0xFF080810),
    Color(0xFF2D1B69),
    Color(0xFFA855F7), // purple
    Color(0xFFEC4899), // pink
    Color(0xFFFFFFFF),
  ]);

  /// Inferno: black → red → orange → yellow → white
  static const inferno = Colormap._('inferno', [
    Color(0xFF000004),
    Color(0xFF420A68),
    Color(0xFF932667),
    Color(0xFFDD513A),
    Color(0xFFFCA50A),
    Color(0xFFFCFFA4),
  ]);

  /// All available colormaps.
  static const all = [audioMeter, plasma, eclipsa, inferno];

  /// Look up by name.
  static Colormap byName(String name) =>
      all.firstWhere((c) => c.name == name, orElse: () => audioMeter);
}
