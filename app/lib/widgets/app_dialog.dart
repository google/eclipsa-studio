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

/// What the Escape key does on a dialog shown by [showAppDialog].
enum DialogEscape {
  /// Pops the dialog with a null result, the same outcome as its Cancel
  /// or Done button. The default.
  dismiss,

  /// Escape does nothing. For dialogs that report a running operation
  /// with no user action, and for dialogs that bind Escape themselves.
  none,
}

/// The app-wide dialog policy (ES-639): a click on the background never
/// closes a dialog, and Escape closes it wherever a Cancel or Done
/// button would.
///
/// Flutter's `barrierDismissible` flag drives both paths at once: the
/// modal route's Escape action is enabled only while the barrier is
/// dismissible. So this helper turns the barrier off at every route and
/// binds Escape itself, inside the dialog, where [escape] says so.
///
/// Every dialog in the app goes through here rather than `showDialog`,
/// so no call site can inherit the framework default by omission; a
/// test greps the source tree for direct calls.
///
/// [id] gives the dialog an identity (ES-682). While a dialog with that
/// id is on the stack, a second request for it is dropped and the
/// returned future completes with null. The macOS menu bar lives
/// outside the Flutter window, so its items and their shortcuts stay
/// live under a modal route and re-enter the dialog that is already
/// open. The guard is per id rather than app-wide because a dialog
/// may legitimately open a different one over itself — Export shows a
/// confirm, ADM import shows a replace prompt. Pass the dialog
/// widget's `Type` where it has a class of its own, or another
/// constant object where the dialog is built inline. With no id the
/// call is unguarded.
///
/// A caller with work to do before the push must ask [isAppDialogOpen]
/// first, or that work takes effect on a call that opens nothing.
/// `SettingsDialog.show`, which records the tab to open on, does.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  DialogEscape escape = DialogEscape.dismiss,
  Object? id,
}) {
  if (id != null && !_openDialogIds.add(id)) return Future<T?>.value();
  final Future<T?> route;
  try {
    route = showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => switch (escape) {
        DialogEscape.dismiss => _EscapeDismisses(child: builder(ctx)),
        DialogEscape.none => builder(ctx),
      },
    );
  } catch (_) {
    // `showDialog` throws synchronously on a deactivated context. The
    // route never opens, so nothing will ever complete its future and
    // release the id; without this the dialog could never be opened
    // again for the rest of the session.
    if (id != null) _openDialogIds.remove(id);
    rethrow;
  }
  if (id == null) return route;
  // The route's future is the one exit every path shares: Escape, the
  // Done or Cancel button, and a `Navigator.pop` from inside the
  // dialog all complete it.
  return route.whenComplete(() => _openDialogIds.remove(id));
}

/// Whether [showAppDialog] has a dialog with this [id] on the stack.
bool isAppDialogOpen(Object id) => _openDialogIds.contains(id);

/// Ids of the dialogs [showAppDialog] currently has on the stack.
final Set<Object> _openDialogIds = {};

/// Clears the [showAppDialog] id registry.
///
/// A widget test that tears its tree down with a dialog still up
/// leaves that route's future uncompleted, so the id would outlive the
/// test. Only tests call this.
@visibleForTesting
void debugResetOpenDialogIds() => _openDialogIds.clear();

/// Binds Escape to `Navigator.maybePop` for [child].
///
/// Key events bubble from the focused node up through its ancestors,
/// so the binding only sees Escape while focus is inside the dialog.
/// With nothing in the dialog focused, the route's own scope holds
/// focus and the binding would be bypassed, so the child sits in a
/// [FocusScope] that autofocuses. As an ancestor it registers first
/// and takes focus; a dialog widget that autofocuses too (a text
/// field, a default button) then lands inside that scope, which is
/// what its autofocus checks, and gets focus as before. A dialog that
/// binds Escape on a deeper focus node (the routing matrix) handles
/// it first, so nothing pops twice.
class _EscapeDismisses extends StatelessWidget {
  const _EscapeDismisses({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: FocusScope(autofocus: true, child: child),
    );
  }
}
