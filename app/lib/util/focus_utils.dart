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

import 'package:flutter/widgets.dart';

/// True when the primary focus sits inside a text editor (TextField /
/// EditableText) — the one case where printable-key shortcuts (Space
/// for play/stop) must stay out of the way so typing is never hijacked.
///
/// Any other focused control (button, list row, the 3D renderer) must
/// NOT suppress the transport shortcuts — see ES-79, where a blanket
/// `hasPrimaryFocus` guard made Space activate whichever button was
/// last clicked instead of toggling playback.
bool textInputHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  // A TextField's focus node is attached inside EditableText's subtree,
  // so the editor is found as an ancestor of the focused context.
  return context.findAncestorStateOfType<EditableTextState>() != null;
}
