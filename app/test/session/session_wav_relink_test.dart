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

// ES-628: a session whose WAVs cannot be loaded must say which failure it
// hit and offer the matching remedy. The WAV probe is stubbed, so
// "readable" here means what the sandbox would decide at runtime: a file
// can sit on disk and still refuse to open.

import 'dart:convert';
import 'dart:io';

import 'package:eclipsa_studio/session/session_model.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/waveform/wav_decoder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../support/session_env.dart';

/// A readable 2-channel file, as the engine probe reports it.
String _okProbe() => jsonEncode({
  'ok': true,
  'recovered': false,
  'metadata_dropped': false,
  'container': 'wav',
  'channels': 2,
  'sample_rate': 48000,
  'bits_per_sample': 24,
  'is_float': false,
  'num_frames': 48000,
  'data_offset': 44,
  'data_size': 48000 * 6,
  'axml_bytes': 0,
  'chna_bytes': 0,
});

/// What the sandbox produces for a file it will not hand over — the
/// error [WavDecoder] turns into a [FileSystemException].
String _refusedProbe(String path) =>
    jsonEncode({'ok': false, 'error': 'Cannot open WAV file: $path'});

/// A file that opens but is not a WAV.
String _corruptProbe() =>
    jsonEncode({'ok': false, 'error': 'not a RIFF/WAVE file'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir; // the session folder
  late Directory outside; // media that does not live below the session
  late Directory support; // app-support root
  late Set<String> readable; // paths the stubbed probe accepts

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wav_relink_session');
    outside = await Directory.systemTemp.createTemp('wav_relink_media');
    support = await Directory.systemTemp.createTemp('wav_relink_support');
    PathProviderPlatform.instance = FakePathProvider(support.path);
    readable = <String>{};
    WavDecoder.probeForTesting = (path) => readable.contains(path)
        ? _okProbe()
        : p.basename(path) == 'corrupt.wav'
        ? _corruptProbe()
        : _refusedProbe(path);
  });

  tearDown(() async {
    WavDecoder.probeForTesting = null;
    SessionNotifier.folderPickerForTesting = null;
    SessionNotifier.wavPickerForTesting = null;
    for (final d in [dir, outside, support]) {
      await d.delete(recursive: true);
    }
  });

  /// A file that exists on disk. Contents never matter: the probe is
  /// stubbed, and the production path only stats the file before probing.
  String touch(String path) {
    File(path).writeAsStringSync('RIFF');
    return path;
  }

  /// Writes `<dir>/session.esp` referencing [wavPaths] (ids 1..n) and
  /// returns its path.
  Future<String> writeSession(
    List<String> wavPaths, {
    String layout = 'Stereo',
  }) async {
    final esp = p.join(dir.path, 'session.esp');
    final session = SessionModel(
      iamfProfile: IamfProfile.baseEnhanced,
      elements: [
        for (var i = 0; i < wavPaths.length; i++)
          AudioElement(
            id: i + 1,
            name: p.basenameWithoutExtension(wavPaths[i]),
            type: 'Channel',
            layout: layout,
            codec: 'LPCM',
            color: 0xFF888888,
            wavPath: wavPaths[i],
          ),
      ],
    );
    await File(esp).writeAsString(session.encode(relativeTo: dir.path));
    return esp;
  }

  /// A container wired like the running app: the listener mirrors
  /// `DirtyTracker` (session/dirty_tracker.dart), whose `loading` guard is
  /// what keeps a header re-read from counting as an edit.
  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [recentSessionsProvider.overrideWith(StubRecentSessions.new)],
    );
    addTearDown(c.dispose);
    c.listen(elementsProvider, (_, _) {
      if (!c.read(sessionProvider).loading) {
        c.read(sessionProvider.notifier).markDirty();
      }
    });
    return c;
  }

  Future<ProviderContainer> load(String esp) async {
    final c = makeContainer();
    expect(await c.read(sessionProvider.notifier).loadFile(esp), isTrue);
    return c;
  }

  // The sandbox verdicts below only hold where there is a sandbox.
  final macOnly = Platform.isMacOS
      ? null
      : 'sandbox classification is macOS-only';

  group('the notice names the failure and carries its remedy', () {
    test(
      'a WAV beside the session that will not open offers a grant',
      () async {
        final wav = touch(p.join(dir.path, 'bed.wav'));
        final c = await load(await writeSession([wav]));

        final notice = c.read(importNoticeProvider);
        expect(notice, isNotNull);
        expect(notice!.title, 'Audio Files Not Accessible');
        expect(notice.actionLabel, 'Grant Access…');
        expect(notice.onAction, isNotNull);
        expect(notice.message, contains('bed.wav'));
        expect(c.read(elementsProvider).single.wavInfo, isNull);
      },
      skip: macOnly,
    );

    test('a WAV that is not on disk at all offers a relink', () async {
      final wav = p.join(outside.path, 'gone.wav'); // never created
      final c = await load(await writeSession([wav]));

      final notice = c.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(notice!.title, 'Missing Audio Files');
      expect(notice.actionLabel, 'Locate…');
      expect(notice.message, contains('gone.wav'));
    });

    test('the grant comes first when a load hits both failures', () async {
      final beside = touch(p.join(dir.path, 'bed.wav'));
      final gone = p.join(outside.path, 'gone.wav');
      final c = await load(await writeSession([beside, gone]));

      final notice = c.read(importNoticeProvider);
      expect(notice!.title, 'Audio Files Not Accessible');
      expect(notice.message, contains('bed.wav'));
      expect(
        notice.message,
        isNot(contains('gone.wav')),
        reason: 'the reload after the grant raises the Locate… notice',
      );
    }, skip: macOnly);

    test('a file the parser rejects offers a relink, not a grant', () async {
      // Present, beside the session — the location rule alone would call
      // this a grant problem, and granting would raise the same notice
      // again.
      final wav = touch(p.join(dir.path, 'corrupt.wav'));
      final c = await load(await writeSession([wav]));

      final notice = c.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(notice!.title, 'Audio Files Could Not Be Read');
      expect(notice.actionLabel, 'Locate…');
      expect(notice.message, contains('corrupt.wav'));
    });

    test('a session whose WAVs all load raises nothing', () async {
      final wav = touch(p.join(dir.path, 'bed.wav'));
      readable.add(wav);
      final c = await load(await writeSession([wav]));

      expect(c.read(importNoticeProvider), isNull);
      expect(c.read(elementsProvider).single.wavInfo, isNotNull);
    });
  });

  group('Grant Access…', () {
    test('reloads the media without dirtying the session', () async {
      final wav = touch(p.join(dir.path, 'bed.wav'));
      final c = await load(await writeSession([wav]));
      expect(c.read(elementsProvider).single.wavInfo, isNull);
      // The shell clears the notice as it shows the dialog, so the action
      // runs against an empty provider.
      c.read(importNoticeProvider.notifier).clear();

      readable.add(wav); // the grant is what makes the file openable
      String? startedIn;
      SessionNotifier.folderPickerForTesting = (initial) async {
        startedIn = initial;
        return dir.path;
      };
      await c.read(sessionProvider.notifier).grantSessionFolderAccess();

      expect(startedIn, dir.path, reason: 'the panel starts on the session');
      expect(c.read(elementsProvider).single.wavInfo, isNotNull);
      expect(c.read(importNoticeProvider), isNull);
      expect(c.read(sessionProvider).loading, isFalse);
      expect(
        c.read(sessionProvider).dirty,
        isFalse,
        reason: 'a header re-read is not an edit',
      );
    });

    test('raises the relink notice for what the grant did not cover', () async {
      final beside = touch(p.join(dir.path, 'bed.wav'));
      final gone = p.join(outside.path, 'gone.wav');
      final c = await load(await writeSession([beside, gone]));
      c.read(importNoticeProvider.notifier).clear();

      readable.add(beside);
      SessionNotifier.folderPickerForTesting = (_) async => dir.path;
      await c.read(sessionProvider.notifier).grantSessionFolderAccess();

      final notice = c.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(notice!.title, 'Missing Audio Files');
      expect(notice.message, contains('gone.wav'));
      expect(c.read(elementsProvider).first.wavInfo, isNotNull);
    });

    test('a WAV gone from the session folder offers a relink after the '
        'grant', () async {
      // Before the grant the sandbox refuses even the stat, so the load
      // cannot tell a deleted file from an ungranted one and offers the
      // grant. After it the stat is reliable: the file is missing, and
      // the remedy is Locate…, not the folder panel again.
      final gone = p.join(dir.path, 'gone.wav'); // never created
      final c = await load(await writeSession([gone]));
      c.read(importNoticeProvider.notifier).clear();
      SessionNotifier.folderPickerForTesting = (_) async => dir.path;

      await c.read(sessionProvider.notifier).grantSessionFolderAccess();

      final notice = c.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(notice!.title, 'Missing Audio Files');
      expect(notice.actionLabel, 'Locate…');
      expect(notice.message, contains('gone.wav'));
      expect(c.read(elementsProvider).single.wavInfo, isNull);
    });

    test('a cancelled panel changes nothing', () async {
      final wav = touch(p.join(dir.path, 'bed.wav'));
      final c = await load(await writeSession([wav]));
      readable.add(wav); // would load, if the panel were confirmed
      SessionNotifier.folderPickerForTesting = (_) async => null;

      await c.read(sessionProvider.notifier).grantSessionFolderAccess();

      expect(c.read(elementsProvider).single.wavInfo, isNull);
      expect(c.read(sessionProvider).dirty, isFalse);
    });
  });

  group('relink', () {
    test(
      'rewrites the path, dirties the session, and survives a save',
      () async {
        final esp = await writeSession([p.join(outside.path, 'gone.wav')]);
        final c = await load(esp);
        final moved = touch(p.join(outside.path, 'renamed.wav'));
        readable.add(moved);
        final id = c.read(elementsProvider).single.id;

        expect(
          await c.read(sessionProvider.notifier).relinkWav(id, moved),
          isTrue,
        );
        expect(c.read(elementsProvider).single.wavPath, moved);
        expect(c.read(elementsProvider).single.wavInfo, isNotNull);
        expect(c.read(sessionProvider).dirty, isTrue);

        expect(await c.read(sessionProvider.notifier).saveToPath(esp), isTrue);
        final json = await File(esp).readAsString();
        expect(
          (jsonDecode(json)['elements'] as List).single['wavPath'],
          isNot(startsWith('/')),
          reason: 'media paths stay relative to the session file',
        );
        final saved = SessionModel.decode(json, resolveFrom: dir.path);
        expect(saved.elements.single.wavPath, moved);
      },
    );

    test('a file that is not a WAV is refused and changes nothing', () async {
      final gone = p.join(outside.path, 'gone.wav');
      final c = await load(await writeSession([gone]));
      c.read(importNoticeProvider.notifier).clear();
      final corrupt = touch(p.join(outside.path, 'corrupt.wav'));
      final id = c.read(elementsProvider).single.id;

      expect(
        await c.read(sessionProvider.notifier).relinkWav(id, corrupt),
        isFalse,
      );
      final notice = c.read(importNoticeProvider);
      expect(notice!.title, 'Relink Failed');
      expect(notice.message, contains('corrupt.wav'));
      expect(c.read(elementsProvider).single.wavPath, gone);
      expect(c.read(sessionProvider).dirty, isFalse);
    });

    test('a file with the wrong channel count is refused', () async {
      final gone = p.join(outside.path, 'gone.wav');
      final c = await load(await writeSession([gone], layout: '7.1.4'));
      c.read(importNoticeProvider.notifier).clear();
      final stereo = touch(p.join(outside.path, 'stereo.wav')); // 2 channels
      readable.add(stereo);
      final id = c.read(elementsProvider).single.id;

      expect(
        await c.read(sessionProvider.notifier).relinkWav(id, stereo),
        isFalse,
      );
      final notice = c.read(importNoticeProvider);
      expect(notice!.title, 'Relink Failed');
      expect(notice.message, contains('2 channels'));
      expect(notice.message, contains('12 channels'));
      expect(c.read(elementsProvider).single.wavPath, gone);
      expect(c.read(sessionProvider).dirty, isFalse);
    });

    test(
      'Locate… prompts only failed elements and stops at a cancel',
      () async {
        final good = touch(p.join(dir.path, 'good.wav'));
        readable.add(good);
        final a = p.join(outside.path, 'a.wav');
        final b = p.join(outside.path, 'b.wav');
        final c = await load(await writeSession([good, a, b]));
        final found = touch(p.join(outside.path, 'a_found.wav'));
        readable.add(found);

        final startedIn = <String?>[];
        SessionNotifier.wavPickerForTesting = (initial) async {
          startedIn.add(initial);
          return startedIn.length == 1 ? found : null; // cancel the second
        };
        await c.read(sessionProvider.notifier).locateMissingWavs();

        expect(
          startedIn,
          [dir.path, dir.path],
          reason:
              'the loaded element is never prompted; both panels start '
              'in the session folder',
        );
        final elements = c.read(elementsProvider);
        expect(elements[0].wavPath, good);
        expect(elements[1].wavPath, found);
        expect(elements[1].wavInfo, isNotNull);
        expect(elements[2].wavPath, b, reason: 'the cancel stopped the walk');
        expect(elements[2].wavInfo, isNull);
      },
    );
  });
}
