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

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/logging/log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/engine_dylib.dart';

/// The engine formats log messages into fixed buffers, so a message can
/// end in a UTF-8 character cut short. The log callback decodes it with
/// U+FFFD in place of the cut character; before, the decode threw and
/// the entry was lost.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a message cut inside a UTF-8 character reaches the log', () async {
    final dylib = engineDylibOrSkip();
    if (dylib == null) return;
    useEngineDylib(dylib);

    final engine = EclipsaStudioEngine();
    expect(engine.init(), 0, reason: 'engine init failed');
    // element_add logs `element_add(id=1, path="<path>") -> rc=N` into a
    // 512-byte buffer. The message's first 26 bytes come before the first
    // U+00E9 of this path, so byte 511, the last one kept, is the first of
    // the two bytes of a U+00E9.
    engine.addElement(1, '/x${'\u{E9}' * 300}');
    await engine.shutdown();

    final messages = [
      for (final entry in Log.instance.entries)
        if (entry.category == 'engine' &&
            entry.message.startsWith('element_add(id=1,'))
          entry.message,
    ];
    expect(messages, hasLength(1));
    expect(messages.single, endsWith('\u{E9}\u{FFFD}'));
  });
}
