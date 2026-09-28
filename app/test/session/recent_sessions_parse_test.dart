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

// Pins how a recent-sessions file in an unexpected shape is read: the
// plain-string entries pre-release builds wrote, and a file that is not
// a list, yield no entries instead of a TypeError that would stop the
// app at startup or fail a save.

import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/session/recent_sessions.dart';

void main() {
  test('reads path and bookmark entries', () {
    expect(
      RecentSessions.pathsFromJson([
        {'path': '/a.esp'},
        {
          'path': '/b.esp',
          'bookmarks': {'/b.esp': 'data'},
        },
      ]),
      ['/a.esp', '/b.esp'],
    );
  });

  test('skips plain-string and malformed entries', () {
    expect(
      RecentSessions.pathsFromJson([
        '/old.esp',
        {'path': 42},
        {'path': '/ok.esp', 'bookmarks': 'not a map'},
        null,
      ]),
      ['/ok.esp'],
    );
  });

  test('a file that is not a list yields nothing', () {
    expect(RecentSessions.pathsFromJson({'path': '/a.esp'}), isEmpty);
    expect(RecentSessions.pathsFromJson('text'), isEmpty);
    expect(RecentSessions.pathsFromJson(null), isEmpty);
  });
}
