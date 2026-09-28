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
import 'dart:typed_data';

import '../ffi_bridge.dart';
import 'coordinate_utils.dart';
import 'icosahedron.dart';
import 'native_sh_decoder.dart';
import 'sh_utils.dart' show ShDirectivity;

/// Cached SH decode of a summed ambisonic coefficient set onto an
/// icosahedron tessellation.
///
/// The function keeps per-subdivision caches for the mesh, probe
/// directions, and the native decoder instance — so repeated calls at
/// the same (subdivisions, order, directivity, engine) are cheap. EMA
/// smoothing is applied so the mesh doesn't chatter at 60 Hz.
class ShDecodeResult {
  final Icosahedron mesh;

  /// A view of the shared EMA buffer — valid until the next [decode]
  /// call. Consume synchronously; do not cache across frames. (Same
  /// contract as readElementStats' pooled slots in ffi_bridge.dart.)
  final List<double> energies;

  const ShDecodeResult({required this.mesh, required this.energies});
}

class ShDecodeHelper {
  ShDecodeHelper._();

  static final Map<int, Icosahedron> _icoCache = {};
  static final Map<int, List<(double, double)>> _probeAzElCache = {};

  static NativeShDecoder? _decoder;
  static EclipsaStudioEngine? _decoderEngine;
  static int _decoderSubs = -1;
  static int _decoderOrder = -1;
  static ShDirectivity _decoderDir = ShDirectivity.inPhase;

  static Float64List _prevEnergies = Float64List(0);

  /// EMA blend factor for decoded energies (~50 ms at 60 Hz). Public
  /// so MollweidePainter's decode path smooths identically.
  static const double smoothing = 0.35;

  static Icosahedron _icosahedron(int subdivisions) => _icoCache.putIfAbsent(
    subdivisions,
    () => Icosahedron.generate(subdivisions: subdivisions),
  );

  static List<(double, double)> _probeAzEl(Icosahedron ico, int subdivisions) {
    return _probeAzElCache.putIfAbsent(subdivisions, () {
      return ico.faces.map((f) {
        final (a, b, c) = f;
        final centroid = (ico.vertices[a] + ico.vertices[b] + ico.vertices[c])
          ..scale(1 / 3)
          ..normalize();
        // Icosahedron vertices are in visualizer space; decoder
        // expects ADM audio space.
        final audio = CoordinateUtils.visualizerToAudio(centroid);
        final az = math.atan2(audio.x, audio.z);
        final el = math.asin(audio.y.clamp(-1.0, 1.0));
        return (az, el);
      }).toList();
    });
  }

  /// Decode [coeffs] at the icosahedron centroids, apply EMA smoothing,
  /// and return the mesh + per-face energies. Safe to call repeatedly
  /// per frame.
  static ShDecodeResult decode({
    required EclipsaStudioEngine engine,
    required List<double> coeffs,
    required int order,
    required int subdivisions,
    required ShDirectivity directivity,
  }) {
    final ico = _icosahedron(subdivisions);
    final probes = _probeAzEl(ico, subdivisions);

    if (_decoderEngine != engine ||
        _decoderSubs != subdivisions ||
        _decoderOrder != order ||
        _decoderDir != directivity) {
      _decoder?.dispose();
      _decoder = NativeShDecoder(
        engine: engine,
        directions: probes,
        order: order,
        directivity: directivity,
      );
      _decoderEngine = engine;
      _decoderSubs = subdivisions;
      _decoderOrder = order;
      _decoderDir = directivity;
    }

    final raw = _decoder != null && _decoder!.isValid
        ? _decoder!.decode(coeffs)
        : List<double>.filled(probes.length, 0.0);

    final n = raw.length;
    if (_prevEnergies.length != n) {
      _prevEnergies = Float64List(n);
    }
    for (var i = 0; i < n; i++) {
      _prevEnergies[i] =
          smoothing * raw[i] + (1 - smoothing) * _prevEnergies[i];
    }

    // Hand out the EMA buffer directly (up to 5120 doubles at
    // subdivision 4) — copying it every frame at 60 Hz defeats the
    // zero-copy design of NativeShDecoder underneath. See the
    // ShDecodeResult.energies contract.
    return ShDecodeResult(mesh: ico, energies: _prevEnergies);
  }
}
