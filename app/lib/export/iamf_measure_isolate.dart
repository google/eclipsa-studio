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
import 'element_clip_stats.dart';

/// One element's contribution to an offline mix render, mirroring
/// `MixElementConfig` on the engine side: the source WAV plus the same
/// stream inputs the IAMF push export takes ([IamfPushElement] minus
/// the join key) and the mix-level rendering config. All fields are
/// primitives/sendables so the whole request crosses to a background
/// isolate.
class MixMeasureElement {
  final String sourceWavPath;

  /// Element pre-gain in dB, applied in the stream — distinct from
  /// [mixGainDb], the mix-level (OAR) gain.
  final double gainDb;

  /// Channel routing map (`output_ch[i] = input_ch[routing[i]]`,
  /// -1 = silence). Empty = identity.
  final List<int> routing;

  /// Stream length in output-rate frames (pad short, truncate long).
  final int padToFrames;

  final int outputSampleRate;
  final int elementId;
  final int elementType;
  final int elementSubType;
  final int channels;
  final double mixGainDb;
  final int headphonesMode;
  final int binauralProfile;

  /// Object-based only (elementType == 2): polar position(s), in the
  /// shape produced by [elementObjectPolarPositions]. Objects without
  /// positions measure as silence on loudspeaker layouts — OAR's
  /// object-to-loudspeaker renderer stays silent until positions
  /// arrive. Ignored for channel/scene elements.
  final int numObjects;
  final double azimuth;
  final double elevation;
  final double distance;
  final double azimuth2;
  final double elevation2;
  final double distance2;

  const MixMeasureElement({
    required this.sourceWavPath,
    required this.gainDb,
    this.routing = const [],
    required this.padToFrames,
    required this.outputSampleRate,
    required this.elementId,
    required this.elementType,
    required this.elementSubType,
    required this.channels,
    required this.mixGainDb,
    required this.headphonesMode,
    required this.binauralProfile,
    this.numObjects = 1,
    this.azimuth = 0,
    this.elevation = 0,
    this.distance = 1,
    this.azimuth2 = 0,
    this.elevation2 = 0,
    this.distance2 = 1,
  });
}

/// Loudness measurement for one mix × layout.
typedef MixMeasureResult = ({
  double integratedLufs,
  double truePeakDbtp,
  double digitalPeakDbfs,
});

/// Trace series ids, mirroring `eclipsa_studio::MixTraceSeries` (engine.h).
const int _kTraceMomentaryLufs = 0;
const int _kTraceShortTermLufs = 1;
const int _kTraceShortTermPeakDbfs = 2;
const int _kTraceShortTermPsrDb = 3;
const int _kTraceLimiterGrDb = 4;

/// Loudness time series recorded during one mix × layout render. Every
/// series steps at [stepMs]; a series has fewer entries than
/// program-length/step because its first entry lands only once its
/// analysis window fills (400 ms momentary, 3 s the short-term family).
class MixMeasureTraces {
  /// Milliseconds between consecutive entries of every series
  /// (`OfflineMixRenderer::kTraceStepMs`).
  static const int stepMs = 100;

  final Float32List momentaryLufs; // 400 ms window, ungated
  final Float32List shortTermLufs; // 3 s sliding window, ungated
  final Float32List shortTermPeakDbfs; // max sample peak per 3 s window
  final Float32List shortTermPsrDb; // peak minus short-term loudness

  /// Limiter envelope sampled once per render block, max-reduced per
  /// 100 ms step (dB, >= 0). Sustained limiting reads accurately;
  /// isolated transients are understated, because each step sees only
  /// a few block-end point samples of the 50 ms-release envelope —
  /// resolution is bounded by the render block size (exact per-sample
  /// tracking is ES-541). Unlike the analyzer series, there is no
  /// window-fill offset — entries run from t=0. GR > 0 at step k means
  /// the exported (unlimited) audio exceeds −1 dBFS at or shortly
  /// after an engagement near that step (the release tail smears into
  /// the following steps): the report's numbers are measured after the
  /// −1 dBFS limiter, while the exported file is not limited.
  final Float32List limiterGrDb;

  /// EBU TECH 3342 loudness range; null when the program was too short
  /// for a short-term block.
  final double? loudnessRangeLu;

  /// EBU TECH 3341 "stable after 60 s" criterion for [loudnessRangeLu].
  final bool lraStable;

