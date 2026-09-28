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

import 'package:eclipsa_studio/session/session_model.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Matches a path against [expected] ignoring platform separator style —
/// decoded absolute paths come back `\`-separated on Windows.
Matcher samePath(String expected) => predicate<String?>(
  (actual) => actual != null && p.equals(actual, expected),
  'is the same path as "$expected"',
);

void main() {
  group('relative paths', () {
    const sessionDir = '/Users/me/projects/my-session';

    final model = SessionModel(
      elements: [
        AudioElement(
          id: 1,
          name: 'drums',
          type: 'Object',
          layout: 'Stereo',
          codec: 'WAV 24bit',
          color: 0xFF888888,
          wavPath: '/Users/me/projects/my-session/audio/drums.wav',
        ),
        AudioElement(
          id: 2,
          name: 'vocals',
          type: 'Object',
          layout: 'Mono',
          codec: 'WAV 16bit',
          color: 0xFF888888,
          wavPath: '/Users/me/projects/audio/vocals.wav',
        ),
      ],
      mediaPath: '/Users/me/projects/my-session/video/clip.mp4',
    );

    test('encode stores paths relative to session dir', () {
      final json = model.toJson(relativeTo: sessionDir);

      expect(json['mediaPath'], 'video/clip.mp4');

      final elems = json['elements'] as List<dynamic>;
      final e1 = elems[0] as Map<String, dynamic>;
      final e2 = elems[1] as Map<String, dynamic>;
      expect(e1['wavPath'], 'audio/drums.wav');
      expect(e2['wavPath'], '../audio/vocals.wav');
    });

    test('decode resolves relative paths to absolute', () {
      final json = model.toJson(relativeTo: sessionDir);
      final decoded = SessionModel.fromJson(json, resolveFrom: sessionDir);

      expect(
        decoded.mediaPath,
        samePath('/Users/me/projects/my-session/video/clip.mp4'),
      );
      expect(
        decoded.elements[0].wavPath,
        samePath('/Users/me/projects/my-session/audio/drums.wav'),
      );
      expect(
        decoded.elements[1].wavPath,
        samePath('/Users/me/projects/audio/vocals.wav'),
      );
    });

    test('encode without relativeTo keeps absolute paths', () {
      final json = model.toJson();
      expect(json['mediaPath'], '/Users/me/projects/my-session/video/clip.mp4');
      final e1 = (json['elements'] as List<dynamic>)[0] as Map<String, dynamic>;
      expect(e1['wavPath'], '/Users/me/projects/my-session/audio/drums.wav');
    });

    test('decode leaves absolute paths unchanged', () {
      final json = {
        'version': SessionModel.schemaVersion,
        'elements': [
          {
            'id': 1,
            'name': 'test',
            'type': 'Object',
            'wavPath': '/absolute/path/to/file.wav',
          },
        ],
        'mediaPath': '/absolute/video.mp4',
      };

      final decoded = SessionModel.fromJson(json, resolveFrom: sessionDir);
      expect(decoded.elements[0].wavPath, '/absolute/path/to/file.wav');
      expect(decoded.mediaPath, '/absolute/video.mp4');
    });

    test('the pre-release videoPath key is not read', () {
      final json = {
        'version': SessionModel.schemaVersion,
        'elements': <dynamic>[],
        'videoPath': 'video/clip.mp4',
      };
      final decoded = SessionModel.fromJson(json, resolveFrom: sessionDir);
      expect(decoded.mediaPath, isNull);
    });

    test('a pre-release schema version is rejected', () {
      for (final version in [1, 2]) {
        expect(
          () => SessionModel.fromJson({'version': version, 'elements': []}),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('version $version was written by a pre-release'),
            ),
          ),
        );
      }
      expect(
        () => SessionModel.fromJson({'elements': []}),
        throwsA(isA<FormatException>()),
        reason: 'a file without a version field is a version 1 file',
      );
    });

    test('a newer schema version is rejected', () {
      expect(
        () => SessionModel.fromJson({
          'version': SessionModel.schemaVersion + 1,
          'elements': [],
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('newer than supported'),
          ),
        ),
      );
    });

    test('roundtrip through encode/decode preserves paths', () {
      final encoded = model.encode(relativeTo: sessionDir);
      final decoded = SessionModel.decode(encoded, resolveFrom: sessionDir);

      expect(decoded.mediaPath, samePath(model.mediaPath!));
      expect(decoded.elements[0].wavPath, samePath(model.elements[0].wavPath!));
      expect(decoded.elements[1].wavPath, samePath(model.elements[1].wavPath!));
    });

    test('null paths are handled', () {
      final noPathModel = SessionModel(
        elements: [
          AudioElement(
            id: 1,
            name: 'empty',
            type: 'Object',
            layout: 'Mono',
            codec: '',
            color: 0xFF888888,
          ),
        ],
      );

      final json = noPathModel.toJson(relativeTo: sessionDir);
      expect(json.containsKey('mediaPath'), isFalse);
      final e1 = (json['elements'] as List<dynamic>)[0] as Map<String, dynamic>;
      expect(e1.containsKey('wavPath'), isFalse);

      final decoded = SessionModel.fromJson(json, resolveFrom: sessionDir);
      expect(decoded.mediaPath, isNull);
      expect(decoded.elements[0].wavPath, isNull);
    });
  });
}
