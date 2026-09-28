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

import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for WAV channel-count → element-config autodetect.
/// Pins the rule that the default is never object-based, so a dropped file
/// can't land as a profile-invalid Object in Simple / Base (ES-132).
void main() {
  group('defaultConfigForChannelCount', () {
    test('mono defaults to Channel · Mono, not Object · Mono (ES-132)', () {
      final cfg = defaultConfigForChannelCount(1);
      expect(cfg.type, 'Channel');
      expect(cfg.layout, 'Mono');
    });

    test('Object · Mono is still offered for 1ch (selectable override)', () {
      final configs = validConfigsForChannelCount(1);
      expect(
        configs.any((c) => c.type == 'Object' && c.layout == 'Mono'),
        isTrue,
      );
    });

    test('stereo defaults to Channel · Stereo, not Object · Dual', () {
      final cfg = defaultConfigForChannelCount(2);
      expect(cfg.type, 'Channel');
      expect(cfg.layout, 'Stereo');
    });

    test('the autodetect default is never object-based for any count', () {
      // 1 and 2 are the only counts that offer an Object reading; both must
      // prefer their channel-based default. Sweep a representative range.
      for (final ch in const [1, 2, 4, 6, 8, 10, 12, 16, 17, 24, 25]) {
        expect(
          defaultConfigForChannelCount(ch).type,
          isNot('Object'),
          reason: '$ch-channel default must not be Object',
        );
      }
    });

    test('16ch defaults to Scene · 3OA, not Channel · 9.1.6 (ES-152)', () {
      final cfg = defaultConfigForChannelCount(16);
      expect(cfg.type, 'Scene');
      expect(cfg.layout, '3OA');
      expect(cfg.ambisonicsOrder, 3);
    });

    test('ambiguous bed counts default to the ubiquitous layout', () {
      expect(defaultConfigForChannelCount(6).layout, '5.1');
      expect(defaultConfigForChannelCount(8).layout, '7.1');
      expect(defaultConfigForChannelCount(10).layout, '5.1.4');
    });
  });

  group('validConfigsForChannelCount ordering contract', () {
    test('the default is always the first entry', () {
      for (final ch in const [1, 2, 4, 6, 8, 10, 12, 16, 17, 24, 25, 32]) {
        expect(
          defaultConfigForChannelCount(ch).label,
          validConfigsForChannelCount(ch).first.label,
          reason: '$ch-channel default must be the list head',
        );
      }
    });

    test('deliberate-intent options (Object, Binaural) sort last', () {
      expect(validConfigsForChannelCount(1).last.type, 'Object');
      final stereo = validConfigsForChannelCount(2);
      expect(stereo.first.layout, 'Stereo');
      expect(stereo[1].layout, 'Binaural');
      expect(stereo.last.type, 'Object');
    });

    test('routing-aware superset keeps the exact-count head', () {
      for (final ch in const [2, 6, 8, 10, 12, 16, 25]) {
        final exact = validConfigsForChannelCount(ch).map((c) => c.label);
        final routable = routableConfigsForChannelCount(ch).map((c) => c.label);
        expect(routable.take(exact.length), exact);
      }
    });

    test('exactly the documented counts are ambiguous (ES-152)', () {
      const ambiguous = {1, 2, 6, 8, 10, 16};
      for (var ch = 1; ch <= 32; ch++) {
        expect(
          validConfigsForChannelCount(ch).length > 1,
          ambiguous.contains(ch),
          reason:
              '$ch-channel ambiguity changed — update the element '
              'format dialog trigger if this is intentional',
        );
      }
    });
  });

  group('routableConfigsForChannelCount (matrix format picker)', () {
    List<String> labels(int ch) =>
        routableConfigsForChannelCount(ch).map((c) => c.label).toList();

    test('smaller beds are routable, widest first; wider beds never', () {
      final l = labels(16);
      expect(l, contains('Channel · 7.1.4'));
      expect(l, contains('Channel · 5.1'));
      expect(l, contains('Channel · Stereo'));
      expect(
        l.indexOf('Channel · 7.1.4'),
        lessThan(l.indexOf('Channel · 5.1')),
      );
      // 7.1.5.4 (17ch) and 10.2.9.3 (24ch) exceed the source — a wider
      // bed would just seed silent speakers.
      expect(l, isNot(contains('Channel · 7.1.5.4')));
      expect(l, isNot(contains('Channel · 10.2.9.3')));
    });

    test('ambisonics routes down in order only, never up', () {
      // 3OA source: lower orders offered, descending.
      final l16 = labels(16);
      expect(l16, contains('Scene · 2OA'));
      expect(l16, contains('Scene · 1OA'));
      expect(l16.indexOf('Scene · 2OA'), lessThan(l16.indexOf('Scene · 1OA')));
      // 2OA source: only 1OA below it; never 3OA/4OA.
      final l9 = labels(9);
      expect(l9, contains('Scene · 1OA'));
      expect(l9, isNot(contains('Scene · 3OA')));
      expect(l9, isNot(contains('Scene · 4OA')));
      // 4OA source: everything down to 1OA (playback caps at 3OA, so
      // the 3OA target is the practical use).
      final l25 = labels(25);
      expect(l25, containsAll(['Scene · 3OA', 'Scene · 2OA', 'Scene · 1OA']));
    });

    test('non-ambisonic sources get no scene targets at all', () {
      for (final ch in const [2, 6, 8, 10, 12, 17, 24]) {
        expect(
          routableConfigsForChannelCount(ch).where((c) => c.type == 'Scene'),
          isEmpty,
          reason: '$ch-channel WAV has no soundfield to truncate',
        );
      }
    });

    test('deliberate-intent targets sort last', () {
      final l = labels(16);
      expect(l.sublist(l.length - 3), [
        'Channel · Binaural',
        'Object · Mono',
        'Object · Dual',
      ]);
    });

    test('no duplicates when the intent targets overlap exact counts', () {
      for (final ch in const [1, 2, 4, 6, 16]) {
        final l = labels(ch);
        expect(l.toSet().length, l.length, reason: '$ch-channel duplicates');
      }
    });

    test('mono has nothing to route — just the exact list', () {
      expect(labels(1), ['Channel · Mono', 'Object · Mono']);
    });
  });

  group('allElementConfigs (picker universe)', () {
    test('covers every bed, order, and object config with unique labels', () {
      final labels = allElementConfigs().map((c) => c.label).toList();
      expect(labels.toSet().length, labels.length);
      expect(
        labels,
        containsAll([
          'Channel · Mono',
          'Channel · 9.1.6',
          'Channel · 10.2.9.3',
          'Channel · Binaural',
          'Scene · 1OA',
          'Scene · 4OA',
          'Object · Mono',
          'Object · Dual',
        ]),
      );
    });

    test('labels match the exact-count lists (dedup contract)', () {
      final universe = allElementConfigs().map((c) => c.label).toSet();
      for (final ch in const [1, 2, 4, 6, 8, 10, 12, 16, 17, 24, 25]) {
        for (final cfg in validConfigsForChannelCount(ch)) {
          expect(
            universe,
            contains(cfg.label),
            reason: '${cfg.label} missing from the universe',
          );
        }
      }
    });
  });

  group('configMismatchCaveat (de-emphasized-option tooltip)', () {
    ElementConfig byLabel(String label) =>
        allElementConfigs().firstWhere((c) => c.label == label);

    test('null for every natural (routable) pairing', () {
      for (final ch in const [1, 2, 6, 12, 16, 25]) {
        for (final cfg in routableConfigsForChannelCount(ch)) {
          expect(
            configMismatchCaveat(cfg, ch),
            isNull,
            reason: '${cfg.label} is a natural fit for ${ch}ch',
          );
        }
      }
    });

    test('wider beds and objects warn about silent channels', () {
      expect(
        configMismatchCaveat(byLabel('Channel · 9.1.6'), 12),
        contains('unrouted channels stay silent'),
      );
      expect(
        configMismatchCaveat(byLabel('Channel · 9.1.6'), 12),
        contains('12ch source'),
      );
      expect(
        configMismatchCaveat(byLabel('Object · Dual'), 1),
        contains('unrouted channels stay silent'),
      );
    });

    test('scene targets over non-natural sources explain ACN use', () {
      // Non-ambisonic source: channels get consumed as ACN components.
      expect(
        configMismatchCaveat(byLabel('Scene · 1OA'), 12),
        contains('ACN 0, ACN 1'),
      );
      // Ambisonic source, but a higher order than it carries.
      expect(
        configMismatchCaveat(byLabel('Scene · 3OA'), 9),
        contains('ambisonic'),
      );
    });
  });

  group('elementConfigChannelCount', () {
    test('derives output count per type, falls back for custom', () {
      final configs = routableConfigsForChannelCount(16);
      final scene = configs.firstWhere((c) => c.label == 'Scene · 2OA');
      expect(elementConfigChannelCount(scene, 16), 9);
      final bed = configs.firstWhere((c) => c.label == 'Channel · 5.1');
      expect(elementConfigChannelCount(bed, 16), 6);
      final dual = configs.firstWhere((c) => c.label == 'Object · Dual');
      expect(elementConfigChannelCount(dual, 16), 2);
      final custom = validConfigsForChannelCount(14).single;
      expect(elementConfigChannelCount(custom, 14), 14);
    });
  });
}
