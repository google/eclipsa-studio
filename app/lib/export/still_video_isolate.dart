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
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;

import '../ffi/engine_bindings.dart';
import '../ffi_bridge.dart';

/// Runs the still→video encode (`eclipsa_studio_still_video_encode`) on a
/// short-lived background isolate — the encode is one synchronous call
/// that repeats the frame for the whole session length, which would
/// freeze the UI isolate for seconds.
///
/// [rgba] is tightly packed RGBA8888 ([width] * [height] * 4 bytes,
/// top-down); both dimensions must be even (see
/// `still_export_frame.dart`, which prepares a conforming frame).
///
/// Returns the encoder result code: 0 on success, negative on error
/// (see `eclipsa_studio_still_video_encode` in engine.h for the table).
Future<int> runStillVideoEncodeOnIsolate({
  required Uint8List rgba,
  required int width,
  required int height,
  required int fps,
  required double durationSeconds,
  required String outputMp4,
}) {
  final dylibPath = EclipsaStudioEngine.dylibPath;
  return Isolate.run(() {
    final encode = EngineBindings(
      DynamicLibrary.open(dylibPath),
    ).stillVideoEncode;
    final pixels = ffi_pkg.malloc.allocate<Uint8>(rgba.length);
    final outPtr = outputMp4.toNativeUtf8(allocator: ffi_pkg.malloc);
    try {
      pixels.asTypedList(rgba.length).setAll(0, rgba);
      return encode(
        pixels,
        rgba.length,
        width,
        height,
        fps,
        durationSeconds,
        outPtr,
      );
    } finally {
      ffi_pkg.malloc.free(pixels);
      ffi_pkg.malloc.free(outPtr);
    }
  });
}
