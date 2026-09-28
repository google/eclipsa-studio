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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the `window_manager` method channel in a widget test, so a
/// widget that asks the plugin about the window (the title strip's
/// maximized state on Windows, the title sync) does not throw
/// `MissingPluginException`. `isMaximized` answers false; every other
/// method answers null. Call from `setUp`; the handler is cleared in a
/// teardown it registers itself.
void mockWindowManager() {
  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'isMaximized') return false;
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}
