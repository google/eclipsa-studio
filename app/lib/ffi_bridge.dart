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

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:ffi/ffi.dart' show calloc;

import 'ffi/engine_bindings.dart';
import 'logging/log.dart';
import 'renderer/element_stats.dart';

// ---------------------------------------------------------------------------
// Constants — must match ECLIPSA_STUDIO_MAX_* in eclipsa_studio_engine.h
// ---------------------------------------------------------------------------

const int eclipsaStudioMaxElements = 28;
const int eclipsaStudioMaxChannelsPerElement = 28;

/// Visualizer-stats pairwise correlation cap. Must match
/// `kStatsCorrMaxChannels` in meter_state.h.
const int kStatsCorrMaxChannels = 16;

/// Number of packed upper-triangular correlation pairs.
const int kStatsCorrPairs =
    kStatsCorrMaxChannels * (kStatsCorrMaxChannels - 1) ~/ 2; // 120

// ---------------------------------------------------------------------------
// FFI struct mirrors
//
// Field order and types mirror the C structs exactly so the Dart FFI runtime
// computes the same ABI layout (including alignment padding).
// ---------------------------------------------------------------------------

/// Mirrors `EclipsaStudioMeterData` in meters/meter_state.h.
///
/// Layout (no padding needed — all fields 4-byte aligned):
///   channel_count   :    4 B
///   peak[28]        :  112 B
///   rms[28]         :  112 B
///   peak_hold[28]   :  112 B
///   clip[28]        :   28 B
///   sh_snapshot[28] :  112 B
///   stats_energy[28]:  112 B
///   stats_coh_lo    :  112 B
///   stats_coh_mid   :  112 B
///   stats_coh_hi    :  112 B
///   stats_onset[28] :   28 B
///   stats_pad[4]    :    4 B
///   stats_corr[120] :  480 B
///   total           : 1440 B
final class EclipsaStudioMeterData extends Struct {
  @Uint32()
  external int channelCount;

  @Array(28)
  external Array<Float> peak;

  @Array(28)
  external Array<Float> rms;

  @Array(28)
  external Array<Float> peakHold;

  @Array(28)
  external Array<Uint8> clip;

  /// SH active intensity — mean(W * ch_c) per channel.
  /// Preserves spatial direction for ambisonic elements.
  @Array(28)
  external Array<Float> shSnapshot;

  /// Short-window linear power per channel (EMA-smoothed). Primary
  /// visualizer input — feeds energy_shell, wavefronts, etc.
  @Array(28)
  external Array<Float> statsEnergy;

  /// Coherence against the element sum, per channel, 3 bands (|γ|²∈0..1).
  @Array(28)
  external Array<Float> statsCohLo;
  @Array(28)
  external Array<Float> statsCohMid;
  @Array(28)
  external Array<Float> statsCohHi;

  /// Transient onset flag per channel (1 = onset in hold window).
  @Array(28)
  external Array<Uint8> statsOnset;

  /// Padding to 4-byte align the correlation array.
  @Array(4)
  external Array<Uint8> statsPad;

  /// Upper-triangular Pearson correlation, packed row-major. Only pairs
  /// within the first `kStatsCorrMaxChannels` channels are updated.
  @Array(120)
  external Array<Float> statsCorr;
}

/// Helper — index into [EclipsaStudioMeterData.statsCorr] for channel pair
/// (i, j) with i < j. Mirrors `pair_index()` in channel_stats.cc.
int statsCorrIndex(int i, int j) {
  if (i > j) {
    final t = i;
    i = j;
    j = t;
  }
  if (i == j || i < 0 || j >= kStatsCorrMaxChannels) return -1;
  const n = kStatsCorrMaxChannels;
  return i * (2 * n - i - 1) ~/ 2 + (j - i - 1);
}

/// Mirrors `EclipsaStudioLoudnessData` in eclipsa_studio_engine.h.
final class EclipsaStudioLoudnessData extends Struct {
  @Float()
  external double lufsMomentary;

  @Float()
  external double lufsShortTerm;

  @Float()
  external double lufsIntegrated;

  @Float()
  external double truePeak;
}

/// Mirrors `EclipsaStudioMeterState` in meters/meter_state.h.
///
/// Note: the C compiler inserts 4 B of alignment padding between
/// element_count (uint32_t) and frame_counter (uint64_t).  Dart FFI
/// follows the same platform ABI, so the layout matches automatically.
final class EclipsaStudioMeterState extends Struct {
  @Uint32()
  external int elementCount;

  @Uint64()
  external int frameCounter;

  @Array(28)
  external Array<EclipsaStudioMeterData> elements;

  external EclipsaStudioLoudnessData loudness;

  /// Limiter gain reduction (linear). 1.0 = no reduction.
  @Float()
  external double limiterGr;

  /// Audio thread CPU load (0.0–1.0), smoothed by the engine.
  @Float()
  external double audioCpuLoad;

  // ── Audio-thread health counters (see meter_state.h) ──────────────
  @Uint64()
  external int audioCallbackCount;

  @Uint64()
  external int audioDropoutCount;

  @Uint64()
  external int audioOverrunCount;

  // Field order must mirror EclipsaStudioMeterState in meter_state.h exactly —
  // sizeof assertions do not catch reordering, only total size changes.
  @Uint64()
  external int lastDropoutCb;

  @Float()
  external double lastDropoutBehindMs;

  @Float()
  external double lastDropoutPeriodMs;

  @Uint64()
  external int lastOverrunCb;

  @Float()
  external double lastOverrunElapsedMs;

  @Float()
  external double lastOverrunPeriodMs;

  // IAMF ring underruns — the audio thread read short from an
  // element's PCM ring without EOF (decode pump fell behind).
  @Uint64()
  external int ringUnderrunCount;

  @Uint64()
  external int ringUnderrunFrames;

  @Uint32()
  external int lastUnderrunElement;

  @Uint32()
  external int lastUnderrunMissing;
}

/// Snapshot of audio-thread health counters read from shared memory.
///
/// Values are monotonic across the lifetime of the audio device and
/// reset only when the device is re-opened.  Compare successive
/// snapshots to detect new dropout / overrun events.
class AudioDiagnostics {
  final int callbackCount;
  final int dropoutCount;
  final int overrunCount;
  final int underrunCount;
  final int underrunFrames;
  final int lastDropoutCb;
  final int lastOverrunCb;
  final int lastUnderrunElement;
  final int lastUnderrunMissing;
  final double lastDropoutBehindMs;
  final double lastDropoutPeriodMs;
  final double lastOverrunElapsedMs;
  final double lastOverrunPeriodMs;
  final double cpuLoad;

  const AudioDiagnostics({
    required this.callbackCount,
    required this.dropoutCount,
    required this.overrunCount,
    required this.underrunCount,
    required this.underrunFrames,
    required this.lastDropoutCb,
    required this.lastOverrunCb,
    required this.lastUnderrunElement,
    required this.lastUnderrunMissing,
    required this.lastDropoutBehindMs,
    required this.lastDropoutPeriodMs,
    required this.lastOverrunElapsedMs,
    required this.lastOverrunPeriodMs,
    required this.cpuLoad,
  });

  static const empty = AudioDiagnostics(
    callbackCount: 0,
    dropoutCount: 0,
    overrunCount: 0,
    underrunCount: 0,
    underrunFrames: 0,
    lastDropoutCb: 0,
    lastOverrunCb: 0,
    lastUnderrunElement: 0,
    lastUnderrunMissing: 0,
    lastDropoutBehindMs: 0.0,
    lastDropoutPeriodMs: 0.0,
    lastOverrunElapsedMs: 0.0,
    lastOverrunPeriodMs: 0.0,
    cpuLoad: 0.0,
  );
}

// ---------------------------------------------------------------------------
// AudioDeviceInfo — Dart representation of a native audio device
// ---------------------------------------------------------------------------

/// Detailed info about an enumerated audio output device.
///
/// The engine's C API also exposes per-device supported sample-rate and
/// channel-count lists; they are not mirrored here since the app stopped
/// consuming them when the rate selector was removed (ES-33).
class AudioDeviceInfo {
  final int index;
  final String name;
  final bool isDefault;
  final int maxChannels;

  const AudioDeviceInfo({
    required this.index,
    required this.name,
    required this.isDefault,
    required this.maxChannels,
  });
}

// ---------------------------------------------------------------------------
// Playback mode (IAMF streaming) — mirrors engine/engine.h structs
// ---------------------------------------------------------------------------

/// Mirrors `EclipsaStudioPlaybackAe` in engine.h.
final class _NativePlaybackAe extends Struct {
  @Uint32()
  external int audioElementId;

  @Int32()
  external int kind;

  @Uint32()
  external int numChannels;

  @Int32()
  external int layoutInfo;
}

/// Mirrors `EclipsaStudioPlaybackOpenResult` in engine.h.
final class _NativePlaybackOpenResult extends Struct {
  @Int32()
  external int status;

  external Pointer<ffi_pkg.Utf8> errorMessage;

  @Uint32()
  external int sampleRate;

  @Uint64()
  external int totalFrames;

  @Uint32()
  external int numAudioElements;

  external Pointer<_NativePlaybackAe> audioElements;
}

/// Kind of Audio Element in a Playback session.
enum PlaybackAeKind { channelBased, sceneBased, objectBased, unknown }

PlaybackAeKind _mapPlaybackAeKind(int k) => switch (k) {
  0 => PlaybackAeKind.channelBased,
  1 => PlaybackAeKind.sceneBased,
  2 => PlaybackAeKind.objectBased,
  _ => PlaybackAeKind.unknown,
};

/// One Audio Element as reported by the engine after opening a
/// playback session. Fields are immutable post-open.
class PlaybackAe {
  const PlaybackAe({
    required this.audioElementId,
    required this.kind,
    required this.numChannels,
    required this.layoutInfo,
  });

