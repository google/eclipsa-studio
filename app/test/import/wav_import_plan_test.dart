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

import 'package:eclipsa_studio/import/wav_import_plan.dart';
import 'package:eclipsa_studio/models/audio_element_enums.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:eclipsa_studio/widgets/element_format_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the batch WAV import / replace planning extracted
/// from elements_view.dart (ES-432): sticky per-channel-count
/// overrides, cancel-aborts-the-batch, profile-bump carry, and the
/// ambiguous-replace decision.
void main() {
  WavInfo info(int channels) => WavInfo(
    channels: channels,
    sampleRate: 48000,
    bitsPerSample: 24,
    audioFormat: 1,
    dataOffset: 44,
    dataSize: channels * 48000 * 3,
    totalSamples: 48000,
  );

  ElementConfig configFor(int channels) =>
      validConfigsForChannelCount(channels).first;

  // A prompt that records its calls and replies from a scripted queue.
  ({FormatPrompt prompt, List<({String path, int channels})> calls})
  scriptedPrompt(List<ElementFormatChoice?> replies) {
    final calls = <({String path, int channels})>[];
    var next = 0;
    Future<ElementFormatChoice?> prompt({
      required String path,
      required WavInfo info,
      required IamfProfile profile,
      required int remainingSameCount,
    }) async {
      calls.add((path: path, channels: info.channels));
      return replies[next++];
    }

    return (prompt: prompt, calls: calls);
  }

  group('planWavBatch', () {
    // Fixture sanity check, not module coverage: the tests below rely
    // on these counts being (un)ambiguous under the base profile.
    test('precondition: 2ch is ambiguous, 4ch is not (base profile)', () {
      expect(elementFormatDialogWouldShow(IamfProfile.base, 2), isTrue);
      expect(elementFormatDialogWouldShow(IamfProfile.base, 4), isFalse);
    });

    test(
      'apply-to-remaining makes a choice sticky per channel count',
      () async {
        final headers = {
          'a.wav': info(2),
          'b.wav': info(2),
          'c.wav': info(6),
          'd.wav': info(2),
        };
        final pick2 = configFor(2);
        final s = scriptedPrompt([
          ElementFormatChoice(pick2, applyToRemaining: true),
          const ElementFormatChoice((
            label: '5.1',
            type: 'Channel',
            layout: '5.1',
            ambisonicsOrder: null,
            isDual: null,
          )),
        ]);
        // c.wav (6ch) must get its own prompt; b/d ride the sticky 2ch
        // choice without prompting.
        final plan = await planWavBatch(
          paths: ['a.wav', 'b.wav', 'c.wav', 'd.wav'],
          headers: headers,
          profile: IamfProfile.base,
          allowProfileBump: false,
          prompt: s.prompt,
        );
        expect(plan, isNotNull);
        expect(s.calls.map((c) => c.path), ['a.wav', 'c.wav']);
        expect(plan!.overrides['a.wav'], pick2);
        expect(plan.overrides['b.wav'], pick2);
        expect(plan.overrides['d.wav'], pick2);
        expect(plan.overrides['c.wav']!.label, '5.1');
      },
    );

    test('without apply-to-remaining every ambiguous file prompts', () async {
      final headers = {'a.wav': info(2), 'b.wav': info(2)};
      final s = scriptedPrompt([
        ElementFormatChoice(configFor(2)),
        ElementFormatChoice(configFor(2)),
      ]);
      final plan = await planWavBatch(
        paths: ['a.wav', 'b.wav'],
        headers: headers,
        profile: IamfProfile.base,
        allowProfileBump: false,
        prompt: s.prompt,
      );
      expect(plan, isNotNull);
      expect(s.calls.length, 2);
    });

    test('cancel aborts the whole batch before later prompts', () async {
      final headers = {'a.wav': info(2), 'b.wav': info(6)};
      final s = scriptedPrompt([null, ElementFormatChoice(configFor(6))]);
      final plan = await planWavBatch(
        paths: ['a.wav', 'b.wav'],
        headers: headers,
        profile: IamfProfile.base,
        allowProfileBump: false,
        prompt: s.prompt,
      );
      expect(plan, isNull);
      expect(s.calls.length, 1, reason: 'no prompt after the cancel');
    });

    test('unambiguous and unreadable files are never prompted', () async {
      final headers = {'four.wav': info(4)}; // 'bad.wav' unreadable
      final s = scriptedPrompt([]);
      final plan = await planWavBatch(
        paths: ['four.wav', 'bad.wav'],
        headers: headers,
        profile: IamfProfile.base,
        allowProfileBump: false,
        prompt: s.prompt,
      );
      expect(plan, isNotNull);
      expect(s.calls, isEmpty);
      expect(plan!.overrides, isEmpty);
      // A prompt-free batch must never mutate the profile.
      expect(plan.profile, IamfProfile.base);
    });

    test('a confirmed bump re-parameterizes later prompts and lands on '
        'the plan', () async {
      final headers = {'a.wav': info(2), 'b.wav': info(6)};
      final profiles = <IamfProfile>[];
      var next = 0;
      final replies = [
        ElementFormatChoice(configFor(2), bumpTo: IamfProfile.baseEnhanced),
        ElementFormatChoice(configFor(6)),
      ];
      Future<ElementFormatChoice?> prompt({
        required String path,
        required WavInfo info,
        required IamfProfile profile,
        required int remainingSameCount,
      }) async {
        profiles.add(profile);
        return replies[next++];
      }

      final plan = await planWavBatch(
        paths: ['a.wav', 'b.wav'],
        headers: headers,
        profile: IamfProfile.base,
        allowProfileBump: true,
        prompt: prompt,
      );
      expect(plan, isNotNull);
      expect(profiles, [IamfProfile.base, IamfProfile.baseEnhanced]);
      expect(plan!.profile, IamfProfile.baseEnhanced);
    });

    test(
      'remainingSameCount counts only later files of the same count',
      () async {
        final headers = {
          'a.wav': info(2),
          'b.wav': info(6),
          'c.wav': info(2),
          'd.wav': info(2),
        };
        final remaining = <int>[];
        Future<ElementFormatChoice?> prompt({
          required String path,
          required WavInfo info,
          required IamfProfile profile,
          required int remainingSameCount,
        }) async {
          remaining.add(remainingSameCount);
          return ElementFormatChoice(configFor(info.channels));
        }

        final plan = await planWavBatch(
          paths: ['a.wav', 'b.wav', 'c.wav', 'd.wav'],
          headers: headers,
          profile: IamfProfile.base,
          allowProfileBump: false,
          prompt: prompt,
        );
        expect(plan, isNotNull);
        // a.wav sees c+d (2 more 2ch); b.wav sees no more 6ch; c sees d.
        expect(remaining, [2, 0, 1, 0]);
      },
    );
  });

  group('planWavReplace', () {
    test('same channel count proceeds without a prompt', () async {
      final s = scriptedPrompt([]);
      final plan = await planWavReplace(
        path: 'x.wav',
        newInfo: info(2),
        currentChannels: 2,
        profile: IamfProfile.base,
        prompt: s.prompt,
      );
      expect(plan.aborted, isFalse);
      expect(plan.override, isNull);
      expect(s.calls, isEmpty);
    });

    test('undecodable WAV proceeds unprompted (assignment reports)', () async {
      final s = scriptedPrompt([]);
      final plan = await planWavReplace(
        path: 'x.wav',
        newInfo: null,
        currentChannels: 2,
        profile: IamfProfile.base,
        prompt: s.prompt,
      );
      expect(plan.aborted, isFalse);
      expect(s.calls, isEmpty);
    });

    test('different channel count prompts and applies the choice', () async {
      final pick = configFor(6);
      final s = scriptedPrompt([ElementFormatChoice(pick)]);
      final plan = await planWavReplace(
        path: 'x.wav',
        newInfo: info(6),
        currentChannels: 2,
        profile: IamfProfile.base,
        prompt: s.prompt,
      );
      expect(plan.aborted, isFalse);
      expect(plan.override, pick);
      expect(s.calls.single.channels, 6);
    });

    test('cancelling the prompt keeps the current element', () async {
      final s = scriptedPrompt([null]);
      final plan = await planWavReplace(
        path: 'x.wav',
        newInfo: info(6),
        currentChannels: 2,
        profile: IamfProfile.base,
        prompt: s.prompt,
      );
      expect(plan.aborted, isTrue);
      expect(plan.override, isNull);
    });
  });
}
