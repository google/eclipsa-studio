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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/log.dart';
import 'workspace_mode.dart';

/// Guard that Creator-only mutating operations run only while the
/// workspace is in Creator mode.
///
/// Intended for use at the top of notifier mutators that write to
/// session / element / mix state. In debug builds the guard throws
/// via `assert`, surfacing programmer error immediately. In release
/// builds the guard logs a warning and returns; the caller should
/// also short-circuit by checking the return value.
///
/// Returns `true` when the call site is free to proceed (mode is
/// Creator or, defensively, `none` during bootstrap), `false` when it
/// must no-op.
bool assertCreatorMode(Ref ref, {required String op}) {
  final mode = ref.read(workspaceModeProvider);
  if (mode == WorkspaceMode.creator) return true;

  final message = 'Creator-only op "$op" attempted in mode ${mode.name}';
  assert(() {
    throw StateError(message);
  }());
  if (kReleaseMode) {
    Log.w(LogCat.app, message);
  }
  return false;
}