  final int audioElementId;
  final PlaybackAeKind kind;
  final int numChannels;
  // For channel AEs this is the upstream `OutputLayout` enum value; for
  // scene AEs it's the ambisonics order; object AEs are unsupported in
  // Phase A so this field isn't consumed then.
  final int layoutInfo;
}

/// Value type returned by [EclipsaStudioEngine.playbackOpen]. On success
/// [ok] is true and the descriptor fields are populated; on failure
/// [errorMessage] carries an upstream-prefixed reason.
class PlaybackOpenResult {
  const PlaybackOpenResult({
    required this.ok,
    required this.errorMessage,
    required this.sampleRate,
    required this.totalFrames,
    required this.audioElements,
  });

  const PlaybackOpenResult.error(String message)
    : ok = false,
      errorMessage = message,
      sampleRate = 0,
      totalFrames = 0,
      audioElements = const [];

  final bool ok;
  final String? errorMessage;
  final int sampleRate;
  final int totalFrames;
  final List<PlaybackAe> audioElements;
}

/// Mirrors `EclipsaStudioPlaybackStatus` in engine.h.
final class _NativePlaybackStatus extends Struct {
  @Int32()
  external int sessionOpen;

  @Int32()
  external int scanComplete;

  @Int32()
  external int totalSamplesReady;

  @Uint64()
  external int totalFrames;
}

/// Snapshot of the upstream lazy temporal-unit scan state for the
/// currently-open IAMF playback session. While a lazy scan is in flight
/// `totalFrames` is 0 and the timeline duration is unknown; the tick
/// loop polls this until [totalSamplesReady] flips, then refreshes the
/// transport.
class PlaybackStatus {
  const PlaybackStatus({
    required this.sessionOpen,
    required this.scanComplete,
    required this.totalSamplesReady,
    required this.totalFrames,
  });

  static const PlaybackStatus closed = PlaybackStatus(
    sessionOpen: false,
    scanComplete: false,
    totalSamplesReady: false,
    totalFrames: 0,
  );

  final bool sessionOpen;
  final bool scanComplete;
  final bool totalSamplesReady;
  final int totalFrames;
}

// ---------------------------------------------------------------------------
// C++ log callback — routes engine log messages to Dart Log system
// ---------------------------------------------------------------------------

/// Native function type for the log callback.
typedef _NativeLogCallback =
    Void Function(Int32, Pointer<ffi_pkg.Utf8>, Pointer<ffi_pkg.Utf8>);

// ---------------------------------------------------------------------------
// EclipsaStudioEngine — Dart facade over the native library
// ---------------------------------------------------------------------------

/// Thrown by the [EclipsaStudioEngine] constructor when the dylib loads but
/// its `eclipsa_studio_api_version` differs from (or predates) what these
/// bindings were compiled against. The FFI surface of such a library
/// is unverified — struct layouts or signatures may not match — so it
/// is rejected outright instead of risking subtle memory corruption.
class StaleEngineLibraryException implements Exception {
  const StaleEngineLibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// FFI bridge to the Eclipsa Studio C++ audio engine.
///
/// Build via `./build.sh run`, which runs Bazel and copies the dylib
/// to engine/build/.
class EclipsaStudioEngine {
  /// Log callback delivering C++ log messages into [Log]. Only ever
  /// invoked from eclipsa_studio_rt_log_drain() on this isolate's thread —
  /// engine threads stage messages in a lock-free ring instead of
  /// calling it directly (a NativeCallable invoked from a thread of
  /// another isolate group, e.g. the video pop-out's decoder worker,
  /// aborts the process in the Dart VM).
  late final NativeCallable<_NativeLogCallback> _logCallable;

  /// Drains the C++ log ring even when no session is open (the
  /// AppShell tick loop also drains every frame, but it only exists
  /// inside a workspace — without this timer, engine logs emitted on
  /// the landing screen would never reach the log file).
  Timer? _logDrainTimer;

  late final DynamicLibrary _lib;

  // --- Existing bindings ---
  late final int Function(int, int) _add;
  late final Pointer<ffi_pkg.Utf8> Function() _version;

  // --- Lifecycle bindings ---
  late final int Function(int, int) _engineInit;
  late final void Function() _engineShutdown;
  late final void Function(Pointer<NativeFunction<_NativeLogCallback>>)
  _setLogCallback;
  late final void Function() _rtLogDrain;

  // --- Element bindings ---
  late final int Function(Pointer<ffi_pkg.Utf8>, int) _elementAdd;
  late final void Function(int) _elementRemove;
  late final int Function(Pointer<Uint32>, int) _elementIds;
  late final void Function(int, double) _elementSetGain;
  late final void Function(int, int) _elementSetMute;
  late final void Function(int, int) _elementSetSolo;
  late final void Function(int, int) _elementSetMixExcluded;
  late final void Function(int, double) _elementSetMixGain;
  late final void Function(
    int,
    int,
    double,
    double,
    double,
    double,
    double,
    double,
  )
  _elementSetObjectPosition;
  late final void Function(int, Pointer<Int8>, int) _elementSetInputRouting;
  late final void Function(double) _setOutputMixGain;
  late final void Function(int, double) _elementSeedMixGain;
  late final void Function(double) _seedOutputMixGain;
  late final void Function(int) _setMonitorDim;

  // --- Transport bindings ---
  late final void Function() _transportPlay;
  late final void Function() _transportPause;
  late final void Function(double) _transportSeek;
  late final int Function() _transportGetPositionFrames;
  late final int Function() _transportIsAudioThreadRunning;

  // --- Playback (IAMF streaming) bindings ---
  late final Pointer<_NativePlaybackOpenResult> Function(Pointer<ffi_pkg.Utf8>)
  _playbackOpen;
  late final void Function(Pointer<_NativePlaybackOpenResult>)
  _playbackOpenResultFree;
  late final void Function() _playbackClose;
  late final void Function(int) _playbackUseStreamGains;
  late final _NativePlaybackStatus Function() _playbackStatus;

  // --- Meter bindings ---
  late final Pointer<EclipsaStudioMeterState> Function() _getMeterState;
  late final void Function() _meterReset;
  late final void Function() _meterResetLevels;
  late final void Function() _meterResetClips;

  // --- Audio device bindings ---
  late final int Function() _deviceCount;
  late final Pointer<ffi_pkg.Utf8> Function(int) _deviceName;
  late final Pointer<ffi_pkg.Utf8> Function(int) _deviceChannelName;
  late final int Function() _devicesRefresh;
  late final int Function(int) _deviceMaxChannels;
  late final int Function(int) _deviceIsDefault;
  late final int Function() _currentSampleRate;
  late final int Function() _deviceHardwareSampleRate;
  late final int Function() _currentBufferSize;
  late final int Function() _currentDeviceIndex;
  late final int Function(int, int, int) _engineReconfigure;
  late final Pointer<ffi_pkg.Utf8> Function() _lastDeviceError;
  late final void Function(Pointer<ffi_pkg.Utf8>) _stringFree;
  late final int Function() _getFrameCounter;
  late final int Function(Pointer<Float>, int) _getOutputPeaks;
  late final int Function(Pointer<Float>, int) _getOutputRms;
  late final int Function(Pointer<Uint8>, int) _getOutputClips;
  late final int Function(int, int, int, int) _elementSetType;
  late final int Function(int, int, int) _elementSetRenderingConfig;
  late final int Function() _commitRenderingConfig;
  late final int Function(int) _monitoringSetLayout;
  late final int Function(Pointer<Uint64>, int) _monitoringSetRouting;
  late final int Function(int, Pointer<Uint64>, int)
  _monitoringSetLayoutAndRouting;
  late final int Function(int, int, double) _monitoringSetNoise;
  late final void Function(int) _setChannelStatsEnabled;
  late final void Function(int) _engineSetExportPaused;

  // --- Shared engine bindings (lib/ffi/engine_bindings.dart) ---
  //
  // Symbols whose signatures are shared with worker isolates are bound
  // once in [EngineBindings]; the facade methods below delegate to it
  // so each signature is defined in exactly one place. Lazily created,
  // and each binding is itself a lazy lookup.
  late final EngineBindings _bindings = EngineBindings(_lib);

  // --- SH decode bindings (resolved lazily — dylib may predate
  //     the sh_decode module) ---
  Pointer<Void> Function(int, Pointer<Float>, Pointer<Float>, int, int)?
  _shDecoderCreate;
  void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>)? _shDecode;
  void Function(Pointer<Void>)? _shDecoderDestroy;
  bool _shDecodeResolved = false;

  EclipsaStudioEngine() {
    _lib = _loadLibrary();

    _add = _lib
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'eclipsa_studio_add',
        );
    _version = _lib
        .lookupFunction<
          Pointer<ffi_pkg.Utf8> Function(),
          Pointer<ffi_pkg.Utf8> Function()
        >('eclipsa_studio_version');
    // Guard against a stale dylib: the engine declares its FFI surface
    // a versioned API (ECLIPSA_STUDIO_ENGINE_API_VERSION in engine.h). A
    // mismatch means struct layouts or signatures may differ from what
    // these bindings assume, so the library cannot be trusted — refuse
    // it rather than run with an unverified FFI surface. A dylib so
    // old it lacks the symbol entirely is the strongest possible
    // mismatch, so resolve it optionally (the same pattern as
    // _resolveShDecode) instead of letting lookupFunction throw.
    // 0 when the dylib predates eclipsa_studio_api_version entirely.
    var engineApiVersion = 0;
    try {
      final apiVersionFn = _lib
          .lookupFunction<Int32 Function(), int Function()>(
            'eclipsa_studio_api_version',
          );
      engineApiVersion = apiVersionFn();
    } on ArgumentError {
      engineApiVersion = 0; // symbol absent — pre-versioning dylib
    }
    if (engineApiVersion != kExpectedEngineApiVersion) {
      final found = engineApiVersion == 0
          ? 'no eclipsa_studio_api_version symbol'
          : '$engineApiVersion';
      final buildCmd = Platform.isWindows ? r'.\build.ps1' : './build.sh';
      throw StaleEngineLibraryException(
        'engine API version mismatch: library has $found, bindings '
        'expect $kExpectedEngineApiVersion; rebuild with $buildCmd',
      );
    }

