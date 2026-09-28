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

// The Import ADM dialog shows the chosen session folder on one row. The
// path is elided from the left, because the folder just chosen sits at the
// end and end-elision is what hid it.

import 'package:eclipsa_studio/import/adm_import_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a path that fits is returned unchanged', () {
    expect(elideFolderPath('/Users/me/Projects'), '/Users/me/Projects');
  });

  test('a long path keeps its tail', () {
    const path =
        '/Users/me/Library/Containers/com.eclipsa.studio/Data/Documents/'
        'Sessions/Autumn/Reels';
    final elided = elideFolderPath(path, maxChars: 32);
    expect(elided, startsWith('…/'));
    expect(elided, endsWith('Autumn/Reels'));
    expect(elided.length, lessThanOrEqualTo(32));
  });

  test('one oversized segment is cut from the left', () {
    final name = 'x' * 80;
    final elided = elideFolderPath('/Users/me/$name', maxChars: 20);
    expect(elided, startsWith('…'));
    expect(elided, endsWith('x'));
    expect(elided.length, lessThanOrEqualTo(20));
  });

  test('the leading separator is not doubled', () {
    final elided = elideFolderPath('/${'a' * 30}/${'b' * 30}/c', maxChars: 20);
    expect(elided, isNot(contains('//')));
  });
}
