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
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../ffi/engine_bindings.dart';
import '../ffi_bridge.dart' show EclipsaStudioEngine;
import '../logging/log.dart';

// The C ABI mirror ([Adm2iamfRenderConfig], the adm2iamf_* typedefs)
// lives in the shared binding module; re-export the pieces that belong
// to this bridge's public surface (used by [renderStart] callers and
// the ABI-guard test).
export '../ffi/engine_bindings.dart' show Adm2iamfRenderConfig;

// ───────────────────────────────────────────────────────────────────────────
// Dart bridge over the ADM->bed converter's flat C ABI (adm2iamf_*), which is
// linked into the engine library (see engine/adm_import/ffi). The C ABI
// mirror tracks engine/adm_import/ffi/adm2iamf_ffi.h field-for-field.
// ───────────────────────────────────────────────────────────────────────────

/// Job state (`adm2iamf_render_state`).
enum AdmRenderState {
  running(0),
  done(1),
  error(2),
  cancelled(3),
  unknownJob(-1);

  const AdmRenderState(this.value);
  final int value;

  /// Maps a raw C state code to the enum, defaulting to [unknownJob].
  static AdmRenderState fromValue(int v) =>
      values.firstWhere((s) => s.value == v, orElse: () => unknownJob);
}

/// Parameters for one render, mapped to [Adm2iamfRenderConfig] by [renderStart].
/// The engine renders to its fixed 7.1.4 layout as 24-bit PCM at 48 kHz;
/// there is no layout or encoding field.
class AdmRenderRequest {
  final int minImportance;
  final String inPath;
  final String outPath;

  const AdmRenderRequest({
    required this.inPath,
    required this.outPath,
    this.minImportance = 0,
  });
}

/// Binds the `adm2iamf_*` C ABI exported from `libeclipsa_studio_engine.dylib`.
///
/// One instance per dylib handle. Use [instance] in app code; [openAt] is for
/// tests that want to point at a specific dylib (e.g. the Bazel output).
class AdmImportBridge {
  final EngineBindings _bindings;

  AdmImportBridge._(DynamicLibrary lib) : _bindings = EngineBindings(lib);

  static AdmImportBridge? _instance;

  /// Lazily opens the engine dylib (shared with [EclipsaStudioEngine]) and
  /// binds the ADM symbols.
  static AdmImportBridge get instance =>
      _instance ??= AdmImportBridge._(_load());

  /// Opens a bridge against an explicit dylib path (tests).
  static AdmImportBridge openAt(String dylibPath) =>
      AdmImportBridge._(DynamicLibrary.open(dylibPath));

  static DynamicLibrary _load() =>
      DynamicLibrary.open(EclipsaStudioEngine.dylibPath);

  /// Library version string (e.g. "adm2iamf 0.1.0"). The returned pointer is
  /// statically owned by the library (see adm2iamf_ffi.h) — do NOT free it via
  /// `adm2iamf_string_free`, unlike every other string-returning call here.
  String version() => _bindings.admVersion().toDartString();

  /// Probes an ADM-BWF file synchronously; returns the raw probe JSON string.
  /// Blocks the calling thread (file open + axml/chna parse + scene build), so
  /// on the UI isolate prefer [probeJsonAsync].
  String probeJson(String path) {
    final pathPtr = path.toNativeUtf8();
    try {
      final out = _bindings.admProbeJson(pathPtr);
      if (out == nullptr) return '{"ok":false,"error":"null result"}';
      try {
        return out.toDartString();
      } finally {
        _bindings.admStringFree(out);
      }
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// Probes off the UI isolate so the window never freezes on a large file.
  /// Function pointers are not sendable across isolates, so the helper isolate
  /// re-opens the dylib and runs the blocking probe there. Static on purpose:
  /// the `Isolate.run` closure must capture only `path` (a sendable String).
  /// The handle from that open is never closed: `DynamicLibrary.open` on a
  /// library the process already holds returns the same mapping with its
  /// reference count raised, and the mapping lives for the process anyway.
  static Future<String> probeJsonAsync(String path) =>
      Isolate.run(() => AdmImportBridge._(_load()).probeJson(path));

  /// Starts a render on a native worker thread; returns a positive job id, or a
  /// negative value if the request was rejected before the thread started.
  int renderStart(AdmRenderRequest req) {
    final cfgPtr = calloc<Adm2iamfRenderConfig>();
    final inPtr = req.inPath.toNativeUtf8();
    final outPtr = req.outPath.toNativeUtf8();
    try {
      final cfg = cfgPtr.ref;
      cfg.minImportance = req.minImportance;
      cfg.inPath = inPtr;
      cfg.outPath = outPtr;
      // The native side reads the whole config (incl. string contents) before
      // returning, so it is safe to free our buffers in `finally`.
      return _bindings.admRenderStart(cfgPtr);
    } finally {
      malloc.free(inPtr);
      malloc.free(outPtr);
      calloc.free(cfgPtr);
    }
  }

  double renderProgress(int job) => _bindings.admRenderProgress(job);

  AdmRenderState renderState(int job) =>
      AdmRenderState.fromValue(_bindings.admRenderState(job));

  /// Result JSON once the job is terminal, else null.
  String? renderResultJson(int job) {
    final out = _bindings.admRenderResultJson(job);
    if (out == nullptr) return null;
    try {
      return out.toDartString();
    } finally {
      _bindings.admStringFree(out);
    }
  }

  void renderCancel(int job) => _bindings.admRenderCancel(job);

  /// Drives a started [job] to completion, polling every [poll] and reporting
  /// progress (0..1) via [onProgress]. Returns the terminal result JSON. The
  /// render itself runs on a native worker thread, so polling never blocks it.
  Future<String> awaitRender(
    int job, {
    Duration poll = const Duration(milliseconds: 100),
    void Function(double progress)? onProgress,
  }) async {
    while (true) {
      final state = renderState(job);
      onProgress?.call(renderProgress(job));
      if (state != AdmRenderState.running) {
        return renderResultJson(job) ??
            '{"ok":false,"error":"no result for job $job (state ${state.value})"}';
      }
      await Future<void>.delayed(poll);
    }
  }

  /// Guards [shutdown] so it runs once — it may be called from both the
  /// provider `ref.onDispose` and the app's exit handler.
  bool _didShutdown = false;

  /// Cancels all jobs and blocks until their worker threads finish. The host
  /// must call this before tearing down (e.g. on app exit) so no native worker
  /// outlives the library; see the C ABI contract in adm2iamf_ffi.h.
  /// Idempotent.
  void shutdown() {
    if (_didShutdown) return;
    _didShutdown = true;
    _bindings.admShutdown();
    Log.d(LogCat.engine, 'ADM import: native render workers shut down');
  }
}
