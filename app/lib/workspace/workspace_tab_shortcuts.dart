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

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../state.dart';
import 'workspace_mode.dart';

/// The digit keys of the tab shortcuts, in top bar order.
const _tabDigits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
];

/// The shortcut that selects the tab at [index] in
/// [WorkspaceTabs.allowedIn]: Cmd+1 to Cmd+3 when [mac] is true, Ctrl+1
/// to Ctrl+3 otherwise.
///
/// The index is the tab's position in the top bar, left to right, so
/// Renderer is Cmd+3 in Creator and Cmd+2 in Playback.
SingleActivator workspaceTabShortcut(int index, {required bool mac}) =>
    SingleActivator(_tabDigits[index], meta: mac, control: !mac);

/// The tab in [mode] that [event] selects through its shortcut, or null.
///
/// The workspace shell's key handler calls this on every platform. On
/// macOS the window's views receive a Cmd key event before the menu
/// bar, so the handler selects the tab, and the View menu item runs for
/// a click or for a Cmd+digit the shell does not receive, such as one
/// pressed in a dialog. The Flutter-drawn menu bar on Windows and Linux
/// only displays its shortcuts. [mac] defaults to the host platform.
String? workspaceTabForKey(KeyEvent event, WorkspaceMode mode, {bool? mac}) {
  final isMac = mac ?? Platform.isMacOS;
  for (final (i, id) in WorkspaceTabs.allowedIn(mode).indexed) {
    if (workspaceTabShortcut(
      i,
      mac: isMac,
    ).accepts(event, HardwareKeyboard.instance)) {
      return id;
    }
  }
  return null;
}
