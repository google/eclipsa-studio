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

import 'package:flutter/material.dart';

import 'ok_dialog.dart';

/// Modal notice for import blockers — drops or opens where nothing was
/// imported (ES-184).
///
/// A bottom-of-window SnackBar is too easy to miss for a hard failure:
/// users re-drop the same file assuming the drop didn't register, when
/// it was rejected for an actionable reason. A modal forces the
/// acknowledgement. Informational notices (the import succeeded with
/// caveats) stay on the SnackBar — see the `importNoticeProvider`
/// listener in `app_shell.dart`.
Future<void> showImportErrorDialog(BuildContext context, String message) {
  return showOkDialog(context, title: "Couldn't Import", message: message);
}
