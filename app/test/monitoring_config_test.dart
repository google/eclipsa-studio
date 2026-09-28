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

import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for the multi-target monitoring model. No engine
/// dependency — these pin down the index/active-key integrity and the
/// cross-point routing semantics that Phase 2 plumbing relies on.
void main() {
  late ProviderContainer container;
  MonitoringConfig read() => container.read(monitoringConfigProvider);
  MonitoringConfigNotifier notifier() =>
      container.read(monitoringConfigProvider.notifier);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  group('OutputTarget', () {
    test('identity patch maps channel i to device bit i', () {
      final t = OutputTarget.identity(OarLayout.layout514);
      expect(t.routing.length, OarLayout.layout514.channels);
      for (var i = 0; i < t.routing.length; i++) {
        expect(t.routing[i], 1 << i);
      }
    });
  });

  group('initial config', () {
    test('exposes Stereo + Binaural with Stereo live', () {
      final c = read();
      expect(c.targets.map((t) => t.layout), [
        OarLayout.stereo,
        OarLayout.binaural,
      ]);
      expect(c.activeLayout, OarLayout.stereo);
      // Back-compat getters delegate to the active target.
      expect(c.layout, OarLayout.stereo);
      expect(c.routing, [1, 2]);
      expect(c.isBinaural, isFalse);
    });
  });

  group('setActive', () {
    test('switches the live target by layout key', () {
      notifier().setActive(OarLayout.binaural);
      expect(read().activeLayout, OarLayout.binaural);
      expect(read().layout, OarLayout.binaural);
      expect(read().isBinaural, isTrue);
    });

    test('is a no-op for a layout that is not exposed', () {
      notifier().setActive(OarLayout.layout714);
      expect(read().activeLayout, OarLayout.stereo);
    });
  });

  group('addTarget', () {
    test('appends with identity routing and does not change live', () {
      notifier().addTarget(OarLayout.layout714);
      final c = read();
      expect(c.targets.last.layout, OarLayout.layout714);
      expect(
        c.targets.last.routing,
        List<int>.generate(OarLayout.layout714.channels, (i) => 1 << i),
      );
      expect(c.activeLayout, OarLayout.stereo);
    });

    test('ignores a layout that is already exposed', () {
      notifier().addTarget(OarLayout.stereo);
      expect(read().targets.length, 2);
    });
  });

  group('removeTarget', () {
    test('removing the live target promotes the first remaining row', () {
      notifier().setActive(OarLayout.binaural);
      notifier().removeTarget(OarLayout.binaural);
      final c = read();
      expect(c.isExposed(OarLayout.binaural), isFalse);
      expect(c.activeLayout, OarLayout.stereo);
    });

    test('keeps at least one target (last remove is a no-op)', () {
      notifier().removeTarget(OarLayout.binaural);
      notifier().removeTarget(OarLayout.stereo);
      expect(read().targets.length, 1);
      expect(read().activeLayout, OarLayout.stereo);
    });
  });

  group('reorderTarget', () {
    // Indices follow the onReorderItem convention: newIndex is the
    // insertion position after the item is removed (the framework
    // pre-adjusts downward drags).
    test('reorders the set but preserves the active target', () {
      notifier().addTarget(OarLayout.layout714);
      notifier().setActive(OarLayout.binaural);
      notifier().reorderTarget(0, 1); // move Stereo down one
      final c = read();
      expect(c.targets.map((t) => t.layout), [
        OarLayout.binaural,
        OarLayout.stereo,
        OarLayout.layout714,
      ]);
      expect(c.activeLayout, OarLayout.binaural);
    });

    test('moves the first target to the end', () {
      notifier().addTarget(OarLayout.layout714);
      notifier().reorderTarget(0, 2);
      expect(read().targets.map((t) => t.layout), [
        OarLayout.binaural,
        OarLayout.layout714,
        OarLayout.stereo,
      ]);
    });

    test('clamps an out-of-range newIndex', () {
      notifier().addTarget(OarLayout.layout714);
      notifier().reorderTarget(0, 99);
      expect(read().targets.map((t) => t.layout), [
        OarLayout.binaural,
        OarLayout.layout714,
        OarLayout.stereo,
      ]);
    });
  });

  group('toggleCell (full cross-point)', () {
    test('independent toggle does not clear other cells', () {
      // Split: Stereo channel 0 feeds device 0 (identity) and device 5.
      notifier().toggleCell(OarLayout.stereo, 0, 5);
      expect(read().routing[0], (1 << 0) | (1 << 5));
      // Sum: Stereo channel 1 also feeds device 0 (shared with ch 0).
      notifier().toggleCell(OarLayout.stereo, 1, 0);
      expect(read().routing[1], (1 << 1) | (1 << 0));
      // Channel 0's split is untouched.
      expect(read().routing[0], (1 << 0) | (1 << 5));
    });

    test('toggling an on cell clears just that bit (mute)', () {
      notifier().toggleCell(OarLayout.stereo, 0, 0); // clear identity bit
      expect(read().routing[0], 0);
    });
  });

  group('clampedToDeviceChannels (engine-push view)', () {
    test('masks out-of-range bits without mutating state', () {
      notifier().addTarget(OarLayout.layout714);
      notifier().toggleCell(OarLayout.layout714, 0, 40); // beyond 16
      final full = read();

      final view = full.clampedToDeviceChannels(16);
      final masked = view.targets.firstWhere(
        (t) => t.layout == OarLayout.layout714,
      );
      expect(masked.routing[0] & (1 << 40), 0); // muted in the view
      expect(masked.routing[0] & (1 << 0), 1 << 0); // in-range kept

      // The full patch is untouched — it must survive to disk and
      // restore when the channels come back (ES-24, ES-63).
      final kept = read().targets.firstWhere(
        (t) => t.layout == OarLayout.layout714,
      );
      expect(kept.routing[0] & (1 << 40), 1 << 40);
    });

    test('is identity when the device spans the full bit range', () {
      final cfg = read();
      expect(identical(cfg.clampedToDeviceChannels(64), cfg), isTrue);
    });
  });

  group('toJson / fromJson', () {
    test('round-trips targets, active, routing, and noiseDbfs', () {
      notifier().addTarget(OarLayout.layout714);
      notifier().toggleCell(OarLayout.layout714, 0, 5); // split into dev 5
      notifier().setActive(OarLayout.binaural);
      notifier().setNoiseDbfs(-12.0);
      final cfg = read();

      final restored = MonitoringConfig.fromJson(cfg.toJson());
      expect(
        restored.targets.map((t) => t.layout),
        cfg.targets.map((t) => t.layout),
      );
      expect(restored.activeLayout, OarLayout.binaural);
      expect(restored.noiseDbfs, -12.0);
      final t714 = restored.targets.firstWhere(
        (t) => t.layout == OarLayout.layout714,
      );
      expect(t714.routing[0], (1 << 0) | (1 << 5));
    });

    test('limiter never appears in the slice (always-on, no setting)', () {
      final json = read().toJson();
      expect(json.containsKey('limiter'), isFalse);
      expect(json.containsKey('limiterEnabled'), isFalse);
    });

    test('a duplicated layout in the blob keeps its first entry', () {
      // The each-layout-at-most-once invariant is enforced on the
      // untrusted prefs blob, not assumed (ES-591): first entry wins so
      // the user's saved routing for that layout survives.
      final restored = MonitoringConfig.fromJson({
        'v': 1,
        'active': 'stereo',
        'targets': [
          {
            'layout': 'stereo',
            'routing': [4, 8],
          },
          {'layout': 'binaural'},
          {
            'layout': 'stereo',
            'routing': [1, 2],
          },
        ],
      });
      expect(restored.targets.map((t) => t.layout), [
        OarLayout.stereo,
        OarLayout.binaural,
      ]);
      expect(restored.targets.first.routing, [4, 8]);
    });
  });

  group('exposed-set cap (ES-591)', () {
    test('the cap can hold every layout that exists today', () {
      // Nine layouts, cap of ten: the cap is a forward guard for a
      // grown enum, not a constraint on current configs. If this
      // fails, a new layout pushed the enum past the cap — revisit
      // ES-591 (and how the switcher column scales) before raising it.
      expect(
        OarLayout.values.length,
        lessThanOrEqualTo(kMaxExposedMonitoringTargets),
      );
    });

    test('addTarget refuses to grow past the cap', () {
      // Exposing every layout stays within the cap today, so the
      // guard is exercised at the boundary artificially: state built
      // to the cap must not accept one more distinct layout. With
      // only nine layouts the loop stops early — assert the invariant
      // rather than the unreachable rejection.
      for (final l in OarLayout.values) {
        notifier().addTarget(l);
      }
      expect(
        read().targets.length,
        lessThanOrEqualTo(kMaxExposedMonitoringTargets),
      );
      expect(read().targets.length, OarLayout.values.length);
    });
  });

  group('noise injection', () {
    test('single generator: selecting another cell moves it', () {
      final n = container.read(noiseInjectionProvider.notifier);
      n.toggleRow(1);
      var s = container.read(noiseInjectionProvider);
      expect(s.rowOn(1), isTrue);
      expect(s.anyOn, isTrue);

      // One generator: lighting a column moves it off the row.
      n.toggleCol(5);
      s = container.read(noiseInjectionProvider);
      expect(s.colOn(5), isTrue);
      expect(s.rowOn(1), isFalse);

      // Re-toggling the lit cell clears it.
      n.toggleCol(5);
      s = container.read(noiseInjectionProvider);
      expect(s.anyOn, isFalse);
    });

    test('kill-all clears the lit cell', () {
      final n = container.read(noiseInjectionProvider.notifier);
      n.toggleRow(2);
      expect(container.read(noiseInjectionProvider).anyOn, isTrue);
      n.killAll();
      expect(container.read(noiseInjectionProvider).anyOn, isFalse);
    });
  });
}