    _engineInit = _lib
        .lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>(
          'eclipsa_studio_engine_init',
        );
    _engineShutdown = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_engine_shutdown',
    );
    _setLogCallback = _lib
        .lookupFunction<
          Void Function(Pointer<NativeFunction<_NativeLogCallback>>),
          void Function(Pointer<NativeFunction<_NativeLogCallback>>)
        >('eclipsa_studio_set_log_callback');
    _rtLogDrain = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_rt_log_drain',
    );

    // Register Dart log callback so C++ messages flow through Log.
    // C++ never invokes it directly: engine_log()/engine_log_rt() stage
    // messages in a lock-free ring and eclipsa_studio_rt_log_drain() — called
    // only from this isolate — forwards them through this callback.
    _logCallable = NativeCallable<_NativeLogCallback>.listener((
      int level,
      Pointer<ffi_pkg.Utf8> category,
      Pointer<ffi_pkg.Utf8> message,
    ) {
      // The drain in engine_log.cc heap-allocates copies of both
      // strings with the engine's CRT malloc (see safe_strdup), so
      // they must be released with the engine's own free —
      // eclipsa_studio_string_free — never package:ffi's malloc.free, which
      // maps to CoTaskMemFree on Windows and corrupts the heap when
      // handed CRT-malloc'd memory (ES-353).
      final cat = category.toDartString();
      final msg = message.toDartString();
      _stringFree(category);
      _stringFree(message);
      switch (level) {
        case 1:
          Log.i(cat, msg);
        case 2:
          Log.w(cat, msg);
        case 3:
          Log.e(cat, msg);
        default:
          Log.d(cat, msg);
      }
    });
    _setLogCallback(_logCallable.nativeFunction);
    // Baseline drain cadence — keeps logs flowing on the landing screen
    // and other states without a tick loop. The AppShell ticker also
    // drains every frame for lower latency during a session; both run
    // on this isolate's event loop, so the ring's single-consumer
    // contract holds.
    _logDrainTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _rtLogDrain(),
    );

    _elementAdd = _lib
        .lookupFunction<
          Int32 Function(Pointer<ffi_pkg.Utf8>, Uint32),
          int Function(Pointer<ffi_pkg.Utf8>, int)
        >('eclipsa_studio_element_add');
    _elementRemove = _lib
        .lookupFunction<Void Function(Uint32), void Function(int)>(
          'eclipsa_studio_element_remove',
        );
    _elementIds = _lib
        .lookupFunction<
          Uint32 Function(Pointer<Uint32>, Uint32),
          int Function(Pointer<Uint32>, int)
        >('eclipsa_studio_element_ids');
    _elementSetGain = _lib
        .lookupFunction<
          Void Function(Uint32, Float),
          void Function(int, double)
        >('eclipsa_studio_element_set_gain');
    _elementSetMute = _lib
        .lookupFunction<Void Function(Uint32, Uint8), void Function(int, int)>(
          'eclipsa_studio_element_set_mute',
        );
    _elementSetSolo = _lib
        .lookupFunction<Void Function(Uint32, Uint8), void Function(int, int)>(
          'eclipsa_studio_element_set_solo',
        );
    _elementSetMixExcluded = _lib
        .lookupFunction<Void Function(Uint32, Uint8), void Function(int, int)>(
          'eclipsa_studio_element_set_mix_excluded',
        );
    _elementSetMixGain = _lib
        .lookupFunction<
          Void Function(Uint32, Float),
          void Function(int, double)
        >('eclipsa_studio_element_set_mix_gain');
    _elementSetObjectPosition = _lib
        .lookupFunction<
          Void Function(
            Uint32,
            Uint32,
            Float,
            Float,
            Float,
            Float,
            Float,
            Float,
          ),
          void Function(
            int,
            int,
            double,
            double,
            double,
            double,
            double,
            double,
          )
        >('eclipsa_studio_element_set_object_position');
    _elementSetInputRouting = _lib
        .lookupFunction<
          Void Function(Uint32, Pointer<Int8>, Uint32),
          void Function(int, Pointer<Int8>, int)
        >('eclipsa_studio_element_set_input_routing');

    _setOutputMixGain = _lib
        .lookupFunction<Void Function(Float), void Function(double)>(
          'eclipsa_studio_set_output_mix_gain',
        );
    _elementSeedMixGain = _lib
        .lookupFunction<
          Void Function(Uint32, Float),
          void Function(int, double)
        >('eclipsa_studio_element_seed_mix_gain');
    _seedOutputMixGain = _lib
        .lookupFunction<Void Function(Float), void Function(double)>(
          'eclipsa_studio_seed_output_mix_gain',
        );
    _setMonitorDim = _lib
        .lookupFunction<Void Function(Int32), void Function(int)>(
          'eclipsa_studio_set_monitor_dim',
        );

    _transportPlay = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_transport_play',
    );
    _transportPause = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_transport_pause',
    );
    _transportSeek = _lib
        .lookupFunction<Void Function(Double), void Function(double)>(
          'eclipsa_studio_transport_seek',
        );
    _transportGetPositionFrames = _lib
        .lookupFunction<Uint64 Function(), int Function()>(
          'eclipsa_studio_transport_get_position_frames',
        );
    _transportIsAudioThreadRunning = _lib
        .lookupFunction<Uint8 Function(), int Function()>(
          'eclipsa_studio_transport_is_audio_thread_running',
        );

    _playbackOpen = _lib
        .lookupFunction<
          Pointer<_NativePlaybackOpenResult> Function(Pointer<ffi_pkg.Utf8>),
          Pointer<_NativePlaybackOpenResult> Function(Pointer<ffi_pkg.Utf8>)
        >('eclipsa_studio_playback_open');
    _playbackOpenResultFree = _lib
        .lookupFunction<
          Void Function(Pointer<_NativePlaybackOpenResult>),
          void Function(Pointer<_NativePlaybackOpenResult>)
        >('eclipsa_studio_playback_open_result_free');
    _playbackClose = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_playback_close',
    );
    _playbackUseStreamGains = _lib
        .lookupFunction<Void Function(Uint8), void Function(int)>(
          'eclipsa_studio_playback_use_stream_gains',
        );
    _playbackStatus = _lib
        .lookupFunction<
          _NativePlaybackStatus Function(),
          _NativePlaybackStatus Function()
        >('eclipsa_studio_playback_status');

    _getMeterState = _lib
        .lookupFunction<
          Pointer<EclipsaStudioMeterState> Function(),
          Pointer<EclipsaStudioMeterState> Function()
        >('eclipsa_studio_get_meter_state');
    _meterReset = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_meter_reset',
    );
    _meterResetLevels = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_meter_reset_levels',
    );
    _meterResetClips = _lib.lookupFunction<Void Function(), void Function()>(
      'eclipsa_studio_meter_reset_clips',
    );

    // Audio device bindings.
    _deviceCount = _lib.lookupFunction<Uint32 Function(), int Function()>(
      'eclipsa_studio_device_count',
    );
    _deviceName = _lib
        .lookupFunction<
          Pointer<ffi_pkg.Utf8> Function(Uint32),
          Pointer<ffi_pkg.Utf8> Function(int)
        >('eclipsa_studio_device_name');
    _deviceChannelName = _lib
        .lookupFunction<
          Pointer<ffi_pkg.Utf8> Function(Uint32),
          Pointer<ffi_pkg.Utf8> Function(int)
        >('eclipsa_studio_device_channel_name');
    _devicesRefresh = _lib.lookupFunction<Uint32 Function(), int Function()>(
      'eclipsa_studio_devices_refresh',
    );
    _deviceMaxChannels = _lib
        .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'eclipsa_studio_device_max_channels',
        );
    _deviceIsDefault = _lib
        .lookupFunction<Uint8 Function(Uint32), int Function(int)>(
          'eclipsa_studio_device_is_default',
        );
    _currentSampleRate = _lib.lookupFunction<Uint32 Function(), int Function()>(
      'eclipsa_studio_current_sample_rate',
    );
    _deviceHardwareSampleRate = _lib
        .lookupFunction<Uint32 Function(), int Function()>(
          'eclipsa_studio_device_hardware_sample_rate',
        );
    _currentBufferSize = _lib.lookupFunction<Uint32 Function(), int Function()>(
      'eclipsa_studio_current_buffer_size',
    );
    _currentDeviceIndex = _lib
        .lookupFunction<Uint32 Function(), int Function()>(
          'eclipsa_studio_current_device_index',
        );
    _engineReconfigure = _lib
        .lookupFunction<
          Int32 Function(Uint32, Uint32, Uint32),
          int Function(int, int, int)
        >('eclipsa_studio_engine_reconfigure');
    _lastDeviceError = _lib
        .lookupFunction<
          Pointer<ffi_pkg.Utf8> Function(),
          Pointer<ffi_pkg.Utf8> Function()
        >('eclipsa_studio_last_device_error');
    _stringFree = _lib
        .lookupFunction<
          Void Function(Pointer<ffi_pkg.Utf8>),
          void Function(Pointer<ffi_pkg.Utf8>)
        >('eclipsa_studio_string_free');
    _getFrameCounter = _lib.lookupFunction<Uint64 Function(), int Function()>(
      'eclipsa_studio_get_frame_counter',
    );
    _getOutputPeaks = _lib
        .lookupFunction<
          Uint32 Function(Pointer<Float>, Uint32),
          int Function(Pointer<Float>, int)
        >('eclipsa_studio_get_output_peaks');
    _getOutputRms = _lib
        .lookupFunction<
          Uint32 Function(Pointer<Float>, Uint32),
          int Function(Pointer<Float>, int)
        >('eclipsa_studio_get_output_rms');
    _getOutputClips = _lib
        .lookupFunction<
          Uint32 Function(Pointer<Uint8>, Uint32),
          int Function(Pointer<Uint8>, int)
        >('eclipsa_studio_get_output_clips');
    _elementSetType = _lib
        .lookupFunction<
          Int32 Function(Uint32, Int32, Int32, Uint32),
          int Function(int, int, int, int)
        >('eclipsa_studio_element_set_type');
    _elementSetRenderingConfig = _lib
        .lookupFunction<
          Int32 Function(Uint32, Uint32, Uint32),
          int Function(int, int, int)
        >('eclipsa_studio_element_set_rendering_config');
    _commitRenderingConfig = _lib
        .lookupFunction<Int32 Function(), int Function()>(
          'eclipsa_studio_commit_rendering_config',
        );
    _monitoringSetLayout = _lib
        .lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'eclipsa_studio_monitoring_set_layout',
        );
    _monitoringSetRouting = _lib
        .lookupFunction<
          Int32 Function(Pointer<Uint64>, Uint32),
          int Function(Pointer<Uint64>, int)
        >('eclipsa_studio_monitoring_set_routing');
    _monitoringSetLayoutAndRouting = _lib
        .lookupFunction<
          Int32 Function(Uint32, Pointer<Uint64>, Uint32),
          int Function(int, Pointer<Uint64>, int)
        >('eclipsa_studio_monitoring_set_layout_and_routing');
    _monitoringSetNoise = _lib
        .lookupFunction<
          Int32 Function(Uint32, Uint32, Float),
          int Function(int, int, double)
        >('eclipsa_studio_monitoring_set_noise');
    _setChannelStatsEnabled = _lib
        .lookupFunction<Void Function(Uint8), void Function(int)>(
          'eclipsa_studio_set_channel_stats_enabled',
        );
    _engineSetExportPaused = _lib
        .lookupFunction<Void Function(Uint8), void Function(int)>(
          'eclipsa_studio_engine_set_export_paused',
        );

    // Verify FFI struct sizes match C++ layout. A mismatch here means
    // the Dart mirror structs are out of sync with meter_state.h.
    assert(
      sizeOf<EclipsaStudioMeterData>() == 1440,
      'EclipsaStudioMeterData size mismatch: '
      '${sizeOf<EclipsaStudioMeterData>()}',
    );
    assert(
      sizeOf<EclipsaStudioLoudnessData>() == 16,
      'EclipsaStudioLoudnessData size mismatch: '
      '${sizeOf<EclipsaStudioLoudnessData>()}',
    );
    assert(
      sizeOf<EclipsaStudioMeterState>() == 40440,
      'EclipsaStudioMeterState size mismatch: '
      '${sizeOf<EclipsaStudioMeterState>()}',
    );
    assert(
      sizeOf<EclipsaStudioPeakData>() == 80,
      'EclipsaStudioPeakData size mismatch: ${sizeOf<EclipsaStudioPeakData>()}',
    );
  }

  /// Resolved path to the native library.
  ///
  /// Safe to call from any isolate — used by [peak_isolate.dart] to
  /// open a fresh DynamicLibrary in a child isolate.
  static String get dylibPath => _resolveDylibPath();

  /// Test hook: absolute dylib path override. The default resolution
  /// walks up from `Platform.resolvedExecutable`, which points inside
  /// the Flutter SDK under `flutter test` and never finds the repo's
  /// engine build. FFI-backed tests set this to the built dylib and
  /// reset it in teardown; production never touches it.
  static String? dylibPathOverride;

  static String _resolveDylibPath() {
    final override = dylibPathOverride;
    if (override != null) return override;
    if (Platform.isMacOS) {
      const name = 'libeclipsa_studio_engine.dylib';
      final exe = Platform.resolvedExecutable;
      final macosDir = exe.substring(0, exe.lastIndexOf('/'));

      // Packaged app: .app/Contents/Frameworks/
      final frameworksPath = '$macosDir/../Frameworks/$name';
      if (File(frameworksPath).existsSync()) return frameworksPath;

      // Debug/run: walk up from the executable until we find
      // engine/build/ (works regardless of build output depth).
      var dir = Directory(macosDir);
      while (dir.parent.path != dir.path) {
        final candidate = '${dir.path}/engine/build/$name';
        if (File(candidate).existsSync()) return candidate;
        dir = dir.parent;
      }

      // Fallback: relative to CWD.
      return 'engine/build/$name';
    } else if (Platform.isLinux) {
      return 'engine/build/libeclipsa_studio_engine.so';
    } else if (Platform.isWindows) {
      const name = 'eclipsa_studio_engine.dll';
      final exe = Platform.resolvedExecutable;
      final exeDir = exe.substring(0, exe.lastIndexOf(Platform.pathSeparator));

      // Packaged build: DLL bundled next to eclipsa_studio.exe. Nothing
      // stages it there for in-tree dev builds (neither `flutter run` nor
      // build.ps1's release launch copies it), so this only fires for a
      // future distributed layout; the walk-up below covers dev builds.
      final beside = '$exeDir${Platform.pathSeparator}$name';
      if (File(beside).existsSync()) return beside;

      // Dev builds (`flutter run` and build.ps1 release): walk up from the
      // executable until we find engine/build/ at the repo root.
      var dir = Directory(exeDir);
      while (dir.parent.path != dir.path) {
        final candidate =
            '${dir.path}${Platform.pathSeparator}engine'
            '${Platform.pathSeparator}build${Platform.pathSeparator}$name';
        if (File(candidate).existsSync()) return candidate;
        dir = dir.parent;
      }

      // Last-resort: cwd-relative.
      return 'engine\\build\\$name';
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  static DynamicLibrary _loadLibrary() {
    final path = _resolveDylibPath();
    Log.d(LogCat.engine, 'Dylib: $path');
    if (Platform.isWindows) {
      // eclipsa_studio_engine.dll statically imports libgpac.dll (the MP4
      // muxer's LGPL dependency). The engine is loaded by absolute path, and
      // the Windows loader does NOT search that directory for the engine's own
      // imports — so preload libgpac.dll from beside it by full path. Once it's
      // in the process, the loader binds the engine's import to the
      // already-loaded module by name, no disk search needed. build.ps1 stages
      // libgpac.dll next to the engine DLL (and packaging puts both beside the
      // exe), so it sits in the same dir as `path`.
      final sep = Platform.pathSeparator;
      final cut = path.lastIndexOf(sep);
      if (cut >= 0) {
        final dir = path.substring(0, cut);
        final gpac = '$dir${sep}libgpac.dll';
        if (File(gpac).existsSync()) {
          try {
            DynamicLibrary.open(gpac);
          } catch (e) {
            Log.w(LogCat.engine, 'Preload libgpac.dll failed: $e');
          }
        }
        // eclipsa_studio_engine.dll also statically imports the FFmpeg + dav1d
        // DLLs (the FFmpeg-in-engine video backend's LGPL decode dependency),
        // which build.ps1 stages beside it. Same rationale as libgpac: preload
        // them by full path so the loader binds the engine's imports by name.
        // They carry FFmpeg's version suffix (avcodec-62.dll, ...) and import
        // each other, so glob them and load in a retry-until-stable loop rather
        // than hard-coding names or a dependency order.
        _preloadFfmpegDlls(dir, sep);
      }
    }
    return DynamicLibrary.open(path);
  }

  /// Preload the vendored FFmpeg + dav1d DLLs staged in [dir] so the Windows
  /// loader can resolve eclipsa_studio_engine.dll's static imports (it does not
  /// search the by-absolute-path engine's own directory for them). The DLLs
  /// import one another (e.g. avcodec depends on avutil + libdav1d), so a
  /// single pass in arbitrary order can fail; retry until a full pass loads
  /// nothing new. A missing set (an engine built without the video backend) is
  /// a no-op.
  static void _preloadFfmpegDlls(String dir, String sep) {
    const prefixes = [
      'avutil-',
      'swresample-',
      'swscale-',
      'avcodec-',
      'avformat-',
      'libdav1d',
      // Bundled mingw-w64 runtime the av* DLLs link (build_ffmpeg.ps1 ships
      // these); preloaded first (retry loop) so avutil resolves them.
      'libwinpthread',
      'libgcc_s',
      'libstdc++',
    ];
    final List<String> pending;
    try {
      pending = Directory(dir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path.substring(f.path.lastIndexOf(sep) + 1))
          .where(
            (n) =>
                n.toLowerCase().endsWith('.dll') &&
                prefixes.any((p) => n.toLowerCase().startsWith(p)),
          )
          .toList();
    } on FileSystemException {
      return;
    }
    if (pending.isEmpty) return;
    // Loop until a full pass loads nothing new — that no-progress break is
    // the sole termination condition. (A pass-count bound would race the
    // shrinking list: the counter climbs while `pending.length` drops, and
    // the loop can exit with resolvable DLLs still pending whenever the
    // dependency chain is deeper than the passes remaining.)
    while (pending.isNotEmpty) {
      var loadedAny = false;
      pending.removeWhere((name) {
        try {
          DynamicLibrary.open('$dir$sep$name');
          loadedAny = true;
          return true;
        } catch (_) {
          return false; // deps not loaded yet; retry next pass
        }
      });
      if (!loadedAny) break;
    }
    for (final name in pending) {
      Log.w(LogCat.engine, 'Preload FFmpeg DLL failed: $name');
    }
  }

  // --- Existing public API ---

  /// Test function: returns a + b.
  int add(int a, int b) => _add(a, b);

  /// Returns the engine version string.
  String version() {
    final ptr = _version();
    if (ptr == nullptr) return 'unknown';
    return ptr.toDartString();
  }

  /// ECLIPSA_STUDIO_ENGINE_API_VERSION these bindings were written against —
  /// a YYYYMMDD date stamp, set to today's date together with engine.h
  /// whenever the FFI contract changes (see the API/ABI stability
  /// policy there). Exact-match checked at load; per-version history
  /// lives in git, not here.
  static const int kExpectedEngineApiVersion = 20260903;

  // --- Lifecycle ---

  /// Initialize the engine. Returns 0 on success.
  int init({int sampleRate = 48000, int bufferSize = 512}) =>
      _engineInit(sampleRate, bufferSize);

  /// Guards [shutdown] so it runs once — it may be called from both the
  /// engine-provider `ref.onDispose` and the app's exit handler.
  bool _shutDown = false;

  /// Whether [shutdown] has run. Callers that poll the engine on a
  /// timer check this: the provider keeps handing out this instance
  /// after shutdown, and the FFI entry points do not test
  /// `g_initialized`, so a poll would keep calling into a stopped
  /// engine until the process exits (ES-662).
  bool get isShutDown => _shutDown;

  /// Shut down the engine and release resources.
  ///
  /// Order matters: _engineShutdown() stops the audio thread (which may
  /// still stage log messages), a final drain flushes whatever is left
  /// in the ring, and only then do we unregister the callback and close
  /// the NativeCallable.
  ///
  /// The callable is a `.listener`, so the final drain only *enqueues*
  /// its entries as isolate messages — the Dart closures that log them
  /// and free the native string copies run on a later event-loop turn.
  /// Closing the callable first would drop those messages and leak the
  /// copies (ES-324), so yield one turn before closing. NB: port messages
  /// draining ahead of a zero-delay timer scheduled after them is
  /// observed VM event-loop behavior, not a documented contract; if it
  /// ever changes the failure is benign — the last few shutdown log
  /// lines are dropped and their copies leak into process exit.
  ///
  /// Idempotent: the app exit handler calls (and awaits) this before the
  /// Dart VM tears down (so the audio thread + log NativeCallable are
  /// gone before the VM, cf. issue ES-203), and the provider
  /// `ref.onDispose` may call it again — the second call is a no-op.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    _logDrainTimer?.cancel();
    _engineShutdown();
    _rtLogDrain();
    _setLogCallback(nullptr);
    await Future<void>.delayed(Duration.zero);
    _logCallable.close();
  }

  // --- Elements ---

  /// Add a WAV-backed audio element. Returns 0 on success.
  int addElement(int elementId, String wavPath) {
    final pathPtr = wavPath.toNativeUtf8(allocator: ffi_pkg.malloc);
    try {
      return _elementAdd(pathPtr, elementId);
    } finally {
      ffi_pkg.malloc.free(pathPtr);
    }
  }

  void removeElement(int elementId) => _elementRemove(elementId);

  /// Element ids by engine slot, in slot order — the engine-authoritative
  /// mapping that `engineOrderProvider` mirrors (ES-531). Meter slot `i`
  /// belongs to `elementIds()[i]`.
  List<int> elementIds() {
    const cap = 64; // > kEclipsaStudioMaxElements (28); one over-read is fine.
    final buf = ffi_pkg.calloc<Uint32>(cap);
    try {
      final count = _elementIds(buf, cap);
      return [for (var i = 0; i < count && i < cap; i++) buf[i]];
    } finally {
      ffi_pkg.calloc.free(buf);
    }
  }

  void setElementGain(int elementId, double gainDb) =>
      _elementSetGain(elementId, gainDb);
  void setElementMute(int elementId, bool muted) =>
      _elementSetMute(elementId, muted ? 1 : 0);
  void setElementSolo(int elementId, bool solo) =>
      _elementSetSolo(elementId, solo ? 1 : 0);
  void setElementMixExcluded(int elementId, bool excluded) =>
      _elementSetMixExcluded(elementId, excluded ? 1 : 0);

  /// Set per-element IAMF mix gain. Passed to OAR as element_mix_gain
  /// metadata — semantically different from setElementGain() (which sets
  /// the element's DSP-chain user gain). The engine slew-limits fast
  /// changes and emits a linear ramp to OAR so fader drags and text-
  /// edit commits are click-free.
  void setElementMixGain(int elementId, double gainDb) =>
      _elementSetMixGain(elementId, gainDb);

  /// Set an object element's polar position(s). REQUIRED for object
  /// elements to be audible on loudspeaker monitoring layouts — OAR's
  /// object-to-loudspeaker renderer stays silent until positions
  /// arrive. The engine re-pushes the latest values to OAR every
  /// audio callback, so positions survive renderer rebuilds.
  ///
  /// Azimuth in degrees, IAMF polar convention (positive = left of
  /// front-center); elevation in degrees; distance normalized 0..1.
  /// For dual objects pass `count: 2` and the second triplet;
  /// otherwise the second triplet is ignored.
  void setElementObjectPosition(
    int elementId, {
    required int count,
    required double azimuth,
    required double elevation,
    required double distance,
    double azimuth2 = 0,
    double elevation2 = 0,
    double distance2 = 1,
  }) => _elementSetObjectPosition(
    elementId,
    count,
    azimuth,
    elevation,
    distance,
    azimuth2,
    elevation2,
    distance2,
  );

  /// Set the per-element input channel routing map.
  /// `routing[dest] = src` (src is a WAV channel index, -1 = silence).
  /// `routing == null` or empty clears to identity (engine fast path).
  /// Engine copies the map synchronously; no need to keep the list alive.
  ///
  /// Entries must be in `[-1, eclipsaStudioMaxChannelsPerElement)`. Values
  /// outside that range would truncate when stored as `Int8` and
  /// silently alias to valid src indices (or to `-1` = silence),
  /// corrupting user routing — the assert catches upstream bugs at
  /// the FFI boundary instead of letting them reach the engine.
  void setElementInputRouting(int elementId, List<int>? routing) {
    if (routing == null || routing.isEmpty) {
      _elementSetInputRouting(elementId, Pointer<Int8>.fromAddress(0), 0);
      return;
    }
    assert(() {
      for (final s in routing) {
        if (s < -1 || s >= eclipsaStudioMaxChannelsPerElement) {
          throw StateError(
            'inputRouting entry $s out of range '
            '[-1, $eclipsaStudioMaxChannelsPerElement)',
          );
        }
      }
      return true;
    }());
    final buf = ffi_pkg.malloc.allocate<Int8>(routing.length);
    try {
      buf.asTypedList(routing.length).setAll(0, routing);
      _elementSetInputRouting(elementId, buf, routing.length);
    } finally {
      ffi_pkg.malloc.free(buf);
    }
  }

  /// Set the master/output mix gain for the active mix presentation.
  /// Passed to OAR as group metadata on group 0. Same slew-and-ramp
  /// semantics as setElementMixGain.
  void setOutputMixGain(double gainDb) => _setOutputMixGain(gainDb);

  /// Seed per-element mix gain to its steady-state value without
  /// ramping. Only safe to call while playback is paused (session
  /// load). A freshly loaded project starts at its persisted gains
  /// instead of ramping up from zero, which would pre-play a dip.
  void seedElementMixGain(int elementId, double gainDb) =>
      _elementSeedMixGain(elementId, gainDb);

  /// Seed the master/output mix gain without ramping. Same constraints
  /// as seedElementMixGain.
  void seedOutputMixGain(double gainDb) => _seedOutputMixGain(gainDb);

  /// Monitor DIM (ES-629): a fixed −20 dB cut on the device output,
  /// applied in the engine after the render, the limiter and every
  /// meter tap. Monitor-only: it never reaches the mix, an export or a
  /// measurement. Ramped over 15 ms each way.
  void setMonitorDim(bool engaged) => _setMonitorDim(engaged ? 1 : 0);

  /// Register element IAMF type with OAR renderer.
  /// type: 0=channel, 1=scene, 2=object
  /// subType: oar_layout_t for channel, oar_hoa_t for scene, num_objects for object
  bool setElementType(int elementId, int type, int subType, int channels) =>
      _elementSetType(elementId, type, subType, channels) == 0;

  /// Stage a change to an element's IAMF element_rendering_config —
  /// headphones_rendering_mode and binaural_filter_profile. The change
  /// is not visible to the OAR renderer until [commitRenderingConfig]
  /// is called. Use [stageElementRenderingConfig] + [commitRenderingConfig]
  /// for bulk updates (session load, active-mix switch) to avoid N
  /// rebuilds, and [updateElementRenderingConfig] for single UI
  /// interactions where the stage-and-commit can happen in one call.
  ///
  /// [mode] values: 0 = stereo fallback (channel-based elements only);
  /// 1 = binaural world-locked; 2 = binaural head-locked.
  ///
  /// [profile] values: 0 = AMBIENT; 1 = DIRECT; 2 = REVERBERANT.
  ///
  /// Returns true if the element was tracked by OAR, false if the
  /// element does not exist in the renderer (e.g. stale id).
  bool stageElementRenderingConfig(int elementId, int mode, int profile) =>
      _elementSetRenderingConfig(elementId, mode, profile) == 0;

  /// Commit any staged rendering-config changes by triggering an OAR
  /// instance rebuild. No-op if nothing is dirty. Returns true on
  /// success.
  bool commitRenderingConfig() => _commitRenderingConfig() == 0;

  /// Convenience: stage a rendering-config change for a single element
  /// and immediately commit it. Fine for user-driven UI interactions
  /// (a single dropdown change) — prefer [stageElementRenderingConfig]
  /// followed by a single [commitRenderingConfig] when pushing values
  /// for many elements in a row.
  bool updateElementRenderingConfig(int elementId, int mode, int profile) {
    final ok = stageElementRenderingConfig(elementId, mode, profile);
    if (ok) commitRenderingConfig();
    return ok;
  }

  // --- Transport ---

  void transportPlay() => _transportPlay();
  void transportPause() => _transportPause();
  void transportSeek(double seconds) => _transportSeek(seconds);

  /// Current playhead position in sample frames.
  ///
  /// Advanced by the audio-thread callback during playback; frozen
  /// while paused. Returns 0 if the engine is not initialised.
  /// Performs a lock-free atomic FFI read on every call — cheap but
  /// not free; do not call multiple times per tick.
  int transportPositionFrames() => _transportGetPositionFrames();

  /// Whether the audio thread is running and driving the output device.
  ///
  /// Returns false if the engine is not initialised or the device
  /// failed to open. When false, [transportPositionFrames] will not
  /// advance and should not be treated as ground truth.
  bool get isAudioThreadRunning => _transportIsAudioThreadRunning() != 0;

  /// Last failure message from the audio output device. Empty when the
  /// device is currently running or has never failed to start.
  ///
  /// The native side hands ownership of the returned buffer to us — we
  /// copy it into a Dart `String` and immediately release the C
  /// allocation with `eclipsa_studio_string_free` (matching the engine's own
  /// allocator; `malloc.free` maps to CoTaskMemFree on Windows and
  /// must not be used on CRT-malloc'd memory).
  String get lastDeviceError {
    final ptr = _lastDeviceError();
    if (ptr == nullptr) return '';
    final s = ptr.toDartString();
    _stringFree(ptr);
    return s;
  }

  // --- Playback (IAMF streaming) ---

  /// Open [path] as an IAMF Playback session. Returns a
  /// [PlaybackOpenResult]; native allocations are copied into Dart
  /// and released before returning, so the caller does not manage
  /// lifetime. Reopening replaces the previous session on the engine
  /// side; Dart callers must still dispatch [playbackClose] when the
  /// user returns to the landing screen so transport is released.
  PlaybackOpenResult playbackOpen(String path) {
    final pathPtr = path.toNativeUtf8(allocator: ffi_pkg.malloc);
    Pointer<_NativePlaybackOpenResult> resultPtr;
    try {
      resultPtr = _playbackOpen(pathPtr);
    } finally {
      ffi_pkg.malloc.free(pathPtr);
    }
    if (resultPtr == nullptr) {
      return const PlaybackOpenResult.error(
        'playback_open: native allocation failed',
      );
    }
    try {
      final native = resultPtr.ref;
      if (native.status != 0) {
        final msg = native.errorMessage == nullptr
            ? 'playback_open failed (status ${native.status})'
            : native.errorMessage.toDartString();
        return PlaybackOpenResult.error(msg);
      }
      final aes = <PlaybackAe>[];
      for (var i = 0; i < native.numAudioElements; i++) {
        final n = (native.audioElements + i).ref;
        aes.add(
          PlaybackAe(
            audioElementId: n.audioElementId,
            kind: _mapPlaybackAeKind(n.kind),
            numChannels: n.numChannels,
            layoutInfo: n.layoutInfo,
          ),
        );
      }
      return PlaybackOpenResult(
        ok: true,
        errorMessage: null,
        sampleRate: native.sampleRate,
        totalFrames: native.totalFrames,
        audioElements: aes,
      );
    } finally {
      _playbackOpenResultFree(resultPtr);
    }
  }

  /// Close the current IAMF playback session (if any). Idempotent.
  void playbackClose() => _playbackClose();

  /// Control whether the stream's per-TU mix gains drive each IAMF
  /// element's mix gain (the default after every [playbackOpen]). The
  /// stream reports gains for the decoder's *default* mix presentation
  /// only, so selecting a non-default presentation disables this and
  /// drives [setElementMixGain] instead. Lock-free; safe mid-playback.
  void playbackUseStreamGains(bool enabled) =>
      _playbackUseStreamGains(enabled ? 1 : 0);

  /// Snapshot the lazy-scan state of the open IAMF session.
  ///
  /// `playbackOpen` returns immediately after the upstream descriptor
  /// parse + codec init; the temporal-unit scan that produces the exact
  /// total frame count runs on a worker thread. Until it completes,
  /// `totalFrames` is 0. Poll this from the 60 Hz tick loop and update
  /// the transport once `totalSamplesReady` flips.
  PlaybackStatus playbackStatus() {
    final native = _playbackStatus();
    return PlaybackStatus(
      sessionOpen: native.sessionOpen != 0,
      scanComplete: native.scanComplete != 0,
      totalSamplesReady: native.totalSamplesReady != 0,
      totalFrames: native.totalFrames,
    );
  }

  // --- Meter public API ---

  /// Returns a pointer to the shared [EclipsaStudioMeterState].
  ///
  /// The pointer is valid for the lifetime of the process.  Read fields
  /// directly; do not store the pointer across frames.
  Pointer<EclipsaStudioMeterState> getMeterState() => _getMeterState();

  /// Reset all meter state (peaks, RMS, clip flags, loudness, frame counter).
  void meterReset() => _meterReset();

  /// Like [meterReset], but the sticky clip latches survive — overload
  /// markers must remain visible after a transport stop (ES-528). Use on
  /// the pause path; keep the full reset for context changes (mode
  /// switch, session load).
  void meterResetLevels() => _meterResetLevels();

  /// Reset the engine's sticky per-channel clip flags.
  ///
  /// Safe at any time, including during playback (the engine's zeroing
  /// races benignly with the audio thread's clip stores).
  void meterResetClips() => _meterResetClips();

  // Pools for the two per-frame meter reads below — same rationale as
  // the channel-stats pool: both are called at 60 Hz and used to
  // allocate one inner list per element per call. Inner lists are
  // reused (resized to the element's channel count); the outer result
  // list is reused too. Callers must consume the result synchronously
  // and copy anything they retain across frames.
  late final List<List<double>> _peaksPool = <List<double>>[];
  late final List<List<double>> _peaksResult = <List<double>>[];
  late final List<List<double>> _rmsPool = <List<double>>[];
  late final List<List<double>> _rmsResult = <List<double>>[];
  late final List<List<bool>> _clipsPool = <List<bool>>[];
  late final List<List<bool>> _clipsResult = <List<bool>>[];
  late final List<List<double>> _shPool = <List<double>>[];
  late final List<List<double>> _shResult = <List<double>>[];

  /// Read per-element per-channel instantaneous peak values.
  ///
  /// Returns a `List<List<double>>` where `result[i][ch]` is the linear peak
  /// amplitude (0..1+) for element `i`, channel `ch`. The returned list and
  /// its entries are pool-backed and reused on the next call — consume
  /// synchronously, copy before retaining.
  List<List<double>> readMeterPeaks() {
    _peaksResult.clear();
    final statePtr = getMeterState();
    if (statePtr == nullptr) return _peaksResult;

    final meterState = statePtr.ref;
    final count = meterState.elementCount.clamp(0, eclipsaStudioMaxElements);

    while (_peaksPool.length < count) {
      _peaksPool.add(<double>[]);
    }
    for (var i = 0; i < count; i++) {
      final elem = meterState.elements[i];
      final chCount = elem.channelCount.clamp(
        0,
        eclipsaStudioMaxChannelsPerElement,
      );
      final channels = _peaksPool[i];
      // Growing a non-nullable list via the length setter throws —
      // shrink with the setter, grow with add().
      if (channels.length > chCount) channels.length = chCount;
      while (channels.length < chCount) {
        channels.add(0);
      }
      for (var ch = 0; ch < chCount; ch++) {
        channels[ch] = elem.peak[ch];
      }
      _peaksResult.add(channels);
    }
    return _peaksResult;
  }

  /// Read per-element per-channel RMS levels (short EMA integration,
  /// engine-defined window).
  ///
  /// Returns `result[i][ch]` — the linear RMS amplitude (0..1+) for
  /// element `i`, channel `ch`, from the same tap as [readMeterPeaks].
  /// The returned list and its entries are pool-backed and reused on
  /// the next call — consume synchronously, copy before retaining.
  List<List<double>> readMeterRms() {
    _rmsResult.clear();
    final statePtr = getMeterState();
    if (statePtr == nullptr) return _rmsResult;

    final meterState = statePtr.ref;
    final count = meterState.elementCount.clamp(0, eclipsaStudioMaxElements);

    while (_rmsPool.length < count) {
      _rmsPool.add(<double>[]);
    }
    for (var i = 0; i < count; i++) {
      final elem = meterState.elements[i];
      final chCount = elem.channelCount.clamp(
        0,
        eclipsaStudioMaxChannelsPerElement,
      );
      final channels = _rmsPool[i];
      if (channels.length > chCount) channels.length = chCount;
      while (channels.length < chCount) {
        channels.add(0);
      }
      for (var ch = 0; ch < chCount; ch++) {
        channels[ch] = elem.rms[ch];
      }
      _rmsResult.add(channels);
    }
    return _rmsResult;
  }

  /// Read per-element per-channel sticky clip flags.
  ///
  /// Returns `result[i][ch]` — true if element `i`, channel `ch` has hit
  /// 0 dBFS since the last clip reset. The flags latch engine-side, so
  /// overs between UI frames are never missed. The returned list and its
  /// entries are pool-backed and reused on the next call — consume
  /// synchronously, copy before retaining.
  List<List<bool>> readMeterClips() {
    _clipsResult.clear();
    final statePtr = getMeterState();
    if (statePtr == nullptr) return _clipsResult;

    final meterState = statePtr.ref;
    final count = meterState.elementCount.clamp(0, eclipsaStudioMaxElements);

    while (_clipsPool.length < count) {
      _clipsPool.add(<bool>[]);
    }
    for (var i = 0; i < count; i++) {
      final elem = meterState.elements[i];
      final chCount = elem.channelCount.clamp(
        0,
        eclipsaStudioMaxChannelsPerElement,
      );
      final channels = _clipsPool[i];
      if (channels.length > chCount) channels.length = chCount;
      while (channels.length < chCount) {
        channels.add(false);
      }
      for (var ch = 0; ch < chCount; ch++) {
        channels[ch] = elem.clip[ch] != 0;
      }
      _clipsResult.add(channels);
    }
    return _clipsResult;
  }

  /// Read per-element per-channel signed SH snapshots.
  ///
  /// Returns `result[i][ch]` — the signed block-average for element
  /// `i`, channel `ch`. For scene-based elements these are SH
  /// coefficients in ACN order. The returned list and its entries are
  /// pool-backed and reused on the next call — consume synchronously,
  /// copy before retaining.
  List<List<double>> readShSnapshots() {
    _shResult.clear();
    final statePtr = getMeterState();
    if (statePtr == nullptr) return _shResult;

    final meterState = statePtr.ref;
    final count = meterState.elementCount.clamp(0, eclipsaStudioMaxElements);

    while (_shPool.length < count) {
      _shPool.add(<double>[]);
    }
    for (var i = 0; i < count; i++) {
      final elem = meterState.elements[i];
      final chCount = elem.channelCount.clamp(
        0,
        eclipsaStudioMaxChannelsPerElement,
      );
      final channels = _shPool[i];
      if (channels.length > chCount) channels.length = chCount;
      while (channels.length < chCount) {
        channels.add(0);
      }
      for (var ch = 0; ch < chCount; ch++) {
        channels[ch] = elem.shSnapshot[ch];
      }
      _shResult.add(channels);
    }
    return _shResult;
  }

  // ── Channel-stats read pool ─────────────────────────────────────
  //
  // readElementStats() is called every frame; allocating ~7 typed-data
  // buffers per element at 60 Hz produces measurable GC churn with 28
  // elements. Buffers are lazily grown to the high-water mark and
  // reused — same object identity every frame. The returned list is
  // also reused; callers must not retain entries across frames.
  late final List<ElementStats> _statsPool = <ElementStats>[];
  late final List<ElementStats> _statsResult = <ElementStats>[];

  ElementStats _makeStatsSlot() => ElementStats(
    channelCount: 0,
    energy: Float32List(eclipsaStudioMaxChannelsPerElement),
    cohLo: Float32List(eclipsaStudioMaxChannelsPerElement),
    cohMid: Float32List(eclipsaStudioMaxChannelsPerElement),
    cohHi: Float32List(eclipsaStudioMaxChannelsPerElement),
    onset: Uint8List(eclipsaStudioMaxChannelsPerElement),
    corr: Float32List(kStatsCorrPairs),
  );

  /// Read per-element channel stats (visualizer inputs).
  ///
  /// Returns a pool-backed list of [ElementStats] — the returned list
  /// and its entries are reused on the next call, so callers must
  /// consume them synchronously and not cache the references.
  List<ElementStats> readElementStats() {
    _statsResult.clear();
    final statePtr = getMeterState();
    if (statePtr == nullptr) return _statsResult;

    final meterState = statePtr.ref;
    final count = meterState.elementCount.clamp(0, eclipsaStudioMaxElements);

    while (_statsPool.length < count) {
      _statsPool.add(_makeStatsSlot());
    }

    for (var i = 0; i < count; i++) {
      final elem = meterState.elements[i];
      final slot = _statsPool[i];
      final chCount = elem.channelCount.clamp(
        0,
        eclipsaStudioMaxChannelsPerElement,
      );
      slot.channelCount = chCount;
      for (var c = 0; c < chCount; c++) {
        slot.energy[c] = elem.statsEnergy[c];
        slot.cohLo[c] = elem.statsCohLo[c];
        slot.cohMid[c] = elem.statsCohMid[c];
        slot.cohHi[c] = elem.statsCohHi[c];
        slot.onset[c] = elem.statsOnset[c];
      }
      // Zero the tail so consumers that read past chCount (e.g. HUD
      // snapshots captured mid-frame) don't see stale values from a
      // prior high-channel-count element that occupied this slot.
      for (var c = chCount; c < eclipsaStudioMaxChannelsPerElement; c++) {
        slot.energy[c] = 0;
        slot.cohLo[c] = 0;
        slot.cohMid[c] = 0;
        slot.cohHi[c] = 0;
        slot.onset[c] = 0;
      }
      // Correlation is packed NxN with N=kStatsCorrMaxChannels regardless
      // of this element's channel count — always copy the full block.
      for (var p = 0; p < kStatsCorrPairs; p++) {
        slot.corr[p] = elem.statsCorr[p];
      }
      _statsResult.add(slot);
    }
    return _statsResult;
  }

  /// Read the current loudness data from the shared meter state.
  ///
  /// Returns a named record with LUFS momentary / short-term / integrated
  /// and true peak (all in dB / dBTP).
  ({
    double lufsMomentary,
    double lufsShortTerm,
    double lufsIntegrated,
    double truePeak,
  })
  readLoudness() {
    final statePtr = getMeterState();
    if (statePtr == nullptr) {
      return (
        lufsMomentary: -120.0,
        lufsShortTerm: -120.0,
        lufsIntegrated: -120.0,
        truePeak: -100.0,
      );
    }
    final l = statePtr.ref.loudness;
    return (
      lufsMomentary: l.lufsMomentary,
      lufsShortTerm: l.lufsShortTerm,
      lufsIntegrated: l.lufsIntegrated,
      truePeak: l.truePeak,
    );
  }

  // --- Monitoring / OAR ---

  /// Limiter gain reduction (linear). 1.0 = no reduction.
  double get limiterGr {
    final statePtr = getMeterState();
    if (statePtr == nullptr) return 1.0;
    return statePtr.ref.limiterGr;
  }

  /// Audio thread CPU load (0.0–1.0) from the shared meter state.
  double get audioCpuLoad {
    final statePtr = getMeterState();
    if (statePtr == nullptr) return 0.0;
    return statePtr.ref.audioCpuLoad.clamp(0.0, 1.0);
  }

  /// Forward messages staged in the C++ log ring — all engine_log()
  /// and engine_log_rt() traffic — through the log callback (and on
  /// into the JSONL log file). Cheap when the ring is empty; called
  /// from the tick loop for per-frame latency, with a periodic timer
  /// in this class as the baseline.
  void drainRtLogs() => _rtLogDrain();

  /// Snapshot of audio-thread health counters from shared meter state.
  ///
  /// Returned as a plain Dart object so callers don't hold a pointer
  /// into C++ memory longer than necessary.  Returns [AudioDiagnostics.empty]
  /// if the engine hasn't been initialized.
  AudioDiagnostics readAudioDiagnostics() {
    final statePtr = getMeterState();
    if (statePtr == nullptr) return AudioDiagnostics.empty;
    final s = statePtr.ref;
    return AudioDiagnostics(
      callbackCount: s.audioCallbackCount,
      dropoutCount: s.audioDropoutCount,
      overrunCount: s.audioOverrunCount,
      underrunCount: s.ringUnderrunCount,
      underrunFrames: s.ringUnderrunFrames,
      lastDropoutCb: s.lastDropoutCb,
      lastOverrunCb: s.lastOverrunCb,
      lastUnderrunElement: s.lastUnderrunElement,
      lastUnderrunMissing: s.lastUnderrunMissing,
      lastDropoutBehindMs: s.lastDropoutBehindMs,
      lastDropoutPeriodMs: s.lastDropoutPeriodMs,
      lastOverrunElapsedMs: s.lastOverrunElapsedMs,
      lastOverrunPeriodMs: s.lastOverrunPeriodMs,
      cpuLoad: s.audioCpuLoad.clamp(0.0, 1.0),
    );
  }

  /// Direct frame counter read (bypasses struct FFI alignment issue).
  int get frameCounter => _getFrameCounter();

  /// Read output peak levels (post-OAR render).
  List<double> readOutputPeaks(int maxChannels) {
    final buf = calloc<Float>(maxChannels);
    try {
      final n = _getOutputPeaks(buf, maxChannels);
      return List.generate(n, (i) => buf[i]);
    } finally {
      calloc.free(buf);
    }
  }

  /// Read output RMS levels (post-OAR render, short EMA integration).
  /// Same tap and channel order as [readOutputPeaks].
  List<double> readOutputRms(int maxChannels) {
    final buf = calloc<Float>(maxChannels);
    try {
      final n = _getOutputRms(buf, maxChannels);
      return List.generate(n, (i) => buf[i]);
    } finally {
      calloc.free(buf);
    }
  }

  /// Read the sticky per-output-channel clip flags (latched by the
  /// audio thread at >= 0 dBFS, so overs between UI frames are never
  /// missed). Same channel order as [readOutputPeaks]; cleared via
  /// [meterResetClips] / [meterReset] — but not [meterResetLevels],
  /// which deliberately preserves the latches (ES-528).
  List<bool> readOutputClips(int maxChannels) {
    final buf = calloc<Uint8>(maxChannels);
    try {
      final n = _getOutputClips(buf, maxChannels);
      return List.generate(n, (i) => buf[i] != 0);
    } finally {
      calloc.free(buf);
    }
  }

  /// Set the OAR target layout. Returns true on success.
  /// Use the oar_layout_t enum value (e.g. 2=stereo, 11=binaural).
  bool setLayout(int oarLayoutValue) =>
      _monitoringSetLayout(oarLayoutValue) == 0;

  /// Set the per-OAR-channel device routing. `masks[oarCh]` is a
  /// device-channel bitmask (bit `d` = OAR channel `oarCh` feeds device
  /// channel `d`; 0 = mute). Length must equal the current layout's OAR
  /// channel count; the engine rejects a mismatch. Returns true on success.
  bool setRouting(List<int> masks) {
    // NB: malloc<Uint64>(n) allocates n ELEMENTS (sizeOf<Uint64>()*n bytes).
    // Do NOT use malloc.allocate<Uint64>(n) — that takes a BYTE count, so it
    // would under-allocate 8x and asTypedList().setAll() overflows the heap.
    final buf = ffi_pkg.malloc<Uint64>(masks.length);
    try {
      buf.asTypedList(masks.length).setAll(0, masks);
      return _monitoringSetRouting(buf, masks.length) == 0;
    } finally {
      ffi_pkg.malloc.free(buf);
    }
  }

  /// Atomic layout + routing switch: apply [oarLayoutValue] and its [masks]
  /// as one engine op so the audio thread never hears the new layout paired
  /// with the old routing. Returns true on success.
  bool setLayoutAndRouting(int oarLayoutValue, List<int> masks) {
    // malloc<Uint64>(n) = n elements; see setRouting for why .allocate() is
    // wrong here (byte count -> 8x under-allocation -> heap overflow).
    final buf = ffi_pkg.malloc<Uint64>(masks.length);
    try {
      buf.asTypedList(masks.length).setAll(0, masks);
      return _monitoringSetLayoutAndRouting(
            oarLayoutValue,
            buf,
            masks.length,
          ) ==
          0;
    } finally {
      ffi_pkg.malloc.free(buf);
    }
  }

  /// Set the single pink-noise calibration injection point.
  /// [mode]: 0=off, 1=row (pre-routing, [channel] = OAR output channel),
  /// 2=col (post-routing, [channel] = device channel). [dbfs] is the fixed
  /// reference level. Returns true on success.
  bool setNoise(int mode, int channel, double dbfs) =>
      _monitoringSetNoise(mode, channel, dbfs) == 0;

  /// Tell the engine whether any visualizer module needs per-channel
  /// stats this frame. Off by default — the audio thread skips the
  /// entire stats computation (energy EMA / correlation / coherence /
  /// onsets) when disabled, so inactive visualizers have no real-time
  /// cost.
  void setChannelStatsEnabled(bool enabled) =>
      _setChannelStatsEnabled(enabled ? 1 : 0);

  /// Pause the live audio output for an offline operation (IAMF export).
  /// While paused, the audio thread skips OAR and emits silence — this
  /// keeps the live OarRenderer from running concurrently with the
  /// offline mix renderer's own OAR instances during loudness
  /// measurement, which corrupts the heap (ES-44).
  ///
  /// Pausing blocks until the audio thread has acknowledged so the
  /// caller can safely use alternative OAR instances on return. Always
  /// pair with `setExportPaused(false)` in a `try/finally`.
  ///
  /// Refcounted in the engine (ES-495): overlapping holds nest and the
  /// live OAR resumes at the last release, so every `true` needs its
  /// own `false`. See ES-158 for the race window vs. an in-flight layout
  /// switch.
  void setExportPaused(bool paused) => _engineSetExportPaused(paused ? 1 : 0);

  // --- SH decode ---

  void _resolveShDecode() {
    if (_shDecodeResolved) return;
    _shDecodeResolved = true;
    try {
      _shDecoderCreate = _lib
          .lookupFunction<
            Pointer<Void> Function(
              Uint32,
              Pointer<Float>,
              Pointer<Float>,
              Uint32,
              Uint32,
            ),
            Pointer<Void> Function(
              int,
              Pointer<Float>,
              Pointer<Float>,
              int,
              int,
            )
          >('eclipsa_studio_sh_decoder_create');
      _shDecode = _lib
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>),
            void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>)
          >('eclipsa_studio_sh_decode');
      _shDecoderDestroy = _lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('eclipsa_studio_sh_decoder_destroy');
    } on ArgumentError catch (e) {
      // Partial resolution — reset all pointers so hasShDecode
      // returns false rather than leaving a mix of null/non-null.
      _shDecoderCreate = null;
      _shDecode = null;
      _shDecoderDestroy = null;
      Log.i(
        LogCat.engine,
        'SH decode symbols not found in dylib — '
        'soundfield decode disabled',
        e,
      );
    }
  }

  /// Whether the native SH decoder is available in the loaded dylib.
  bool get hasShDecode {
    _resolveShDecode();
    return _shDecoderCreate != null;
  }

  /// Create an SH decoder for a fixed set of probe directions.
  /// Returns an opaque native handle, or nullptr on failure.
  Pointer<Void> shDecoderCreate(
    Pointer<Float> probeAz,
    Pointer<Float> probeEl,
    int numProbes,
    int order,
    int directivity,
  ) {
    _resolveShDecode();
    if (_shDecoderCreate == null) return nullptr;
    return _shDecoderCreate!(numProbes, probeAz, probeEl, order, directivity);
  }

  /// Decode SH coefficients into per-probe squared energies.
  void shDecode(
    Pointer<Void> decoder,
    Pointer<Float> coeffs,
    Pointer<Float> outEnergies,
  ) {
    _resolveShDecode();
    if (_shDecode == null) return;
    _shDecode!(decoder, coeffs, outEnergies);
  }

  /// Destroy an SH decoder.
  void shDecoderDestroy(Pointer<Void> decoder) {
    _resolveShDecode();
    if (_shDecoderDestroy == null) return;
    _shDecoderDestroy!(decoder);
  }

  // --- Audio device public API ---

  /// Number of enumerated output devices.
  int get deviceCount => _deviceCount();

  /// Name of the device at [index], or empty string if out of range.
  ///
  /// The native side hands ownership of the buffer to us (same
  /// contract as [deviceChannelName]) — copy to a Dart `String`, then
  /// release with `eclipsa_studio_string_free`.
  String deviceName(int index) {
    final ptr = _deviceName(index);
    if (ptr == nullptr) return '';
    final s = ptr.toDartString();
    _stringFree(ptr);
    return s;
  }

  /// Hardware-reported name of output [channel] (0-based) on the open
  /// device — e.g. `Phones 2` on a MOTU MicroBook II. Empty when no
  /// device is open or the backend reports no label (always the case
  /// on Windows/WASAPI); callers must then render exactly as if the
  /// feature didn't exist.
  ///
  /// The native side hands ownership of the buffer to us (same
  /// contract as [lastDeviceError]) — copy to a Dart `String`, then
  /// release with `eclipsa_studio_string_free`.
  String deviceChannelName(int channel) {
    final ptr = _deviceChannelName(channel);
    if (ptr == nullptr) return '';
    final s = ptr.toDartString();
    _stringFree(ptr);
    return s;
  }

  /// Re-enumerate output devices (hot-plug / OS default changes). Safe
  /// while a stream is open; never touches the open device. The engine
  /// remaps its selection by name across the index shift. Returns the
  /// new device count.
  int refreshDevices() => _devicesRefresh();

  /// Build a [List<AudioDeviceInfo>] for all enumerated output devices.
  List<AudioDeviceInfo> getAudioDevices() {
    final count = deviceCount;
    final devices = <AudioDeviceInfo>[];
    for (var i = 0; i < count; i++) {
      final name = deviceName(i);
      devices.add(
        AudioDeviceInfo(
          index: i,
          name: name.isEmpty ? 'Device $i' : name,
          isDefault: _deviceIsDefault(i) != 0,
          maxChannels: _deviceMaxChannels(i),
        ),
      );
    }
    return devices;
  }

  /// Sample rate the engine is currently running at.
  int get currentSampleRate => _currentSampleRate();

  /// Live hardware rate of the open output device — can diverge from
  /// [currentSampleRate] when the user changes the device's rate in
  /// Audio MIDI Setup. 0 when no device is open.
  int get deviceHardwareSampleRate => _deviceHardwareSampleRate();

  /// Buffer size (frames) the engine is currently running with.
  int get currentBufferSize => _currentBufferSize();

  /// Index of the currently selected output device.
  int get currentDeviceIndex => _currentDeviceIndex();

  /// Stop, reconfigure, and restart the audio engine.
  ///
  /// Returns 0 on success.  Pass 0 for [sampleRate] or [bufferSize] to
  /// keep the current value.
  int reconfigure({
    required int deviceIndex,
    required int sampleRate,
    required int bufferSize,
  }) => _engineReconfigure(deviceIndex, sampleRate, bufferSize);

  // --- IAMF export ---

  /// Cancel an in-flight IAMF export. The export itself runs on a
  /// background isolate (see iamf_encode_isolate.dart); the exporter is
  /// process-global, so cancelling here steers that encode. The push
  /// loop honors it once per coded frame and removes the partial output.
  void iamfExportCancel() => _bindings.iamfExportCancel();

  /// Progress of the in-flight IAMF encode in [0, 1] (0 before the
  /// first encode). Written per coded frame by the push loop on the
  /// encode isolate; safe to poll from here — it's a relaxed atomic on
  /// process-global state.
  double iamfExportProgress() => _bindings.iamfExportProgress();

  /// Free space and identity of the volume holding [path], which must
  /// exist (a file or a directory). `freeBytes` is what this process can
  /// use; `volumeId` is the same for every path on one volume, so the
  /// export dialog can tell whether its scratch dir and the destination
  /// share a disk (ES-742). Null when the path does not exist or the OS
  /// query fails. A single statvfs-class call; fine on the UI isolate.
  ({int freeBytes, int volumeId})? volumeInfo(String path) {
    final pathPtr = path.toNativeUtf8(allocator: ffi_pkg.malloc);
    final freePtr = ffi_pkg.malloc<Uint64>();
    final idPtr = ffi_pkg.malloc<Uint64>();
    try {
      final rc = _bindings.fsVolumeInfo(pathPtr, freePtr, idPtr);
      if (rc != 0) return null;
      return (freeBytes: freePtr.value, volumeId: idPtr.value);
    } finally {
      ffi_pkg.malloc.free(pathPtr);
      ffi_pkg.malloc.free(freePtr);
      ffi_pkg.malloc.free(idPtr);
    }
  }
}
