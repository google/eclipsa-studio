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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_cycle.dart';
import 'theme_gallery.dart';

/// Unmodified `t` and `g` for design review.
///
/// `t` cycles the theme and ships in every build, because every theme
/// is now offered to users and stepping through them is how you
/// compare them on a real surface. `g` opens or closes the Theme
/// Gallery and stays debug-only, along with the gallery itself.
///
/// No modifier on purpose: comparing themes means pressing the same key
/// dozens of times while staring at one surface, and a chord costs a
/// hand position on every press. These were ⌘T and a menu item before.
///
/// A bare letter is only defensible because it stands down whenever a
/// text field holds focus — typing "target" into a session name must
/// not cycle the theme six times.
///
/// Mounted from `MaterialApp.builder`, which puts it above the
/// Navigator, so the keys work over dialogs too. That is what lets `g`
/// close the gallery it opened. Inside `home:` it would sit below the
/// Navigator and never see a key while a route was up.
///
/// Sitting above the Navigator is also why [navigatorKey] is needed:
/// this widget's own context has no Navigator above it, so opening a
/// dialog from it throws. The key supplies a context under the Navigator.
class DevShortcuts extends ConsumerWidget {
  const DevShortcuts({super.key, required this.child, this.navigatorKey});

  final Widget child;

  /// The app's navigator, used to reach a context that can host a
  /// dialog. When null, `g` does nothing rather than throwing.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Whether a text field currently owns the keyboard.
  ///
  /// Flutter inserts characters through the platform text-input
  /// connection, not the key-event pipeline, so an ancestor shortcut
  /// sees `t` even while a field is being typed into — the character
  /// lands in the field *and* the shortcut fires. Hence the check.
  static bool get typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    // A field that wraps its EditableText (search boxes, some console
    // inputs) focuses a node above it.
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: bindings(gallery: kThemeGalleryEnabled),
      child: Actions(
        actions: {
          _CycleThemeIntent: _CycleThemeAction(ref),
          if (kThemeGalleryEnabled)
            _ToggleGalleryIntent: _ToggleGalleryAction(navigatorKey),
        },
        child: child,
      ),
    );
  }
}

/// The key bindings, split out so both branches are testable.
///
/// Tests run in debug, where [kThemeGalleryEnabled] is true, so a
/// widget test can only ever exercise the debug map. Taking the flag
/// as an argument is what lets a test assert what a release build
/// binds: `t` and not `g`.
@visibleForTesting
Map<ShortcutActivator, Intent> bindings({required bool gallery}) => {
  const SingleActivator(LogicalKeyboardKey.keyT): const _CycleThemeIntent(),
  if (gallery)
    const SingleActivator(LogicalKeyboardKey.keyG):
        const _ToggleGalleryIntent(),
};

class _CycleThemeIntent extends Intent {
  const _CycleThemeIntent();
}

class _ToggleGalleryIntent extends Intent {
  const _ToggleGalleryIntent();
}

// Both actions gate on `isActionEnabled` rather than returning early
// from `invoke`. A disabled action does not consume the key, so the
// keystroke carries on to the text field. Swallowing it would leave a
// field that silently drops every `t` and `g`.

class _CycleThemeAction extends Action<_CycleThemeIntent> {
  _CycleThemeAction(this.ref);

  final WidgetRef ref;

  @override
  bool get isActionEnabled => !DevShortcuts.typing;

  @override
  void invoke(_CycleThemeIntent intent) => ThemeCycle.next(ref);
}

class _ToggleGalleryAction extends Action<_ToggleGalleryIntent> {
  _ToggleGalleryAction(this.navigatorKey);

  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  bool get isActionEnabled => !DevShortcuts.typing;

  @override
  void invoke(_ToggleGalleryIntent intent) {
    final ctx = navigatorKey?.currentContext;
    if (ctx != null) ThemeGallery.toggle(ctx);
  }
}
