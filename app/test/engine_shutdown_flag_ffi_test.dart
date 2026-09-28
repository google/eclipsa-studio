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
import 'package:flutter_test/flutter_test.dart';

import 'support/engine_dylib.dart';

/// `eclipsaStudioEngineProvider` keeps handing out the engine after it is
/// shut down, and the FFI entry points do not check `g_initialized`, so
/// a caller that polls on a timer has to ask whether the engine is
/// still there. `AppShell._onTick` does, off this flag (ES-662).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isShutDown reports whether the engine has been torn down', () async {
    final dylib = engineDylibOrSkip();
    if (dylib == null) return;
    useEngineDylib(dylib);

    final engine = EclipsaStudioEngine();
    expect(engine.init(), 0, reason: 'engine init failed');
    expect(engine.isShutDown, isFalse, reason: 'live engine');

    await engine.shutdown();
    expect(engine.isShutDown, isTrue, reason: 'after shutdown');

    // shutdown() is idempotent — the exit handler and the provider's
    // onDispose both call it — and must not clear the flag.
    await engine.shutdown();
    expect(engine.isShutDown, isTrue, reason: 'after a second shutdown');
  });
}
