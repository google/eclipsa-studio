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
import 'element_clip_stats.dart';

/// One element's inputs for the IAMF encode, mirroring the engine's
/// `ElementStream::Config` plus the UserMetadata join key. All fields
/// are primitives/sendables so the request crosses to the encode
/// isolate.
class IamfPushElement {
  /// Must equal the element's `audio_frame_metadata.wav_filename` in the
  /// textproto (the dialog's `wavBasenames` value) — the engine resolves
  /// audio_element_id and channel labels through it.
  final String wavBasename;

  final String sourceWavPath;
  final double gainDb;
  final List<int> routing;
  final int padToFrames;
  final int outputSampleRate;

  const IamfPushElement({
    required this.wavBasename,
    required this.sourceWavPath,
    required this.gainDb,
    this.routing = const [],
    required this.padToFrames,
    required this.outputSampleRate,
  });
}

/// Result of one push encode: the engine return code plus per-element
/// signal-overload stats counted on the PCM actually fed to the
/// encoder (ES-470), aligned with the request's element order. An entry
/// is null when the engine had no stats for that index (the run failed
/// before its streams opened).
class IamfPushEncodeResult {
  final int rc;
  final List<ElementClipStats?> elementStats;

  const IamfPushEncodeResult({required this.rc, required this.elementStats});
}

/// Runs the push-PCM IAMF encode (`eclipsa_studio_iamf_push_export_*`, ES-480) on
/// a short-lived background isolate so the UI isolate stays free to
/// animate progress. Each element streams from its source file through
/// the engine's bounce pipeline (gain, routing, resample, pad) straight
/// into the encoder — no temp WAVs.
///
/// The begin/add/run sequence stays on this single isolate thread (the
/// engine requires that); cancel works cross-isolate via
/// [EclipsaStudioEngine.iamfExportCancel] because the exporter state is
/// process-global (the dylib is mapped once per process), and the push
/// loop honors it per coded frame, all the way through the encode.
///
/// Returns the engine result code (0 on success, negative on error —
/// see `IamfExporter::EncodePush` for the table; -99 = cancelled)
/// together with per-element overload stats, which are meaningful (if
/// partial) on failed and cancelled runs too.
Future<IamfPushEncodeResult> runIamfPushEncodeOnIsolate({
  required String configTextproto,
  required String outputIamfPath,
  required List<IamfPushElement> elements,
}) {
  final dylibPath = EclipsaStudioEngine.dylibPath;
  return Isolate.run(() {
    final bindings = EngineBindings(DynamicLibrary.open(dylibPath));

    IamfPushEncodeResult earlyExit(int rc) => IamfPushEncodeResult(
      rc: rc,
      elementStats: List<ElementClipStats?>.filled(elements.length, null),
    );

    final cfgPtr = configTextproto.toNativeUtf8(allocator: ffi_pkg.malloc);
    final outPtr = outputIamfPath.toNativeUtf8(allocator: ffi_pkg.malloc);
    try {
      final rc = bindings.iamfPushExportBegin(cfgPtr, outPtr);
      if (rc != 0) return earlyExit(rc);
    } finally {
      ffi_pkg.malloc.free(cfgPtr);
      ffi_pkg.malloc.free(outPtr);
    }

    for (final e in elements) {
      final namePtr = e.wavBasename.toNativeUtf8(allocator: ffi_pkg.malloc);
      final srcPtr = e.sourceWavPath.toNativeUtf8(allocator: ffi_pkg.malloc);
      Pointer<Int32> routingPtr = nullptr;
      if (e.routing.isNotEmpty) {
        routingPtr = ffi_pkg.malloc<Int32>(e.routing.length);
        routingPtr.asTypedList(e.routing.length).setAll(0, e.routing);
      }
      try {
        final rc = bindings.iamfPushExportAddElement(
          namePtr,
          srcPtr,
          e.gainDb,
          routingPtr,
          e.routing.length,
          e.padToFrames,
          e.outputSampleRate,
        );
        if (rc != 0) return earlyExit(rc);
      } finally {
        ffi_pkg.malloc.free(namePtr);
        ffi_pkg.malloc.free(srcPtr);
        if (routingPtr != nullptr) ffi_pkg.malloc.free(routingPtr);
      }
    }

    final rc = bindings.iamfPushExportRun();

    // Same isolate, run() has returned: the stats window ("valid until
    // the next begin") is open. Add-order index == request order.
    final stats = <ElementClipStats?>[];
    final clippedPtr = ffi_pkg.malloc.allocate<Uint64>(sizeOf<Uint64>());
    final peakPtr = ffi_pkg.malloc.allocate<Float>(sizeOf<Float>());
    try {
      for (var i = 0; i < elements.length; i++) {
        final ok =
            bindings.iamfPushExportElementClipStats(i, clippedPtr, peakPtr) ==
            0;
        stats.add(
          ok
              ? ElementClipStats(
                  clippedSamples: clippedPtr.value,
                  peakLinear: peakPtr.value.toDouble(),
                )
              : null,
        );
      }
    } finally {
      ffi_pkg.malloc.free(clippedPtr);
      ffi_pkg.malloc.free(peakPtr);
    }

    return IamfPushEncodeResult(rc: rc, elementStats: stats);
  });
}