  const MixMeasureTraces({
    required this.momentaryLufs,
    required this.shortTermLufs,
    required this.shortTermPeakDbfs,
    required this.shortTermPsrDb,
    required this.limiterGrDb,
    required this.loudnessRangeLu,
    required this.lraStable,
  });

  /// Engagement threshold: GR above this counts as "limiting" (~0.1%
  /// linear gain deviation — below it is release-tail float dust).
  static const double engagedThresholdDb = 0.01;

  // The isFinite guards below mirror the report chart's defense in
  // depth: the engine only writes finite entries, but one NaN would
  // otherwise poison the max / the engaged count.
  double get maxLimiterGrDb =>
      limiterGrDb.fold(0.0, (m, v) => v.isFinite && v > m ? v : m);

  /// Fraction of program steps with the limiter engaged, 0..1.
  double get limiterEngagedFraction => limiterGrDb.isEmpty
      ? 0.0
      : limiterGrDb.where((v) => v.isFinite && v > engagedThresholdDb).length /
            limiterGrDb.length;
}

/// Scalars plus (optionally) the recorded time series for one
/// mix × layout measurement.
class MixMeasureOutcome {
  final MixMeasureResult scalars;

  /// Present when the caller requested traces and the render succeeded.
  final MixMeasureTraces? traces;

  /// Per-element signal-overload stats of this render, keyed by
  /// element id (ES-470). Counted on each element's own stream output —
  /// the PCM the IAMF export would encode — not on the limited mix.
  final Map<int, ElementClipStats> elementClipStats;

  const MixMeasureOutcome({
    required this.scalars,
    this.traces,
    this.elementClipStats = const {},
  });
}

