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

import 'package:ffi/ffi.dart' as ffi_pkg;

import '../ffi/engine_bindings.dart';
import '../ffi_bridge.dart';

/// Runs the IAMF + video → MP4 mux (`eclipsa_studio_iamf_mux`) on a short-lived
/// background isolate so the UI isolate stays responsive — libgpac's ISO-media
/// sample copy is a single blocking call that would otherwise freeze the main
/// isolate while the video track is rewritten.
///
/// The mux drives process-global engine state (`g_iamf_muxer`), shared
/// across isolates because the dylib is mapped once per process. The C
/// API serializes re-entry via an atomic busy flag, so only one mux runs
/// at a time.
///
/// Returns the muxer result code: 0 on success, negative on error (see
/// `eclipsa_studio::IamfMuxer::Mux` for the table).
Future<int> runIamfMuxOnIsolate({
  required String inputIamf,
  required String inputVideo,
  required String outputMp4,
}) {
  final dylibPath = EclipsaStudioEngine.dylibPath;
  return Isolate.run(() {
    final mux = EngineBindings(DynamicLibrary.open(dylibPath)).iamfMux;
    final iamfPtr = inputIamf.toNativeUtf8(allocator: ffi_pkg.malloc);
    final videoPtr = inputVideo.toNativeUtf8(allocator: ffi_pkg.malloc);
    final outPtr = outputMp4.toNativeUtf8(allocator: ffi_pkg.malloc);
    try {
      return mux(iamfPtr, videoPtr, outPtr);
    } finally {
      ffi_pkg.malloc.free(iamfPtr);
      ffi_pkg.malloc.free(videoPtr);
      ffi_pkg.malloc.free(outPtr);
    }
  });
}

/// Runs `eclipsa_studio_video_container_probe` on a short-lived background
/// isolate: opens [inputVideo] with the same libgpac reader the mux uses
/// and looks for a visual track, reading only the container's metadata.
/// The export dialog calls it when a video is loaded so a file the muxer
/// cannot read is reported before the encode runs, not after (ES-742).
///
/// Returns 0 when the file muxes, negative otherwise: -1 null argument,
/// -3 missing file, -5 a C++ exception at the FFI boundary, -10 GPAC
/// init failed, -12 the container cannot be opened, -13 no visual track
/// (see `eclipsa_studio_video_container_probe` in `engine/engine.h`).
Future<int> runVideoContainerProbeOnIsolate(String inputVideo) {
  final dylibPath = EclipsaStudioEngine.dylibPath;
  return Isolate.run(() {
    final probe = EngineBindings(
      DynamicLibrary.open(dylibPath),
    ).videoContainerProbe;
    final videoPtr = inputVideo.toNativeUtf8(allocator: ffi_pkg.malloc);
    try {
      return probe(videoPtr);
    } finally {
      ffi_pkg.malloc.free(videoPtr);
    }
  });
}
