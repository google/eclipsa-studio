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

// Hermetic tests for Playback-mode monitoring solo/mute bookkeeping on
// PlaybackSessionNotifier (ES-284). The engine provider is overridden to
// null (no dylib in the test environment); the notifier's setters must
// still keep the Dart-side state correct — the engine mirror is a
// fire-and-forget null-guarded call.

import 'package:eclipsa_studio/ffi_bridge.dart' show PlaybackAe, PlaybackAeKind;
import 'package:eclipsa_studio/meters/meter_provider.dart';
import 'package:eclipsa_studio/playback/iamf_probe.dart';
import 'package:eclipsa_studio/playback/playback_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _report = IamfProbeReport(
  ok: true,
  errorMessage: null,
  sampleRate: 48000,
  totalSamples: 48000,
  audioElements: [],
  mixPresentations: [],
);

const _aes = [
  PlaybackAe(
    audioElementId: 11,
    kind: PlaybackAeKind.channelBased,
    numChannels: 2,
    layoutInfo: 0,
  ),
  PlaybackAe(
    audioElementId: 12,
    kind: PlaybackAeKind.sceneBased,
    numChannels: 4,
    layoutInfo: 1,
  ),
];

void main() {
  late ProviderContainer container;
  late PlaybackSessionNotifier notifier;

  setUp(() {
    container = ProviderContainer(
      overrides: [eclipsaStudioEngineProvider.overrideWithValue(null)],
    );
    notifier = container.read(playbackSessionProvider.notifier);
    notifier.open(
      path: '/tmp/test.iamf',
      report: _report,
      sampleRate: 48000,
      totalFrames: 48000,
      audioElements: _aes,
    );
  });

  tearDown(() => container.dispose());

  test('opens with no solo/mute set', () {
    final s = container.read(playbackSessionProvider)!;
    expect(s.soloedAeIds, isEmpty);
    expect(s.mutedAeIds, isEmpty);
  });

  test('setAeSolo / setAeMute update the per-element sets', () {
    notifier.setAeSolo(11, true);
    notifier.setAeMute(12, true);
    var s = container.read(playbackSessionProvider)!;
    expect(s.soloedAeIds, {11});
    expect(s.mutedAeIds, {12});

    notifier.setAeSolo(11, false);
    s = container.read(playbackSessionProvider)!;
    expect(s.soloedAeIds, isEmpty);
    expect(s.mutedAeIds, {12});
  });

  test('no-op writes do not publish a new state', () {
    final before = container.read(playbackSessionProvider);
    notifier.setAeSolo(11, false);
    notifier.setAeMute(12, false);
    expect(identical(container.read(playbackSessionProvider), before), isTrue);
  });

  test('solo/mute survive a mix-presentation index change', () {
    notifier.setAeSolo(11, true);
    notifier.setAeMute(12, true);
    // updateTotalFrames goes through copyWith like setActiveMix does
    // (setActiveMix itself needs a report with presentations).
    notifier.updateTotalFrames(96000);
    final s = container.read(playbackSessionProvider)!;
    expect(s.soloedAeIds, {11});
    expect(s.mutedAeIds, {12});
  });

  test('reopening starts clean', () {
    notifier.setAeMute(11, true);
    notifier.open(
      path: '/tmp/other.iamf',
      report: _report,
      sampleRate: 48000,
      totalFrames: 48000,
      audioElements: _aes,
    );
    final s = container.read(playbackSessionProvider)!;
    expect(s.mutedAeIds, isEmpty);
  });
}
