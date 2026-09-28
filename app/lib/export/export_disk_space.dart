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

/// Disk-space arithmetic for the export dialog's low-space warning
/// (ES-742). Pure functions: the dialog measures the files and volumes and
/// hands the numbers in, so everything here is unit-testable.
library;

import 'iamf_export_config.dart';

/// Bytes the encoded `.iamf` will take: the audio payload, without the
/// descriptor OBUs (a few kilobytes). LPCM is channels × bytes per sample
/// × frames. Opus is the per-channel bitrate × channels × seconds, which
/// is what iamf-tools targets (`coupling_rate_adjustment` stays 1.0).
int estimateIamfBytes({
  required IamfCodec codec,
  required int bitDepth,
  required int sampleRate,
  required int totalChannels,
  required int frames,
  required int opusBitratePerChannel,
}) {
  if (totalChannels <= 0 || frames <= 0) return 0;
  switch (codec) {
    case IamfCodec.lpcm:
      return totalChannels * (bitDepth ~/ 8) * frames;
    case IamfCodec.opus:
      final bytesPerSecond = totalChannels * opusBitratePerChannel / 8;
      return (bytesPerSecond * frames / sampleRate).round();
  }
}

/// Space an export needs on each volume it writes to, in bytes.
///
/// An MP4 export stages everything in the scratch dir: the `.iamf`, then
/// libgpac's edit-mode temp file holding every video sample (the video's
/// size), then the `.muxed` output (video plus audio), all present at
/// once when the mux closes. The finished file is then copied to the
/// destination. A bare `.iamf` export writes straight to the destination.
class ExportSpaceNeed {
  final int scratchBytes;
  final int destinationBytes;

  const ExportSpaceNeed({
    required this.scratchBytes,
    required this.destinationBytes,
  });

  factory ExportSpaceNeed.compute({
    required bool muxToMp4,
    required int iamfBytes,
    required int videoBytes,
  }) {
    if (!muxToMp4) {
      return ExportSpaceNeed(scratchBytes: 0, destinationBytes: iamfBytes);
    }
    return ExportSpaceNeed(
      scratchBytes: 2 * videoBytes + 2 * iamfBytes,
      destinationBytes: videoBytes + iamfBytes,
    );
  }
}

/// Free space on the volume holding a path, as `EclipsaStudioEngine.volumeInfo`
/// reports it.
class VolumeSpace {
  final String path;
  final int freeBytes;
  final int volumeId;

  const VolumeSpace({
    required this.path,
    required this.freeBytes,
    required this.volumeId,
  });
}

/// One volume that lacks the space an export needs on it.
class DiskSpaceShortfall {
  /// A path on the volume, for the message.
  final String path;
  final int neededBytes;
  final int freeBytes;

  const DiskSpaceShortfall({
    required this.path,
    required this.neededBytes,
    required this.freeBytes,
  });
}

/// The volumes that cannot hold their share of [need]. When the scratch
/// dir and the destination are on one volume its needs add up, since the
/// staged files still exist while the finished file is being copied.
/// [scratch] is null for a bare `.iamf` export, which stages nothing.
List<DiskSpaceShortfall> diskSpaceShortfalls({
  required ExportSpaceNeed need,
  required VolumeSpace? scratch,
  required VolumeSpace destination,
}) {
  final out = <DiskSpaceShortfall>[];
  if (scratch != null && scratch.volumeId == destination.volumeId) {
    final total = need.scratchBytes + need.destinationBytes;
    if (destination.freeBytes < total) {
      out.add(
        DiskSpaceShortfall(
          path: destination.path,
          neededBytes: total,
          freeBytes: destination.freeBytes,
        ),
      );
    }
    return out;
  }
  if (scratch != null && scratch.freeBytes < need.scratchBytes) {
    out.add(
      DiskSpaceShortfall(
        path: scratch.path,
        neededBytes: need.scratchBytes,
        freeBytes: scratch.freeBytes,
      ),
    );
  }
  if (destination.freeBytes < need.destinationBytes) {
    out.add(
      DiskSpaceShortfall(
        path: destination.path,
        neededBytes: need.destinationBytes,
        freeBytes: destination.freeBytes,
      ),
    );
  }
  return out;
}

/// Decimal units, as Finder and Explorer show file sizes: `1.5 GB`,
/// `697 MB`, `312 kB`, `40 bytes`. One decimal from a gigabyte up.
String formatBytes(int bytes) {
  const kB = 1000;
  const mB = 1000 * kB;
  const gB = 1000 * mB;
  if (bytes >= gB) return '${(bytes / gB).toStringAsFixed(1)} GB';
  if (bytes >= mB) return '${(bytes / mB).round()} MB';
  if (bytes >= kB) return '${(bytes / kB).round()} kB';
  return '$bytes bytes';
}
