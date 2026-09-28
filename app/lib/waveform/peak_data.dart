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

import 'dart:typed_data';
import 'dart:math' as math;

/// A single min/max peak pair plus RMS for a block of samples.
class Peak {
  final double min;
  final double max;
  final double rms;

  const Peak(this.min, this.max, [this.rms = 0.0]);

  double get amplitude => math.max(min.abs(), max.abs());
}

/// Downsampled peak data for one channel.
///
/// Each entry represents the min/max envelope and RMS magnitude of
/// [samplesPerPeak] raw samples.
class ChannelPeaks {
  final Float32List mins;
  final Float32List maxs;
  final Float32List rms;
  final int samplesPerPeak;
  final int channelIndex;

  const ChannelPeaks({
    required this.mins,
    required this.maxs,
    required this.rms,
    required this.samplesPerPeak,
    required this.channelIndex,
  });

  int get length => mins.length;

  Peak operator [](int i) => Peak(mins[i], maxs[i], rms[i]);

  /// Merge a range of bins into a single Peak. Min/max use absolute
  /// extremes; RMS combines as sqrt(mean(child_rms²)).
  Peak rangeMinMax(int start, int end) {
    double lo = 0, hi = 0;
    double sumSq = 0;
    var count = 0;
    final e = math.min(end, length);
    for (var i = start; i < e; i++) {
      if (mins[i] < lo) lo = mins[i];
      if (maxs[i] > hi) hi = maxs[i];
      final r = rms[i];
      sumSq += r * r;
      count++;
    }
    final mergedRms = count > 0 ? math.sqrt(sumSq / count) : 0.0;
    return Peak(lo, hi, mergedRms);
  }

  /// On-disk format version. v2 added the `rms` Float32List parallel
  /// to mins/maxs. Header is [version: i32][samplesPerPeak: i32]
  /// [length: i32], followed by mins, maxs, rms (Float32, length each).
  static const int _formatVersion = 2;
  static const int _headerBytes = 12;

  /// Serialize to bytes for disk caching.
  Uint8List toBytes() {
    final buf = ByteData(
      _headerBytes +
          mins.lengthInBytes +
          maxs.lengthInBytes +
          rms.lengthInBytes,
    );
    buf.setInt32(0, _formatVersion, Endian.little);
    buf.setInt32(4, samplesPerPeak, Endian.little);
    buf.setInt32(8, length, Endian.little);
    final out = Uint8List(buf.lengthInBytes);
    out.setAll(0, buf.buffer.asUint8List());
    out.setAll(_headerBytes, mins.buffer.asUint8List());
    out.setAll(_headerBytes + mins.lengthInBytes, maxs.buffer.asUint8List());
    out.setAll(
      _headerBytes + mins.lengthInBytes + maxs.lengthInBytes,
      rms.buffer.asUint8List(),
    );
    return out;
  }

  /// Deserialize from bytes. Throws [FormatException] for unknown
  /// format versions, so callers (e.g. a disk cache) can detect and
  /// invalidate stale entries.
  factory ChannelPeaks.fromBytes(Uint8List bytes, int channelIndex) {
    final bd = ByteData.sublistView(bytes);
    final version = bd.getInt32(0, Endian.little);
    if (version != _formatVersion) {
      throw FormatException(
        'ChannelPeaks: unsupported format version $version '
        '(expected $_formatVersion)',
      );
    }
    final spp = bd.getInt32(4, Endian.little);
    final len = bd.getInt32(8, Endian.little);
    final mins = Float32List(len);
    final maxs = Float32List(len);
    final rms = Float32List(len);
    final minsOff = _headerBytes;
    final maxsOff = minsOff + len * 4;
    final rmsOff = maxsOff + len * 4;
    mins.setAll(
      0,
      Float32List.sublistView(Uint8List.sublistView(bytes, minsOff, maxsOff)),
    );
    maxs.setAll(
      0,
      Float32List.sublistView(Uint8List.sublistView(bytes, maxsOff, rmsOff)),
    );
    rms.setAll(
      0,
      Float32List.sublistView(
        Uint8List.sublistView(bytes, rmsOff, rmsOff + len * 4),
      ),
    );
    return ChannelPeaks(
      mins: mins,
      maxs: maxs,
      rms: rms,
      samplesPerPeak: spp,
      channelIndex: channelIndex,
    );
  }
}

/// Compute peaks from raw sample data.
///
/// [samples] is one channel of Float64 audio data.
/// [samplesPerPeak] controls resolution (e.g. 256 = one peak per 256 samples).
ChannelPeaks computePeaks(
  Float64List samples,
  int channelIndex, {
  int samplesPerPeak = 256,
}) {
  final numPeaks = (samples.length / samplesPerPeak).ceil();
  final mins = Float32List(numPeaks);
  final maxs = Float32List(numPeaks);
  final rms = Float32List(numPeaks);

  for (var p = 0; p < numPeaks; p++) {
    final start = p * samplesPerPeak;
    final end = math.min(start + samplesPerPeak, samples.length);
    double lo = 0, hi = 0;
    double sumSq = 0;
    for (var i = start; i < end; i++) {
      final s = samples[i];
      if (s < lo) lo = s;
      if (s > hi) hi = s;
      sumSq += s * s;
    }
    mins[p] = lo;
    maxs[p] = hi;
    final count = end - start;
    rms[p] = count > 0 ? math.sqrt(sumSq / count) : 0.0;
  }

  return ChannelPeaks(
    mins: mins,
    maxs: maxs,
    rms: rms,
    samplesPerPeak: samplesPerPeak,
    channelIndex: channelIndex,
  );
}

/// Multi-resolution peak pyramid for fast zoom.
///
/// Level 0 = finest resolution (samplesPerPeak).
/// Each subsequent level halves resolution (doubles samplesPerPeak).
class PeakPyramid {
  final List<ChannelPeaks> levels;

  const PeakPyramid(this.levels);

  /// Build a pyramid with [numLevels] levels from raw samples.
  factory PeakPyramid.build(
    Float64List samples,
    int channelIndex, {
    int baseSamplesPerPeak = 256,
    int numLevels = 4,
  }) {
    final levels = <ChannelPeaks>[];
    levels.add(
      computePeaks(samples, channelIndex, samplesPerPeak: baseSamplesPerPeak),
    );

    for (var l = 1; l < numLevels; l++) {
      final prev = levels[l - 1];
      const factor = 2;
      final numPeaks = (prev.length / factor).ceil();
      final mins = Float32List(numPeaks);
      final maxs = Float32List(numPeaks);
      final rms = Float32List(numPeaks);

      for (var p = 0; p < numPeaks; p++) {
        final start = p * factor;
        final end = math.min(start + factor, prev.length);
        double lo = 0, hi = 0;
        double sumSq = 0;
        var count = 0;
        for (var i = start; i < end; i++) {
          if (prev.mins[i] < lo) lo = prev.mins[i];
          if (prev.maxs[i] > hi) hi = prev.maxs[i];
          final r = prev.rms[i];
          sumSq += r * r;
          count++;
        }
        mins[p] = lo;
        maxs[p] = hi;
        rms[p] = count > 0 ? math.sqrt(sumSq / count) : 0.0;
      }

      levels.add(
        ChannelPeaks(
          mins: mins,
          maxs: maxs,
          rms: rms,
          samplesPerPeak: baseSamplesPerPeak * (1 << l),
          channelIndex: channelIndex,
        ),
      );
    }

    return PeakPyramid(levels);
  }
}
