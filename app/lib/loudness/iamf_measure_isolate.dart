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

import '../export/iamf_measure_isolate.dart';
import '../ffi/engine_bindings.dart';
import '../ffi/engine_strings.dart';
import '../ffi_bridge.dart';

/// One audio element of a decoded-IAMF measurement: which element of
/// the file renders, at what static mix gain, with which IAMF rendering
/// config (spec integers, as `eclipsa_studio_iamf_measurer_include_element`
/// takes them).
class IamfMeasureElement {
  final int audioElementId;
  final double mixGainDb;
  final int headphonesMode;
  final int binauralProfile;

  const IamfMeasureElement({
    required this.audioElementId,
    required this.mixGainDb,
    this.headphonesMode = 1,
    this.binauralProfile = 0,
  });
}

/// Result of one decoded-IAMF measurement: the outcome, or, when it
/// failed, the measurer's error message (prefixed `io:`, `malformed:`,
/// `unsupported:`, `invalid_argument:` or `internal:`). The message is
/// null when the measurer has none to give: a failed open destroys the
/// measurer, and an exception in the measure leaves no message. The
/// engine log has the cause in both cases.
class IamfMeasureOutcome {
  final MixMeasureOutcome? outcome;
  final String? error;

  const IamfMeasureOutcome(MixMeasureOutcome this.outcome) : error = null;
  const IamfMeasureOutcome.failed([this.error]) : outcome = null;
}

/// Decodes the IAMF file at [path] on a short-lived background isolate,
/// renders [elements] at [oarLayout] through a standalone offline
/// renderer and measures BS.1770-4 loudness, with the same analyzer,
/// limiter and traces as [runMixMeasureOnIsolate]. The file's own
/// sample rate is the render rate.
///
/// Each measurer instance is standalone and maps the file itself, so
/// concurrent calls are fine; the live renderer must be held
/// offline-exclusive for the whole pass (`setExportPaused`, ES-44), as
/// for the creator report.
///
/// Returns the scalars (plus the recorded time series when [withTraces]
/// is set) in [IamfMeasureOutcome.outcome], or a null outcome when the
/// file could not be opened, an element could not be included, or the
/// decode/render/measure failed. [IamfMeasureOutcome.error] then holds
/// the measurer's message when it has one; the engine log has the
/// specifics. A failed measure must never be read as silence.
Future<IamfMeasureOutcome> runIamfMeasureOnIsolate({
  required String path,
  required int bufferSize,
  required int oarLayout,
  required double outputMixGainDb,
  required List<IamfMeasureElement> elements,
  bool withTraces = false,
}) {
  final dylibPath = EclipsaStudioEngine.dylibPath;
  return Isolate.run(() {
    final bindings = EngineBindings(DynamicLibrary.open(dylibPath));
    final pathPtr = path.toNativeUtf8(allocator: ffi_pkg.malloc);
    final Pointer handle;
    try {
      handle = bindings.iamfMeasurerCreate(pathPtr, bufferSize, oarLayout);
    } finally {
      ffi_pkg.malloc.free(pathPtr);
    }
    if (handle == nullptr) {
      // The measurer is destroyed on a failed open, which has several
      // causes (unreadable file, no audio frames, renderer init), so no
      // message is readable here; the engine log carries it.
      return const IamfMeasureOutcome.failed();
    }
    try {
      // Owned by the measurer and valid until the next call on it; read
      // before destroy, never freed here. Empty after an exception in
      // the measure (return code -5).
      IamfMeasureOutcome fail() {
        final message = decodeEngineString(
          bindings.iamfMeasurerLastError(handle),
        );
        return IamfMeasureOutcome.failed(message.isEmpty ? null : message);
      }

      for (final e in elements) {
        final rc = bindings.iamfMeasurerIncludeElement(
          handle,
          e.audioElementId,
          e.mixGainDb,
          e.headphonesMode,
          e.binauralProfile,
        );
        if (rc != 0) return fail();
      }
      bindings.iamfMeasurerSetOutputGain(handle, outputMixGainDb);

      final scalars = readMeasureScalars(
        (lufs, tp, dp) => bindings.iamfMeasurerMeasure(handle, lufs, tp, dp),
      );
      if (scalars == null) return fail();
      if (!withTraces) {
        return IamfMeasureOutcome(MixMeasureOutcome(scalars: scalars));
      }
      return IamfMeasureOutcome(
        MixMeasureOutcome(
          scalars: scalars,
          traces: readMeasureTraces(
            traceLen: (series) => bindings.iamfMeasurerTraceLen(handle, series),
            copyTrace: (series, out, cap) =>
                bindings.iamfMeasurerCopyTrace(handle, series, out, cap),
            loudnessRange: (lra, stable) =>
                bindings.iamfMeasurerLoudnessRange(handle, lra, stable),
          ),
        ),
      );
    } finally {
      bindings.iamfMeasurerDestroy(handle);
    }
  });
}
