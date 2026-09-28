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

import '../theme.dart';
import 'app_button.dart';
import 'app_dialog.dart';

/// Shared single-button notice dialog: themed [AlertDialog] with a
/// Title Case title, sentence-case body, and one OK action. Used by
/// the import-blocker dialog and the IAMF open/probe error dialogs so
/// the ~20-line AlertDialog block exists once.
Future<void> showOkDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text(title, style: T.styleTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(message, style: T.styleBodySecondary),
      ),
      actions: [
        AppButton(
          label: 'OK',
          role: AppButtonRole.affirmative,
          onPressed: () => Navigator.pop(ctx),
        ),
      ],
    ),
  );
}

/// Warning variant of [showOkDialog]: same themed shell, with an
/// optional remedy action as a second, emphasized button (e.g. the
/// load-time profile bump, ES-490). The plain dismiss stays available so
/// the action is never forced.
Future<void> showWarningDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text(title, style: T.styleTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(message, style: T.styleBodySecondary),
      ),
      actions: [
        AppButton(
          label: actionLabel == null ? 'OK' : 'Dismiss',
          role: actionLabel == null
              ? AppButtonRole.affirmative
              : AppButtonRole.quiet,
          onPressed: () => Navigator.pop(ctx),
        ),
        if (actionLabel != null)
          AppButton(
            label: actionLabel,
            role: AppButtonRole.affirmative,
            onPressed: () {
              Navigator.pop(ctx);
              onAction?.call();
            },
          ),
      ],
    ),
  );
}
