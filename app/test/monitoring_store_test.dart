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

import 'package:eclipsa_studio/session/monitoring_store.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for the per-device monitoring store. No engine,
/// no path_provider — only the encode/decode functions and the model's
/// defensive JSON. These pin the round-trip and the untrusted-input
/// posture (never throw, drop garbage) — and that decode does NOT clamp
/// to any device channel count: the stored patch is the user's full
/// routing; the device's channel count is a view applied at the
/// engine-push and matrix-display boundaries (ES-24, ES-63).
void main() {
  group('encodeDevice / decodeDevice round-trip', () {
    test('preserves targets, active, routing, noiseDbfs, labels', () {
      final cfg = MonitoringConfig(
        targets: [
          const OutputTarget(layout: OarLayout.stereo, routing: [1, 2]),
          OutputTarget(
            layout: OarLayout.layout714,
            routing: List<int>.generate(
              OarLayout.layout714.channels,
              (i) => 1 << i,
            ),
          ),
        ],
        activeLayout: OarLayout.layout714,
        noiseDbfs: -14.0,
      );
      final labels = {0: 'Main L', 1: 'Main R', 10: 'Sub'};

      final encoded = encodeDevice(cfg, labels);
      final decoded = decodeDevice(encoded);

      expect(decoded.config.targets.map((t) => t.layout), [
        OarLayout.stereo,
        OarLayout.layout714,
      ]);
      expect(decoded.config.activeLayout, OarLayout.layout714);
      expect(decoded.config.targets[0].routing, [1, 2]);
      expect(
        decoded.config.targets[1].routing,
        List<int>.generate(OarLayout.layout714.channels, (i) => 1 << i),
      );
      expect(decoded.config.noiseDbfs, -14.0);
      expect(decoded.labels, {0: 'Main L', 1: 'Main R', 10: 'Sub'});
    });

    test('limiter never appears in the encoded slice (always-on)', () {
      final encoded = encodeDevice(MonitoringConfig.initial(), const {});
      expect(encoded.containsKey('limiter'), isFalse);
      expect(encoded.containsKey('limiterEnabled'), isFalse);
    });
  });

  group('defensive decode', () {
    test('drops a target with an unknown layout name', () {
      final j = {
        'active': 'stereo',
        'targets': [
          {
            'layout': 'stereo',
            'routing': [1, 2],
          },
          {
            'layout': 'bogus',
            'routing': [1, 2],
          },
        ],
      };
      final d = decodeDevice(j);
      expect(d.config.targets.map((t) => t.layout), [OarLayout.stereo]);
    });

    test('pads a short routing with identity to layout.channels', () {
      final j = {
        'active': 'layout514',
        'targets': [
          {
            'layout': 'layout514',
            'routing': [9, 9],
          }, // 2 of 10
        ],
      };
      final r = decodeDevice(j).config.targets.single.routing;
      expect(r.length, OarLayout.layout514.channels);
      expect(r[0], 9);
      expect(r[1], 9);
      expect(r[2], 1 << 2); // padded with identity
      expect(r[9], 1 << 9);
    });

    test('truncates a long routing to layout.channels', () {
      final j = {
        'active': 'layout714',
        'targets': [
          {'layout': 'layout714', 'routing': List<int>.generate(20, (i) => i)},
        ],
      };
      final r = decodeDevice(j).config.targets.single.routing;
      expect(r.length, OarLayout.layout714.channels);
      expect(r, List<int>.generate(OarLayout.layout714.channels, (i) => i));
    });

    test('parses string label keys back to int keys', () {
      final j = {
        'active': 'stereo',
        'targets': [
          {
            'layout': 'stereo',
            'routing': [1, 2],
          },
        ],
        'labels': {'0': 'L', '1': 'R'},
      };
      expect(decodeDevice(j).labels, {0: 'L', 1: 'R'});
    });

    test('preserves labels for channels the current device lacks', () {
      // The label was written on a bigger interface; it must survive the
      // round-trip so it reappears when that interface comes back (ES-63).
      final j = {
        'active': 'stereo',
        'targets': [
          {
            'layout': 'stereo',
            'routing': [1, 2],
          },
        ],
        'labels': {'0': 'L', '5': 'Sub'},
      };
      final d = decodeDevice(j);
      expect(d.labels[5], 'Sub');
      expect(d.labels[0], 'L');
    });

    test('drops labels at or beyond kMaxRoutingChannels', () {
      final j = {
        'active': 'stereo',
        'targets': [
          {
            'layout': 'stereo',
            'routing': [1, 2],
          },
        ],
        'labels': {'0': 'L', '$kMaxRoutingChannels': 'bogus'},
      };
      expect(decodeDevice(j).labels.containsKey(kMaxRoutingChannels), isFalse);
    });

    test('preserves routing bits past any device channel count', () {
      // Decode must never clamp: the wire into device channel 40 was
      // patched on a bigger interface and restores with it (ES-24, ES-63).
      final routing = List<int>.generate(
        OarLayout.layout714.channels,
        (i) => 1 << i,
      );
      routing[0] = (1 << 0) | (1 << 40); // a wire into device channel 40
      final j = {
        'active': 'layout714',
        'targets': [
          {'layout': 'layout714', 'routing': routing},
        ],
      };
      final r = decodeDevice(j).config.targets.single.routing;
      expect(r[0] & (1 << 40), 1 << 40); // out-of-range wire kept
      expect(r[0] & (1 << 0), 1 << 0); // in-range identity kept
    });
  });

  group('garbage tolerance (never throws)', () {
    test('empty map decodes to the seeded default', () {
      final d = decodeDevice(<String, dynamic>{});
      expect(
        d.config.targets.map((t) => t.layout),
        MonitoringConfig.initial().targets.map((t) => t.layout),
      );
      expect(d.config.activeLayout, MonitoringConfig.initial().activeLayout);
      expect(d.labels, isEmpty);
    });

    test('malformed field types degrade to defaults without throwing', () {
      final j = <String, dynamic>{
        'active': 123,
        'targets': 'not a list',
        'labels': 'not a map',
        'noiseDbfs': 'loud',
      };
      late final ({MonitoringConfig config, Map<int, String> labels}) d;
      expect(() => d = decodeDevice(j), returnsNormally);
      expect(d.config.targets, isNotEmpty);
      expect(d.config.noiseDbfs, MonitoringConfig.kDefaultNoiseDbfs);
      expect(d.labels, isEmpty);
    });

    test('a target with non-int routing entries pads to identity', () {
      final j = {
        'active': 'stereo',
        'targets': [
          {
            'layout': 'stereo',
            'routing': ['x', 'y'],
          },
        ],
      };
      final r = decodeDevice(j).config.targets.single.routing;
      // Non-int entries dropped → fully padded with identity.
      expect(r, [1 << 0, 1 << 1]);
    });
  });
}
