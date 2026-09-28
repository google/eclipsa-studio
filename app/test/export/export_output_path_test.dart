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

import 'dart:io';

import 'package:eclipsa_studio/export/export_output_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final dir = p.join(p.separator, 'Users', 'me', 'Film');
  String at(String name) => p.join(dir, name);

  group('uniqueOutputPath', () {
    test('returns stem.ext when it is free', () {
      expect(
        uniqueOutputPath(dir, 'Film', 'mp4', exists: (_) => false),
        at('Film.mp4'),
      );
    });

    test('skips an existing file', () {
      final files = {at('Film.mp4'), at('Film-01.mp4')};
      expect(
        uniqueOutputPath(dir, 'Film', 'mp4', exists: files.contains),
        at('Film-02.mp4'),
      );
    });

    test('skips the source video even when it is not seen on disk', () {
      expect(
        uniqueOutputPath(
          dir,
          'Film',
          'mp4',
          exists: (_) => false,
          avoid: at('Film.mp4'),
        ),
        at('Film-01.mp4'),
      );
    });

    test('with Film.mp4 beside Film.esp, the MP4 default is Film-01.mp4', () {
      // Film.esp and Film.mp4 in the session folder, no Film.iamf: the
      // IAMF default is Film.iamf, and switching to MP4 must not give
      // back the source video's path.
      final files = {at('Film.esp'), at('Film.mp4')};
      expect(
        uniqueOutputPath(dir, 'Film', 'iamf', exists: files.contains),
        at('Film.iamf'),
      );
      expect(
        uniqueOutputPath(
          dir,
          'Film',
          'mp4',
          exists: files.contains,
          avoid: at('Film.mp4'),
        ),
        at('Film-01.mp4'),
      );
    });
  });

  test('when all 100 names are taken it returns stem-99.ext', () {
    // The dialog's pre-export check then shows the save panel, since the
    // returned path exists.
    expect(
      uniqueOutputPath(dir, 'Film', 'mp4', exists: (_) => true),
      at('Film-99.mp4'),
    );
  });

  group('normalizeSavePanelPath', () {
    test('keeps a path that already has the extension', () {
      expect(normalizeSavePanelPath(at('Film.mp4'), 'mp4'), at('Film.mp4'));
    });

    test('appends a missing extension', () {
      expect(normalizeSavePanelPath(at('Film'), 'mp4'), at('Film.mp4'));
    });

    test('collapses a doubled extension, ignoring case', () {
      expect(normalizeSavePanelPath(at('Film.MP4.mp4'), 'mp4'), at('Film.MP4'));
    });
  });

  group('outputNeedsSavePanel', () {
    bool needs({
      String output = '',
      bool confirmed = true,
      String? picked,
      String? video,
      Set<String> files = const {},
    }) => outputNeedsSavePanel(
      outputPath: output,
      confirmed: confirmed,
      pickedPath: picked,
      sourceVideoPath: video,
      exists: files.contains,
    );

    test('an unconfirmed path needs the save panel', () {
      expect(needs(output: at('Film.iamf'), confirmed: false), isTrue);
    });

    test('a confirmed path to a new file does not', () {
      expect(needs(output: at('Film.iamf')), isFalse);
    });

    test('a confirmed path to an existing file not picked does', () {
      expect(needs(output: at('Film.mp4'), files: {at('Film.mp4')}), isTrue);
    });

    test('an existing file the user picked in the save panel does not', () {
      expect(
        needs(
          output: at('Film.mp4'),
          picked: at('Film.mp4'),
          files: {at('Film.mp4')},
        ),
        isFalse,
      );
    });

    test('the source video always does', () {
      expect(
        needs(
          output: at('Film.mp4'),
          picked: at('Film.mp4'),
          video: at('Film.mp4'),
        ),
        isTrue,
      );
    });
  });

  group('isSameOutputPath', () {
    test('normalizes before comparing', () {
      expect(
        isSameOutputPath(at('Film.mp4'), p.join(dir, '.', 'Film.mp4')),
        isTrue,
      );
    });

    group('on disk', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('output_path'));
      tearDown(() => tmp.deleteSync(recursive: true));

      test('a path through a symbolic link matches its target', () {
        final real = Directory(p.join(tmp.path, 'real'))..createSync();
        final video = File(p.join(real.path, 'Film.mp4'))..createSync();
        final link = Link(p.join(tmp.path, 'link'))..createSync(real.path);
        expect(
          isSameOutputPath(p.join(link.path, 'Film.mp4'), video.path),
          isTrue,
        );
      });

      test('a case-only difference matches on a case-insensitive volume', () {
        final video = File(p.join(tmp.path, 'Film.mp4'))..createSync();
        final upper = p.join(tmp.path, 'FILM.MP4');
        if (!File(upper).existsSync()) {
          markTestSkipped('the temp volume is case-sensitive');
          return;
        }
        expect(isSameOutputPath(upper, video.path), isTrue);
      });

      test('two different existing files do not match', () {
        final a = File(p.join(tmp.path, 'a.mp4'))..createSync();
        final b = File(p.join(tmp.path, 'b.mp4'))..createSync();
        expect(isSameOutputPath(a.path, b.path), isFalse);
      });
    });

    test('null or empty never matches', () {
      expect(isSameOutputPath(null, at('Film.mp4')), isFalse);
      expect(isSameOutputPath('', ''), isFalse);
    });
  });
}
