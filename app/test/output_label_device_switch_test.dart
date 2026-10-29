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

// An output-label field in the monitoring routing matrix that has focus
// across a device switch must not write its text into the new device's
// labels (ES-845).

import 'package:eclipsa_studio/ffi_bridge.dart' show AudioDeviceInfo;
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/views/routing_matrix_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

AudioDeviceInfo _device(int index, String name) => AudioDeviceInfo(
  index: index,
  name: name,
  isDefault: index == 0,
  maxChannels: 2,
);

/// Devices A and B, replaceable by a test.
class _Devices extends AudioDevicesNotifier {
  @override
  List<AudioDeviceInfo> build() => [_device(0, 'A'), _device(1, 'B')];

  void setDevices(List<AudioDeviceInfo> devices) => state = devices;
}

void main() {
  late ProviderContainer container;

  /// Writes to the labels made after [countWrites] is called.
  var writes = 0;

  Future<void> pumpMatrix(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [audioDevicesProvider.overrideWith(_Devices.new)],
    );
    // Unmount before the container goes: RoutingMatrixView's dispose
    // reads it, and a test that fails leaves its tree mounted.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
    container.read(outputLabelsProvider.notifier).replaceAll({0: 'Left A'});
    container.listen(outputLabelsProvider, (_, _) => writes++);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RoutingMatrixView()),
      ),
    );
    await tester.pumpAndSettle();
  }

  void countWrites() => writes = 0;

  Finder labelField(String text) => find.widgetWithText(TextField, text).first;

  void selectDevice(int index) {
    final settings = container.read(audioSettingsProvider);
    container
        .read(audioSettingsProvider.notifier)
        .update(settings.copyWith(deviceIndex: index));
  }

  /// Applies device B's saved labels, as AppShell's
  /// applyMonitoringForDevice does after it reads the preferences.
  void applyLabelsOfB() {
    container.read(outputLabelsProvider.notifier).replaceAll({0: 'Left B'});
  }

  Future<void> blur(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  testWidgets('an edit on one device is saved as its label', (tester) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.enterText(labelField('Left A'), 'Main L');
    countWrites();
    await blur(tester);
    expect(container.read(outputLabelsProvider)[0], 'Main L');
    expect(writes, 1);
  });

  testWidgets('submit then blur writes once', (tester) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.enterText(labelField('Left A'), 'Main L');
    countWrites();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(container.read(outputLabelsProvider)[0], 'Main L');
    expect(writes, 1);
  });

  testWidgets('a blur without an edit writes nothing', (tester) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.pump();
    countWrites();
    await blur(tester);
    expect(writes, 0);
  });

  testWidgets('a focused field does not write into the next device', (
    tester,
  ) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.pump();
    selectDevice(1);
    applyLabelsOfB();
    await tester.pump();
    countWrites();
    await blur(tester);
    expect(container.read(outputLabelsProvider)[0], 'Left B');
    expect(writes, 0);
    expect(find.widgetWithText(TextField, 'Left B'), findsOneWidget);
  });

  testWidgets('a draft typed before the switch is discarded', (tester) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.enterText(labelField('Left A'), 'Draft');
    selectDevice(1);
    applyLabelsOfB();
    await tester.pump();
    countWrites();
    await blur(tester);
    expect(container.read(outputLabelsProvider)[0], 'Left B');
    expect(writes, 0);
  });

  testWidgets('a blur before the new labels arrive writes nothing', (
    tester,
  ) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.enterText(labelField('Left A'), 'Draft');
    selectDevice(1);
    await tester.pump();
    countWrites();
    await blur(tester);
    expect(writes, 0);
    applyLabelsOfB();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Left B'), findsOneWidget);
  });

  testWidgets('a field focused before the new labels arrive writes nothing', (
    tester,
  ) async {
    await pumpMatrix(tester);
    selectDevice(1);
    await tester.pump();
    await tester.tap(labelField('Left A'));
    await tester.pump();
    applyLabelsOfB();
    await tester.pump();
    countWrites();
    await blur(tester);
    expect(container.read(outputLabelsProvider)[0], 'Left B');
    expect(writes, 0);
  });

  testWidgets('a new device at the same index discards the draft', (
    tester,
  ) async {
    await pumpMatrix(tester);
    await tester.tap(labelField('Left A'));
    await tester.enterText(labelField('Left A'), 'Draft');
    // Device A disappears and C takes index 0.
    (container.read(audioDevicesProvider.notifier) as _Devices).setDevices([
      _device(0, 'C'),
    ]);
    await tester.pump();
    countWrites();
    await blur(tester);
    expect(writes, 0);
  });

  // AppShell reads the device name in a device-index listener it
  // registers in initState, before anything else reads the name.
  testWidgets('a device index listener reads the new device name', (
    tester,
  ) async {
    final c = ProviderContainer(
      overrides: [audioDevicesProvider.overrideWith(_Devices.new)],
    );
    final names = <String?>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: _DeviceNameListener(names),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
    for (final index in [1, 0, 1]) {
      final settings = c.read(audioSettingsProvider);
      c
          .read(audioSettingsProvider.notifier)
          .update(settings.copyWith(deviceIndex: index));
    }
    expect(names, ['B', 'A', 'B']);
  });
}

/// Records [selectedOutputDeviceName] from a device-index listener
/// registered in initState, as AppShell's StartupRestore does.
class _DeviceNameListener extends ConsumerStatefulWidget {
  const _DeviceNameListener(this.names);
  final List<String?> names;

  @override
  ConsumerState<_DeviceNameListener> createState() =>
      _DeviceNameListenerState();
}

class _DeviceNameListenerState extends ConsumerState<_DeviceNameListener> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(
      audioSettingsProvider.select((s) => s.deviceIndex),
      (_, _) => widget.names.add(selectedOutputDeviceName(ref)),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
