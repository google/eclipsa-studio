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

import '../logging/log.dart';
import 'peak_data.dart';
import 'peak_isolate.dart';

/// Manages peak data computation and caching for WAV files.
///
/// Peaks are kept in RAM only. They are recomputed on each app launch.
class PeakCache {
  final int samplesPerPeak;

  /// Pyramid depth computed by the engine. Only level 0 (finest) is
  /// consumed today — the timeline stretches it and the painter
  /// aggregates per pixel; adaptive selection of the coarser levels
  /// at zoom-out is tracked in ES-551.
  final int pyramidLevels;

  /// Long-lived background isolate for peak computation.
  final PeakIsolate? _peakIsolate;

  /// In-memory cache: fileKey → channel index → pyramid.
  final Map<String, List<PeakPyramid>> _ramCache = {};

  /// In-flight computations — prevents duplicate isolate requests
  /// when multiple channels of the same file load concurrently.
  final Map<String, Future<List<PeakPyramid>>> _pending = {};

  PeakCache({
    this.samplesPerPeak = 256,
    this.pyramidLevels = 4,
    String? dylibPath,
  }) : _peakIsolate = dylibPath != null ? PeakIsolate(dylibPath) : null;

  /// Get or compute peak pyramids for all channels in a WAV file.
  Future<List<PeakPyramid>> getPeaks(String wavPath) async {
    final key = _fileKey(wavPath);

    // Check RAM cache.
    if (_ramCache.containsKey(key)) return _ramCache[key]!;

    // Join an in-flight computation for the same file.
    if (_pending.containsKey(key)) return _pending[key]!;

    // Reserve the pending slot before any await so concurrent
    // callers join the same future rather than spawning duplicates.
    final completer = Completer<List<PeakPyramid>>();
    _pending[key] = completer.future;

    try {
      // Compute peaks on the background isolate.
      if (_peakIsolate == null) {
        Log.w(
          LogCat.waveform,
          'No peak isolate — cannot compute peaks for $wavPath',
        );
        completer.complete(const []);
        return const [];
      }
      final List<PeakPyramid> pyramids;
      try {
        pyramids = await _peakIsolate.compute(
          wavPath: wavPath,
          samplesPerPeak: samplesPerPeak,
          numLevels: pyramidLevels,
        );
      } on Object catch (e) {
        // Isolate start/compute failures (e.g. a dylib whose peak
        // symbols are missing) degrade to "no peaks" — the waveform
        // widget's catch list doesn't cover these, so an empty result
        // is the contained outcome, not a rethrow.
        Log.w(LogCat.waveform, 'Peak computation failed for $wavPath', e);
        completer.complete(const []);
        return const [];
      }

      _ramCache[key] = pyramids;

      completer.complete(pyramids);
      return pyramids;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _pending.remove(key);
    }
  }

  /// Evict a file from the RAM cache.
  void evict(String wavPath) {
    _ramCache.remove(_fileKey(wavPath));
  }

  /// Evict a file from the RAM cache. In-flight computations are
  /// left to finish naturally — the wavGeneration bump causes
  /// widgets to re-request with the new file.
  void evictAll(String wavPath) {
    _ramCache.remove(_fileKey(wavPath));
  }

  /// Clear all RAM cache.
  void clear() => _ramCache.clear();

  /// RAM cache key: unique per file path + peak params.
  String _fileKey(String wavPath) {
    return '$wavPath|$samplesPerPeak|$pyramidLevels';
  }
}
