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

// Unit tests for the signal-overload row builders (ES-470): the
// pre-encode gate rows (clipGateRows, keyed by element id) and the
// post-encode receipt rows (encodeOverloadRows, add-order aligned with
// the wavPath-bearing subset), plus the message formatting.

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/export/element_clip_stats.dart';
import 'package:eclipsa_studio/export/element_overload_rows.dart';
import 'package:eclipsa_studio/state.dart';

AudioElement _element(int id, String name, {String? wavPath = '/tmp/a.wav'}) {
  return AudioElement(
    id: id,
    name: name,
    type: 'Channel',
    layout: 'Stereo',
    codec: 'PCM',
    color: 0xFF000000,
    gain: 0,
    wavPath: wavPath,
  );
}

const _hot = ElementClipStats(clippedSamples: 1204, peakLinear: 1.3);
const _clean = ElementClipStats(clippedSamples: 0, peakLinear: 0.8);

void main() {
  group('clipGateRows', () {
    test('keeps only clipped elements, in elements order', () {
      final rows = clipGateRows(
        {
          2: _hot,
          1: _clean,
          3: const ElementClipStats(clippedSamples: 1, peakLinear: 1.01),
        },
        [_element(1, 'Bed'), _element(2, 'Drums'), _element(3, 'Vox')],
      );
      expect(rows.map((r) => r.elementName), ['Drums', 'Vox']);
    });

    test('element with no stats entry is not a warning', () {
      final rows = clipGateRows(
        {1: _hot},
        [_element(1, 'Drums'), _element(2, 'NotMeasured')],
      );
      expect(rows.map((r) => r.elementId), [1]);
    });

    test('clipped stats without a matching element get a placeholder', () {
      // Interpolated, not a literal: the open-source export rewrites a
      // literal `ES-42` as an issue reference.
      const id = 42;
      final rows = clipGateRows({id: _hot}, [_element(1, 'Bed')]);
      expect(rows.single.elementName, 'Element #$id');
    });

    test('clean stats without a matching element are dropped', () {
      expect(clipGateRows({42: _clean}, [_element(1, 'Bed')]), isEmpty);
    });
  });

  group('encodeOverloadRows', () {
    test('aligns add-order stats with the wavPath-bearing subset', () {
      // Element 2 has no wavPath, so the push list was [1, 3]: index 1
      // of the stats belongs to element 3.
      final rows = encodeOverloadRows(
        [
          _element(1, 'Bed'),
          _element(2, 'NoWav', wavPath: null),
          _element(3, 'Drums'),
        ],
        [_clean, _hot],
      );
      expect(rows.single.elementId, 3);
      expect(rows.single.elementName, 'Drums');
    });

    test('null entries and clean elements are skipped', () {
      final rows = encodeOverloadRows(
        [_element(1, 'Bed'), _element(2, 'Drums')],
        [null, _clean],
      );
      expect(rows, isEmpty);
    });

    test('stats shorter than the push list are tolerated', () {
      final rows = encodeOverloadRows(
        [_element(1, 'Bed'), _element(2, 'Drums')],
        [_hot],
      );
      expect(rows.single.elementId, 1);
    });
  });

  group('ElementOverloadRow.message', () {
    test('formats count, plural, and signed peak', () {
      const row = ElementOverloadRow(
        elementId: 1,
        elementName: 'Drums',
        stats: _hot,
      );
      // 20*log10(1.3) = +2.3 dBFS.
      expect(
        row.message,
        'Element "Drums": 1,204 samples above full scale (peak +2.3 dBFS)',
      );
    });

    test('singular sample', () {
      const row = ElementOverloadRow(
        elementId: 1,
        elementName: 'Vox',
        stats: ElementClipStats(clippedSamples: 1, peakLinear: 1.01),
      );
      expect(row.message, contains('1 sample above full scale'));
      expect(row.message, isNot(contains('1 samples')));
    });
  });
}
