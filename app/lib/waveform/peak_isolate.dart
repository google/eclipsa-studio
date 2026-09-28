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
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;

import '../ffi/engine_bindings.dart';
import 'peak_data.dart';

/// Request sent to the long-lived peak isolate.
class _PeakRequest {
  final String wavPath;
  final int samplesPerPeak;
  final int numLevels;
  final SendPort replyPort;

  const _PeakRequest({
    required this.wavPath,
    required this.samplesPerPeak,
    required this.numLevels,
    required this.replyPort,
  });
}

/// Long-lived background isolate for peak computation.
///
/// Spawned once on first request. Opens the dylib and looks up
/// symbols once, then processes requests via [SendPort] messages.
class PeakIsolate {
  final String _dylibPath;
  SendPort? _sendPort;
  Completer<void>? _starting;

  PeakIsolate(this._dylibPath);

  Future<List<PeakPyramid>> compute({
    required String wavPath,
    int samplesPerPeak = 256,
    int numLevels = 4,
  }) async {
    await _ensureStarted();
    final response = ReceivePort();
    try {
      _sendPort!.send(
        _PeakRequest(
          wavPath: wavPath,
          samplesPerPeak: samplesPerPeak,
          numLevels: numLevels,
          replyPort: response.sendPort,
        ),
      );
      final result = await response.first;
      if (result is List<PeakPyramid>) return result;
      if (result is String) throw Exception(result);
      return const [];
    } finally {
      response.close();
    }
  }

  Future<void> _ensureStarted() async {
    if (_sendPort != null) return;
    if (_starting != null) {
      await _starting!.future;
      return;
    }
    _starting = Completer<void>();
    final initPort = ReceivePort();
    final failPort = ReceivePort();
    try {
      await Isolate.spawn(
        _isolateEntry,
        (_dylibPath, initPort.sendPort),
        onError: failPort.sendPort,
        onExit: failPort.sendPort,
      );
      // Race init against early death: a failed dylib open or symbol
      // lookup kills the isolate before it ever sends its SendPort,
      // and without the fail ports this await would hang forever.
      final first = await Future.any(<Future<Object?>>[
        initPort.first,
        failPort.first,
      ]);
      if (first is! SendPort) {
        // onError delivers [error, stackTrace]; onExit delivers null.
        final reason = first is List && first.isNotEmpty
            ? '${first[0]}'
            : 'isolate exited before init';
        throw StateError('peak isolate failed to start: $reason');
      }
      _sendPort = first;
      _starting!.complete();
    } catch (e) {
      // Deliberate asymmetry: success is permanent (_sendPort set),
      // while failure resets _starting so a later compute() retries
      // the spawn. Each retry costs one isolate + dlopen attempt and
      // is contained by PeakCache (logged warning, empty peaks), but
      // it also recovers if the dylib becomes loadable mid-session.
      _starting!.completeError(e);
      _starting = null;
      rethrow;
    } finally {
      initPort.close();
      failPort.close();
    }
  }
}

/// Entry point for the long-lived isolate.
///
/// Opens the dylib once, looks up symbols once, then loops
/// processing [_PeakRequest] messages until the isolate is killed.
void _isolateEntry((String dylibPath, SendPort initPort) args) {
  final (dylibPath, initPort) = args;
  final bindings = EngineBindings(DynamicLibrary.open(dylibPath));

  // Bind eagerly (the lookups in EngineBindings are lazy) so a missing
  // symbol still kills the isolate during init, before the SendPort
  // handshake — the same failure mode as the previous direct lookups.
  final peaksCompute = bindings.peaksCompute;
  final peaksFree = bindings.peaksFree;
  final peaksLevelData = bindings.peaksLevelData;

  final requestPort = ReceivePort();
  initPort.send(requestPort.sendPort);

  requestPort.listen((message) {
    final req = message as _PeakRequest;
    try {
      final result = _computePeaks(
        req,
        peaksCompute,
        peaksFree,
        peaksLevelData,
      );
      req.replyPort.send(result);
    } catch (e) {
      req.replyPort.send(e.toString());
    }
  });
}

List<PeakPyramid> _computePeaks(
  _PeakRequest req,
  PeaksComputeDart peaksCompute,
  PeaksFreeDart peaksFree,
  PeaksLevelDataDart peaksLevelData,
) {
  final pathPtr = req.wavPath.toNativeUtf8(allocator: ffi_pkg.malloc);
  Pointer<EclipsaStudioPeakData> dataPtr;
  try {
    dataPtr = peaksCompute(pathPtr, req.samplesPerPeak, req.numLevels);
  } finally {
    ffi_pkg.malloc.free(pathPtr);
  }

  if (dataPtr == nullptr) return const [];

  try {
    final hdr = dataPtr.ref;
    final nChannels = hdr.numChannels;
    final nLevels = hdr.numLevels;

    if (nChannels == 0 || nLevels == 0) return const [];

    final pyramids = <PeakPyramid>[];

    for (var ch = 0; ch < nChannels; ch++) {
      final levels = <ChannelPeaks>[];

      for (var l = 0; l < nLevels; l++) {
        final nPeaks = hdr.numPeaks[l];
        final spp = hdr.samplesPerPeak[l];
        final minsPtr = peaksLevelData(dataPtr, l, ch);

        if (minsPtr == nullptr) continue;

        final mins = Float32List(nPeaks);
        final maxs = Float32List(nPeaks);
        final rms = Float32List(nPeaks);
        for (var i = 0; i < nPeaks; i++) {
          mins[i] = minsPtr[i];
          maxs[i] = minsPtr[nPeaks + i];
          rms[i] = minsPtr[2 * nPeaks + i];
        }

        levels.add(
          ChannelPeaks(
            mins: mins,
            maxs: maxs,
            rms: rms,
            samplesPerPeak: spp,
            channelIndex: ch,
          ),
        );
      }

      if (levels.isNotEmpty) pyramids.add(PeakPyramid(levels));
    }

    return pyramids;
  } finally {
    peaksFree(dataPtr);
  }
}
