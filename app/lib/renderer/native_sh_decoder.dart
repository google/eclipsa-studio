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

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;

import '../ffi_bridge.dart';
import 'sh_utils.dart';

/// Wraps the C++ Eigen-based SH decoder for fast matrix-vector decode.
///
/// Call [decode] each frame with new coefficients. The decode matrix
/// is precomputed in C++ at construction and reused.
class NativeShDecoder {
  final EclipsaStudioEngine _engine;
  final int numProbes;
  final int numChannels;

  Pointer<Void> _handle = nullptr;
  Pointer<Float> _coeffsBuf = nullptr;
  Pointer<Float> _energiesBuf = nullptr;

  NativeShDecoder({
    required EclipsaStudioEngine engine,
    required List<(double az, double el)> directions,
    required int order,
    required ShDirectivity directivity,
  }) : _engine = engine,
       numProbes = directions.length,
       numChannels = ShUtils.channelCount(order) {
    if (!engine.hasShDecode) {
      _coeffsBuf = nullptr;
      _energiesBuf = nullptr;
      return;
    }

    // Allocate native buffers.
    final azBuf = ffi_pkg.malloc<Float>(numProbes);
    final elBuf = ffi_pkg.malloc<Float>(numProbes);
    for (var i = 0; i < numProbes; i++) {
      azBuf[i] = directions[i].$1;
      elBuf[i] = directions[i].$2;
    }

    _handle = _engine.shDecoderCreate(
      azBuf,
      elBuf,
      numProbes,
      order,
      directivity.index,
    );

    ffi_pkg.malloc.free(azBuf);
    ffi_pkg.malloc.free(elBuf);

    _coeffsBuf = ffi_pkg.malloc<Float>(numChannels);
    _energiesBuf = ffi_pkg.malloc<Float>(numProbes);
  }

  bool get isValid => _handle != nullptr;

  /// Decode [coeffs] into per-probe squared energies.
  Float32List decode(List<double> coeffs) {
    if (!isValid) return Float32List(numProbes);

    final n = coeffs.length < numChannels ? coeffs.length : numChannels;
    for (var i = 0; i < n; i++) {
      _coeffsBuf[i] = coeffs[i];
    }
    for (var i = n; i < numChannels; i++) {
      _coeffsBuf[i] = 0.0;
    }

    _engine.shDecode(_handle, _coeffsBuf, _energiesBuf);

    // Return a view — callers consume synchronously before the
    // next decode() call, so no copy is needed.
    return _energiesBuf.asTypedList(numProbes);
  }

  void dispose() {
    if (_handle != nullptr) {
      _engine.shDecoderDestroy(_handle);
      _handle = nullptr;
    }
    if (_coeffsBuf != nullptr) {
      ffi_pkg.malloc.free(_coeffsBuf);
      _coeffsBuf = nullptr;
    }
    if (_energiesBuf != nullptr) {
      ffi_pkg.malloc.free(_energiesBuf);
      _energiesBuf = nullptr;
    }
  }
}
