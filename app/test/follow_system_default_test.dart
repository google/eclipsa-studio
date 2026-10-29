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

import 'package:eclipsa_studio/ffi_bridge.dart' show AudioDeviceInfo;
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart unit tests for [followSystemDefaultAction], the device-poll
/// decision rule for follow-system-default output mode (ES-467). Pins the
/// three outcomes: no action, re-pin on an enumeration index shift, and
/// reopen when the OS default moved to a different device — including
/// the disconnect/reconnect cycle from the original bug report.
void main() {
  AudioDeviceInfo dev(int index, String name, {bool isDefault = false}) =>
      AudioDeviceInfo(
        index: index,
        name: name,
        isDefault: isDefault,
        maxChannels: 2,
      );

  test('no default, open device at the same index -> no action', () {
    final devices = [dev(0, 'Speakers'), dev(1, 'Headset')];
    expect(followSystemDefaultAction(devices, 'Speakers', 0), isNull);
  });

  test('no default, open device reindexed -> re-pin, no reopen', () {
    // A device without the default flag was plugged in ahead of the
    // open one (ES-949).
    final devices = [dev(0, 'Interface'), dev(1, 'Speakers')];
    final action = followSystemDefaultAction(devices, 'Speakers', 0);
    expect(action, isNotNull);
    expect(action!.index, 1);
    expect(action.reopen, isFalse);
  });

  test('no default, open device gone -> no action', () {
    final devices = [dev(0, 'Interface')];
    expect(followSystemDefaultAction(devices, 'Speakers', 0), isNull);
  });

  test('no default, nothing resolved (null open name) -> no action', () {
    final devices = [dev(0, 'Speakers'), dev(1, 'Headset')];
    expect(followSystemDefaultAction(devices, null, -1), isNull);
  });

  test('empty list -> no action', () {
    expect(followSystemDefaultAction(const [], 'Speakers', 0), isNull);
  });

  test('default is the open device at the same index -> no action', () {
    final devices = [dev(0, 'Speakers', isDefault: true), dev(1, 'Headset')];
    expect(followSystemDefaultAction(devices, 'Speakers', 0), isNull);
  });

  test('open device still default but reindexed -> re-pin, no reopen', () {
    // Something hot-plugged ahead of the open device: its enumeration
    // index shifted from 0 to 1 while it kept the default flag.
    final devices = [dev(0, 'Headset'), dev(1, 'Speakers', isDefault: true)];
    final action = followSystemDefaultAction(devices, 'Speakers', 0);
    expect(action, isNotNull);
    expect(action!.index, 1);
    expect(action.reopen, isFalse);
  });

  test('OS default moved to another device -> reopen onto it', () {
    // The ES-467 repro, reconnect half: the headset came back and the OS
    // made it default while the app is still on the speakers.
    final devices = [dev(0, 'Speakers'), dev(1, 'Headset', isDefault: true)];
    final action = followSystemDefaultAction(devices, 'Speakers', 0);
    expect(action, isNotNull);
    expect(action!.index, 1);
    expect(action.reopen, isTrue);
  });

  test('open device disappeared -> reopen onto the new default', () {
    // The ES-467 repro, disconnect half: the open headset vanished and
    // the default flag moved to the speakers.
    final devices = [dev(0, 'Speakers', isDefault: true)];
    final action = followSystemDefaultAction(devices, 'Headset', 1);
    expect(action, isNotNull);
    expect(action!.index, 0);
    expect(action.reopen, isTrue);
  });

  test('nothing resolved yet (null open name) -> reopen onto default', () {
    final devices = [dev(0, 'Speakers', isDefault: true), dev(1, 'Headset')];
    final action = followSystemDefaultAction(devices, null, -1);
    expect(action, isNotNull);
    expect(action!.index, 0);
    expect(action.reopen, isTrue);
  });
}
