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

// The app's launch parameters (ES-924): the file options and their old
// names, the environment fallbacks, --quit-after-load and --help, and
// the file-type check behind --open.

import 'dart:convert';

import 'package:eclipsa_studio/workspace/launch_args.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLaunchArgs', () {
    test('no options and no environment opens nothing', () {
      final a = parseLaunchArgs(const []);
      expect(a.openPath, isNull);
      expect(a.quitAfterLoad, isFalse);
      expect(a.help, isFalse);
      expect(a.unknown, isEmpty);
    });

    test('each file option sets the path and the kind', () {
      for (final (option, kind) in [
        ('--open', LaunchOpenKind.auto),
        ('--session', LaunchOpenKind.session),
        ('--playback', LaunchOpenKind.playback),
        ('--iamf', LaunchOpenKind.playback),
      ]) {
        final a = parseLaunchArgs([option, '/f/x']);
        expect(a.openPath, '/f/x', reason: option);
        expect(a.openKind, kind, reason: option);
        expect(a.openSource, option);
      }
    });

    test('--iamf is noted as the old name of --playback', () {
      final a = parseLaunchArgs(const ['--iamf', '/f/x.mp4']);
      expect(a.notes, contains('--iamf is an old name of --playback'));
    });

    test('the --option=value form', () {
      final a = parseLaunchArgs(const ['--open=/f/a b.mp4']);
      expect(a.openPath, '/f/a b.mp4');
      expect(a.openKind, LaunchOpenKind.auto);
    });

    test('the last file option wins, with a note', () {
      final a = parseLaunchArgs(const [
        '--session',
        '/f/a.esp',
        '--playback',
        '/f/b.mp4',
      ]);
      expect(a.openPath, '/f/b.mp4');
      expect(a.openKind, LaunchOpenKind.playback);
      expect(a.notes.single, contains('replaces --session /f/a.esp'));
    });

    test('a file option without a file is ignored with a note', () {
      final a = parseLaunchArgs(const ['--open']);
      expect(a.openPath, isNull);
      expect(a.notes.single, contains('needs a file'));
      expect(parseLaunchArgs(const ['--open=']).openPath, isNull);
    });

    test('a file option does not take the next option as its file', () {
      final a = parseLaunchArgs(const ['--open', '--quit-after-load']);
      expect(a.openPath, isNull);
      expect(a.quitAfterLoad, isTrue);
      expect(a.notes.single, contains('needs a file'));
    });

    test('a file option does not take a single-dash option as its file', () {
      final a = parseLaunchArgs(const ['--open', '-h']);
      expect(a.openPath, isNull);
      expect(a.help, isTrue);
      expect(a.notes.single, contains('needs a file'));
    });

    test('the process arguments are read too', () {
      final a = parseLaunchArgs(
        const [],
        extraArgs: const ['--quit-after-load', '--playback', '/f/x.iamf'],
      );
      expect(a.openPath, '/f/x.iamf');
      expect(a.quitAfterLoad, isTrue);
    });

    test('unknown options are reported from main() arguments only', () {
      final a = parseLaunchArgs(
        const ['--bogus', 'value', '-x'],
        extraArgs: const ['--enable-dart-profiling', '-NSDocumentRevisions'],
      );
      expect(a.unknown, ['--bogus', '-x']);
    });

    test('--help and -h', () {
      expect(parseLaunchArgs(const ['--help']).help, isTrue);
      expect(parseLaunchArgs(const ['-h']).help, isTrue);
    });

    test('environment fallbacks, in order, only without a file option', () {
      const env = {
        'ECLIPSA_STUDIO_SESSION': '/f/s.esp',
        'ECLIPSA_STUDIO_IAMF': '/f/p.mp4',
        'ECLIPSA_STUDIO_OPEN': '/f/o.iamf',
      };
      var a = parseLaunchArgs(const [], environment: env);
      expect(a.openPath, '/f/o.iamf');
      expect(a.openKind, LaunchOpenKind.auto);
      expect(a.openSource, 'ECLIPSA_STUDIO_OPEN');

      a = parseLaunchArgs(
        const [],
        environment: {...env}..remove('ECLIPSA_STUDIO_OPEN'),
      );
      expect(a.openPath, '/f/p.mp4');
      expect(a.openKind, LaunchOpenKind.playback);

      a = parseLaunchArgs(
        const [],
        environment: const {'ECLIPSA_STUDIO_SESSION': '/f/s.esp'},
      );
      expect(a.openPath, '/f/s.esp');
      expect(a.openKind, LaunchOpenKind.session);

      a = parseLaunchArgs(const ['--session', '/f/cli.esp'], environment: env);
      expect(a.openPath, '/f/cli.esp');
      expect(a.openSource, '--session');
    });

    test('ECLIPSA_STUDIO_QUIT_AFTER_LOAD=1 sets quitAfterLoad', () {
      expect(
        parseLaunchArgs(
          const [],
          environment: const {'ECLIPSA_STUDIO_QUIT_AFTER_LOAD': '1'},
        ).quitAfterLoad,
        isTrue,
      );
      expect(
        parseLaunchArgs(
          const [],
          environment: const {'ECLIPSA_STUDIO_QUIT_AFTER_LOAD': '0'},
        ).quitAfterLoad,
        isFalse,
      );
    });
  });

  group('classifyLaunchFile', () {
    // An MP4 starts with a box size, then `ftyp`.
    final mp4 = [0, 0, 0, 0x20, ...ascii.encode('ftypiso6'), 0, 0, 0, 0];
    // A raw IA sequence starts with an IA sequence header OBU (type 31),
    // its size, then the ia_code `iamf`.
    final iamf = [0xF8, 0x06, ...ascii.encode('iamf'), 0x00, 0x00];

    test('the content decides over the extension', () {
      expect(classifyLaunchFile('/f/x.esp', mp4), LaunchOpenKind.playback);
      expect(classifyLaunchFile('/f/x.bin', iamf), LaunchOpenKind.playback);
      expect(
        classifyLaunchFile('/f/x.mp4', utf8.encode('{"version": 3}')),
        LaunchOpenKind.session,
      );
    });

    test('a session after a byte-order mark and whitespace', () {
      expect(
        classifyLaunchFile('/f/x', [0xEF, 0xBB, 0xBF, 0x0A, 0x20, 0x7B]),
        LaunchOpenKind.session,
      );
    });

    test('an OBU of another type is not a raw IA sequence', () {
      expect(
        classifyLaunchFile('/f/x.bin', [0x08, 0x06, ...ascii.encode('iamf')]),
        isNull,
      );
    });

    test('unreadable or unrecognised content falls back to the extension', () {
      expect(classifyLaunchFile('/f/x.ESP', null), LaunchOpenKind.session);
      expect(classifyLaunchFile('/f/x.iamf', null), LaunchOpenKind.playback);
      expect(classifyLaunchFile('/f/x.mp4', const []), LaunchOpenKind.playback);
      expect(
        classifyLaunchFile('/f/x.mp4', ascii.encode('RIFF....WAVE')),
        LaunchOpenKind.playback,
      );
      expect(classifyLaunchFile('/f/x.wav', null), isNull);
      expect(classifyLaunchFile('/f/x.wav', ascii.encode('RIFF')), isNull);
    });
  });

  group('resolveLaunchFile', () {
    final mp4Head = [0, 0, 0, 0x20, ...ascii.encode('ftypiso6')];
    final heads = <String, List<int>?>{
      '/f/film.mp4': mp4Head,
      '/f/film.bin': mp4Head,
      '/f/mix.esp': utf8.encode('{"version": 3}'),
      '/f/notes.txt': utf8.encode('hello'),
    };
    bool exists(String path) => heads.containsKey(path);
    List<int>? readHead(String path) => heads[path];

    LaunchFile resolve(
      List<String> args, {
      Map<String, String> env = const {},
      String? startup,
    }) {
      var startupTaken = false;
      final file = resolveLaunchFile(
        parseLaunchArgs(args, environment: env),
        exists: exists,
        readHead: readHead,
        takeStartupSession: () {
          startupTaken = true;
          return startup;
        },
      );
      if (args.isNotEmpty || env.isNotEmpty) {
        expect(startupTaken, isFalse, reason: 'startup file kept');
      }
      return file;
    }

    test('Reopen Last Project applies only when no file is named', () {
      final f = resolve(const []);
      expect(f.status, LaunchFileStatus.none);
      expect(f.allowReopenLastProject, isTrue);
    });

    test('--quit-after-load with no file never reopens the last project', () {
      final plain = parseLaunchArgs(const []);
      expect(mayReopenLastProject(plain, resolve(const [])), isTrue);
      final quit = parseLaunchArgs(const ['--quit-after-load']);
      expect(
        // --quit-after-load names no file, so it resolves as no options.
        mayReopenLastProject(quit, resolve(const [])),
        isFalse,
      );
      final named = parseLaunchArgs(const ['--open', '/f/mix.esp']);
      expect(
        mayReopenLastProject(named, resolve(const ['--open', '/f/mix.esp'])),
        isFalse,
      );
    });

    test('--open routes by content', () {
      expect(
        resolve(const ['--open', '/f/film.bin']).status,
        LaunchFileStatus.playback,
      );
      expect(
        resolve(const ['--open', '/f/mix.esp']).status,
        LaunchFileStatus.session,
      );
      final f = resolve(const ['--open', '/f/notes.txt']);
      expect(f.status, LaunchFileStatus.unclassified);
      expect(f.allowReopenLastProject, isFalse);
    });

    test('--session and --playback do not read the file', () {
      expect(
        resolve(const ['--session', '/f/film.mp4']).status,
        LaunchFileStatus.session,
      );
      expect(
        resolve(const ['--playback', '/f/mix.esp']).status,
        LaunchFileStatus.playback,
      );
    });

    test('a missing file is missing whatever its type, and blocks reopen', () {
      for (final args in const [
        ['--open', '/f/gone.xyz'],
        ['--open', '/f/gone.mp4'],
        ['--session', '/f/gone.esp'],
        ['--playback', '/f/gone.iamf'],
      ]) {
        final f = resolve(args);
        expect(f.status, LaunchFileStatus.missing, reason: '$args');
        expect(f.allowReopenLastProject, isFalse, reason: '$args');
      }
    });

    test('the environment names the file when no option does', () {
      final f = resolve(
        const [],
        env: const {'ECLIPSA_STUDIO_OPEN': '/f/film.mp4'},
      );
      expect(f.status, LaunchFileStatus.playback);
      expect(f.source, 'ECLIPSA_STUDIO_OPEN');
    });

    test('startup_session.txt is read only when nothing else names a file', () {
      var f = resolve(const [], startup: '/f/mix.esp');
      expect(f.status, LaunchFileStatus.session);
      expect(f.source, 'startup_session.txt');
      expect(f.allowReopenLastProject, isFalse);

      f = resolve(const [], startup: '/f/gone.esp');
      expect(f.status, LaunchFileStatus.missing);

      f = resolve(const ['--open', '/f/film.mp4'], startup: '/f/mix.esp');
      expect(f.status, LaunchFileStatus.playback);
    });
  });
}