/// Renders one mix × layout through a standalone offline renderer and
/// measures BS.1770-4 loudness on a short-lived background isolate, so
/// the UI isolate stays responsive (and the progress indicator keeps
/// animating) during the multi-second render.
///
/// Safe because each [`OfflineMixRenderer`] instance is standalone —
/// its OAR/OBR state is fully per-instance, verified by the engine's
/// offline_mix_concurrency_test under the TSan/ASan CI sweeps — and
/// the *live* OAR is paused for the whole export (see `setExportPaused`
/// / issue ES-44). Concurrent calls are fine (the measure pass runs a
/// bounded pool of them); only overlap with the live renderer is
/// forbidden.
///
/// Returns the loudness scalars (plus the recorded time series when
/// [withTraces] is set), or null if the renderer could not be created,
/// an element failed to load, or the render/measure itself failed (the
/// engine logs the specifics). A failed measure must never be read as
/// silence — the engine's -120 LUFS defaults are not written on error.
Future<MixMeasureOutcome?> runMixMeasureOnIsolate({
  required int sampleRate,
  required int bufferSize,
  required int oarLayout,
  required double outputMixGainDb,
  required List<MixMeasureElement> elements,
  bool withTraces = false,
}) {
  final dylibPath = EclipsaStudioEngine.dylibPath;
  return Isolate.run(() {
    final bindings = EngineBindings(DynamicLibrary.open(dylibPath));
    final create = bindings.mixRendererCreate;
    final addElement = bindings.mixRendererAddElement;
    final setGain = bindings.mixRendererSetOutputGain;
    final measure = bindings.mixRendererMeasure;
    final destroy = bindings.mixRendererDestroy;

    final handle = create(sampleRate, bufferSize, oarLayout);
    if (handle == nullptr) return null;
    try {
      for (final e in elements) {
        final pathPtr = e.sourceWavPath.toNativeUtf8(allocator: ffi_pkg.malloc);
        Pointer<Int32> routingPtr = nullptr;
        if (e.routing.isNotEmpty) {
          routingPtr = ffi_pkg.malloc<Int32>(e.routing.length);
          routingPtr.asTypedList(e.routing.length).setAll(0, e.routing);
        }
        final int rc;
        try {
          rc = addElement(
            handle,
            pathPtr,
            e.elementId,
            e.elementType,
            e.elementSubType,
            e.channels,
            e.mixGainDb,
            e.headphonesMode,
            e.binauralProfile,
            e.gainDb,
            routingPtr,
            e.routing.length,
            e.padToFrames,
            e.outputSampleRate,
          );
        } finally {
          ffi_pkg.malloc.free(pathPtr);
          if (routingPtr != nullptr) ffi_pkg.malloc.free(routingPtr);
        }
        if (rc != 0) return null;
        // Object elements need their polar position(s) or they render
        // (and therefore measure) as silence on loudspeaker layouts.
        if (e.elementType == 2) {
          bindings.mixRendererSetObjectPosition(
            handle,
            e.elementId,
            e.numObjects,
            e.azimuth,
            e.elevation,
            e.distance,
            e.azimuth2,
            e.elevation2,
            e.distance2,
          );
        }
      }
      setGain(handle, outputMixGainDb);

      final MixMeasureResult scalars;
      final lufs = ffi_pkg.malloc.allocate<Float>(sizeOf<Float>());
      final tp = ffi_pkg.malloc.allocate<Float>(sizeOf<Float>());
      final dp = ffi_pkg.malloc.allocate<Float>(sizeOf<Float>());
      try {
        // A failed measure must fail the pass: the out values are not
        // written on error, and treating them as data would ship a
        // bogus -120 LUFS into exported loudness metadata.
        if (measure(handle, lufs, tp, dp) != 0) return null;
        scalars = (
          integratedLufs: lufs.value.toDouble(),
          truePeakDbtp: tp.value.toDouble(),
          digitalPeakDbfs: dp.value.toDouble(),
        );
      } finally {
        ffi_pkg.malloc.free(lufs);
        ffi_pkg.malloc.free(tp);
        ffi_pkg.malloc.free(dp);
      }
      // Pull per-element overload stats (cheap scalars, so always —
      // the export gate needs them regardless of traces).
      final clipStats = <int, ElementClipStats>{};
      final clippedPtr = ffi_pkg.malloc.allocate<Uint64>(sizeOf<Uint64>());
      final peakPtr = ffi_pkg.malloc.allocate<Float>(sizeOf<Float>());
      try {
        for (final e in elements) {
          final rc = bindings.mixRendererElementClipStats(
            handle,
            e.elementId,
            clippedPtr,
            peakPtr,
          );
          if (rc == 0) {
            clipStats[e.elementId] = ElementClipStats(
              clippedSamples: clippedPtr.value,
              peakLinear: peakPtr.value.toDouble(),
            );
          }
        }
      } finally {
        ffi_pkg.malloc.free(clippedPtr);
        ffi_pkg.malloc.free(peakPtr);
      }

      if (!withTraces) {
        return MixMeasureOutcome(scalars: scalars, elementClipStats: clipStats);
      }

      // Copy each series out of the renderer into an isolate-sendable
      // Float32List (caller-allocated native scratch, freed before
      // return — no ownership crosses the FFI).
      Float32List copySeries(int series) {
        final len = bindings.mixRendererTraceLen(handle, series);
        if (len == 0) return Float32List(0);
        final buf = ffi_pkg.malloc.allocate<Float>(len * sizeOf<Float>());
        try {
          final copied = bindings.mixRendererCopyTrace(
            handle,
            series,
            buf,
            len,
          );
          return Float32List.fromList(buf.asTypedList(copied));
        } finally {
          ffi_pkg.malloc.free(buf);
        }
      }

      double? lraLu;
      var lraStable = false;
      final lra = ffi_pkg.malloc.allocate<Float>(sizeOf<Float>());
      final stable = ffi_pkg.malloc.allocate<Int32>(sizeOf<Int32>());
      try {
        if (bindings.mixRendererLoudnessRange(handle, lra, stable) == 0) {
          lraLu = lra.value.toDouble();
          lraStable = stable.value != 0;
        }
      } finally {
        ffi_pkg.malloc.free(lra);
        ffi_pkg.malloc.free(stable);
      }

      return MixMeasureOutcome(
        scalars: scalars,
        elementClipStats: clipStats,
        traces: MixMeasureTraces(
          momentaryLufs: copySeries(_kTraceMomentaryLufs),
          shortTermLufs: copySeries(_kTraceShortTermLufs),
          shortTermPeakDbfs: copySeries(_kTraceShortTermPeakDbfs),
          shortTermPsrDb: copySeries(_kTraceShortTermPsrDb),
          limiterGrDb: copySeries(_kTraceLimiterGrDb),
          loudnessRangeLu: lraLu,
          lraStable: lraStable,
        ),
      );
    } finally {
      destroy(handle);
    }
  });
}
