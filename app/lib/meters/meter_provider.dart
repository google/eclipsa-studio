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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi_bridge.dart';
import '../logging/log.dart';

/// Why the native engine could not be brought up. Each kind has a
/// different audience and remedy, surfaced by `EngineUnavailableScreen`.
enum EngineFailureKind {
  /// The dylib could not be opened at all — missing file in a source
  /// checkout, or a damaged installation of the packaged app.
  libraryNotLoaded,

  /// The dylib loaded but failed the API-version handshake
  /// ([StaleEngineLibraryException]) — rebuild via `./build.sh run`.
  staleLibrary,

  /// The library is fine but `eclipsa_studio_engine_init()` returned an error.
  initFailed,
}

/// Outcome of attempting to load and initialize the native engine:
/// either a live [engine] or a [failure] describing why there isn't one.
///
/// Invariant: exactly one of [engine] and [failure] is non-null, and
/// [failureDetail] is non-null iff [failure] is. Only the two named
/// constructors can establish this — keep it that way.
@immutable
class EngineLoadResult {
  const EngineLoadResult.success(EclipsaStudioEngine this.engine)
    : failure = null,
      failureDetail = null;

  const EngineLoadResult.failure(
    EngineFailureKind this.failure,
    String this.failureDetail,
  ) : engine = null;

  final EclipsaStudioEngine? engine;
  final EngineFailureKind? failure;

  /// Underlying error text (dlopen message, version mismatch, rc).
  final String? failureDetail;
}

/// Singleton attempt to load and initialize the native engine.
///
/// The app is not operational without the engine: when this holds a
/// failure, `EclipsaStudioApp` replaces the whole workspace with
/// `EngineUnavailableScreen`.
final engineLoadProvider = Provider<EngineLoadResult>((ref) {
  try {
    Log.d(LogCat.engine, 'Creating EclipsaStudioEngine...');
    final engine = EclipsaStudioEngine();
    final rc = engine.init();
    Log.d(LogCat.engine, 'engine.init() returned rc=$rc');
    if (rc != 0) {
      Log.e(LogCat.engine, 'Engine init failed (rc=$rc)');
      unawaited(engine.shutdown());
      return EngineLoadResult.failure(
        EngineFailureKind.initFailed,
        'eclipsa_studio_engine_init() returned rc=$rc',
      );
    }
    final meterState = engine.getMeterState();
    Log.d(
      LogCat.engine,
      'Engine ready: ${engine.version()}, '
      'meterState=${meterState == nullptr ? "null" : "non-null"}',
    );
    Log.i(LogCat.engine, 'Engine initialized: ${engine.version()}');
    ref.onDispose(() => unawaited(engine.shutdown()));
    return EngineLoadResult.success(engine);
  } on StaleEngineLibraryException catch (e) {
    Log.e(LogCat.engine, 'Stale engine library rejected: $e');
    return EngineLoadResult.failure(EngineFailureKind.staleLibrary, '$e');
  } on Object catch (e) {
    // Deliberately broader than the stale-library clause above: dlopen
    // failures surface as ArgumentError, and anything else unexpected
    // during construction also means "no usable library".
    Log.d(LogCat.engine, 'Engine unavailable: ${e.runtimeType}: $e');
    Log.w(
      LogCat.engine,
      'C++ engine not available — use '
      '${Platform.isWindows ? r'.\build.ps1 run' : './build.sh run'}',
      e,
    );
    return EngineLoadResult.failure(EngineFailureKind.libraryNotLoaded, '$e');
  }
});

/// Singleton Riverpod provider for the native [EclipsaStudioEngine].
///
/// Null when the engine failed to load ([engineLoadProvider] holds the
/// reason). The workspace is unreachable in that state, but consumers
/// keep their null guards as defense-in-depth against transient nulls.
final eclipsaStudioEngineProvider = Provider<EclipsaStudioEngine?>(
  (ref) => ref.watch(engineLoadProvider).engine,
);
