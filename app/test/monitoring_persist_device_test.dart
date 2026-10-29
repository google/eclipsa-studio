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

// The monitoring config and output labels are saved under the device they
// were loaded for, which can differ from the device at the selection index
// (ES-949).

import 'dart:convert';
import 'dart:io';

import 'package:eclipsa_studio/ffi_bridge.dart' show AudioDeviceInfo;
import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/session/app_preferences.dart';
import 'package:eclipsa_studio/session/monitoring_store.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/widgets/app_shell.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/session_env.dart';

AudioDeviceInfo _device(int index, String name) =>
    AudioDeviceInfo(index: index, name: name, isDefault: false, maxChannels: 2);

/// Devices A and B, replaceable by a test.
class _Devices extends AudioDevicesNotifier {
  @override
  List<AudioDeviceInfo> build() => [_device(0, 'A'), _device(1, 'B')];

  void setDevices(List<AudioDeviceInfo> devices) => state = devices;
}

final _configA = MonitoringConfig.initial();
final _configB = MonitoringConfig.initial().copyWith(noiseDbfs: -20);

void main() {
  late Directory support;
  late ProviderContainer container;
  late WidgetRef ref;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('monitoring_persist');
    PathProviderPlatform.instance = FakePathProvider(support.path);
    await File('${support.path}/preferences.json').writeAsString(
      json.encode({
        AppPreferences.kMonitoringByDevice: {
          'A': encodeDevice(_configA, const {0: 'Left A'}),
          'B': encodeDevice(_configB, const {0: 'Left B'}),
        },
      }),
    );
  });

  tearDown(() => support.delete(recursive: true));

  Future<void> pumpListeners(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        audioDevicesProvider.overrideWith(_Devices.new),
        eclipsaStudioEngineProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _MonitoringListeners((r) => ref = r),
      ),
    );
  }

  Future<({MonitoringConfig config, Map<int, String> labels})?> saved(
    String device,
  ) async => monitoringForDeviceIn(await AppPreferences.load(), device);

  Future<void> until(bool Function() condition, String what) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: '$what within 2 s');
  }

  testWidgets('an edit before the first apply saves nothing', (tester) async {
    await pumpListeners(tester);
    await tester.runAsync(() async {
      // The providers hold the built-in defaults, which belong to no
      // device.
      container.read(outputLabelsProvider.notifier).setLabel(0, 'Main L');

      await monitoringSavesSettled();
      expect((await saved('A'))!.labels, {0: 'Left A'});
      expect((await saved('B'))!.labels, {0: 'Left B'});
    });
  });

  testWidgets('an edit while a device switch loads stays with the old '
      'device', (tester) async {
    await pumpListeners(tester);
    await tester.runAsync(() async {
      await applyMonitoringForDevice(ref);
      expect(container.read(outputLabelsProvider), {0: 'Left A'});

      // The index listener starts B's apply, which awaits the
      // preferences while the providers still hold A's state.
      final settings = container.read(audioSettingsProvider);
      container
          .read(audioSettingsProvider.notifier)
          .update(settings.copyWith(deviceIndex: 1));
      container
          .read(monitoringConfigProvider.notifier)
          .setActive(OarLayout.binaural);

      await until(
        () => mapEquals(container.read(outputLabelsProvider), {0: 'Left B'}),
        "B's apply finished",
      );
      await monitoringSavesSettled();
      final a = (await saved('A'))!;
      final b = (await saved('B'))!;
      expect(a.config.activeLayout, OarLayout.binaural);
      expect(a.labels, {0: 'Left A'});
      expect(b.config.activeLayout, OarLayout.stereo);
      expect(b.config.noiseDbfs, -20);
      expect(b.labels, {0: 'Left B'});
    });
  });

  testWidgets('an edit after the device list moved under the selection '
      'stays with the old device', (tester) async {
    await pumpListeners(tester);
    await tester.runAsync(() async {
      await applyMonitoringForDevice(ref);

      // C takes index 0 and the selection index is not updated, as after
      // a failed reopen.
      (container.read(audioDevicesProvider.notifier) as _Devices).setDevices([
        _device(0, 'C'),
        _device(1, 'A'),
        _device(2, 'B'),
      ]);
      container.read(outputLabelsProvider.notifier).setLabel(0, 'Main L');

      await monitoringSavesSettled();
      expect(await saved('C'), isNull);
      expect((await saved('A'))!.labels, {0: 'Main L'});
      expect((await saved('B'))!.labels, {0: 'Left B'});
    });
  });
}

/// Registers the listeners StartupRestore registers in initState: an edit
/// to the config or the labels persists them, and a new selection index
/// applies that device's saved state. StartupRestore itself also runs its
/// startup restore, whose preferences read would run in the fake-async
/// zone of the test.
class _MonitoringListeners extends ConsumerStatefulWidget {
  const _MonitoringListeners(this.onRef);
  final void Function(WidgetRef ref) onRef;

  @override
  ConsumerState<_MonitoringListeners> createState() =>
      _MonitoringListenersState();
}

class _MonitoringListenersState extends ConsumerState<_MonitoringListeners> {
  @override
  void initState() {
    super.initState();
    widget.onRef(ref);
    ref.listenManual(
      monitoringConfigProvider,
      (_, _) => persistMonitoringForDevice(ref),
    );
    ref.listenManual(
      outputLabelsProvider,
      (_, _) => persistMonitoringForDevice(ref),
    );
    ref.listenManual(audioSettingsProvider.select((s) => s.deviceIndex), (
      prev,
      next,
    ) {
      if (prev == null || prev == next) return;
      applyMonitoringForDevice(ref);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
