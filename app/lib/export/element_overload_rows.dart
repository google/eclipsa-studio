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

/// Signal-overload warning rows (ES-470): elements whose stream output
/// exceeded full scale, with fully formatted messages. Shared between
/// the IAMF export dialog (pre-encode gate + post-export receipt) and
/// the Loudness Report window (ES-527).
library;

import '../state.dart';
import 'element_clip_stats.dart';

/// One signal-overload warning row (ES-470): an element whose stream
/// output exceeded full scale, with a fully formatted message for the
/// pre-encode gate and the post-export receipt.
class ElementOverloadRow {
  final int elementId;
  final String elementName;
  final ElementClipStats stats;

  const ElementOverloadRow({
    required this.elementId,
    required this.elementName,
    required this.stats,
  });

  /// e.g. `Element "Drums": 1,204 samples above full scale (peak +2.3 dBFS)`
  String get message =>
      'Element "$elementName": ${_formatCount(stats.clippedSamples)} '
      '${stats.clippedSamples == 1 ? 'sample' : 'samples'} above full '
      'scale (peak ${formatPeakDbfs(stats.peakDbfs)})';

  static String _formatCount(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  );
}

/// Overload rows for the pre-encode gate: elements whose measure-pass
/// stats show clipping, in [elements] order. An id with stats but no
/// matching element (stale cached report edge) falls back to a
/// placeholder name so the warning is never silently dropped.
List<ElementOverloadRow> clipGateRows(
  Map<int, ElementClipStats> stats,
  List<AudioElement> elements,
) {
  final rows = <ElementOverloadRow>[];
  final seen = <int>{};
  for (final e in elements) {
    final s = stats[e.id];
    seen.add(e.id);
    if (s != null && s.clipped) {
      rows.add(
        ElementOverloadRow(elementId: e.id, elementName: e.name, stats: s),
      );
    }
  }
  for (final entry in stats.entries) {
    if (!seen.contains(entry.key) && entry.value.clipped) {
      rows.add(
        ElementOverloadRow(
          elementId: entry.key,
          elementName: 'Element #${entry.key}',
          stats: entry.value,
        ),
      );
    }
  }
  return rows;
}

/// The subset of [elements] the encode actually pushes (wavPath-bearing),
/// in order. The single definition of the add-order alignment: both the
/// push-list builder in `_runExport` and [encodeOverloadRows] must use
/// this, or the per-index stats desync from the elements they describe.
List<AudioElement> pushableElements(List<AudioElement> elements) => [
  for (final e in elements)
    if (e.wavPath != null) e,
];

/// Overload rows from the encode result: [stats] is add-order aligned
/// with [pushableElements] of [elements] (the push list the encode
/// isolate was given). Null entries (no stats for that index) and
/// clean elements are skipped.
List<ElementOverloadRow> encodeOverloadRows(
  List<AudioElement> elements,
  List<ElementClipStats?> stats,
) {
  final pushed = pushableElements(elements);
  final rows = <ElementOverloadRow>[];
  for (var i = 0; i < pushed.length && i < stats.length; i++) {
    final s = stats[i];
    if (s != null && s.clipped) {
      rows.add(
        ElementOverloadRow(
          elementId: pushed[i].id,
          elementName: pushed[i].name,
          stats: s,
        ),
      );
    }
  }
  return rows;
}
