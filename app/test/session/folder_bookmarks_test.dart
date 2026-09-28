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

import 'package:eclipsa_studio/session/folder_bookmarks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('folderBookmarkCandidates walks from the folder up to the root', () {
    final c = folderBookmarkCandidates('/a/b/c');
    expect(c.first, '/a/b/c');
    expect(c, containsAllInOrder(['/a/b/c', '/a/b', '/a', '/']));
    expect(c.last, '/');
  });

  test('canonicalFolder resolves symlinks and normalizes', () {
    final tmp = Directory.systemTemp.createTempSync('fb_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final real = Directory(p.join(tmp.path, 'real'))..createSync();
    final link = Link(p.join(tmp.path, 'link'))..createSync(real.path);
    expect(
      canonicalFolder(link.path),
      Directory(real.path).resolveSymbolicLinksSync(),
    );
    // A folder that does not exist still yields a normalized key.
    expect(canonicalFolder('/no/such/../folder/'), '/no/folder');
  });
}
