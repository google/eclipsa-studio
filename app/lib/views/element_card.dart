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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import '../widgets/app_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/inline_edit_field.dart';

/// Inline rename text field for element rows. Thin wrapper around
/// [InlineEditField] that trims whitespace and rejects empty names.
///
/// The parent is responsible for toggling edit mode back to display
/// mode — wire [onExit] to your `setState(() => _editing = false)`.
class RenameField extends ConsumerWidget {
  final String currentName;
  final ValueChanged<String> onRename;
  final VoidCallback onExit;

  const RenameField({
    super.key,
    required this.currentName,
    required this.onRename,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 20,
      child: InlineEditField(
        initialValue: currentName,
        onCommit: onRename,
        onExit: onExit,
        normalize: (s) => s.trim(),
        validate: (s) => s.isNotEmpty,
        onValidationFail: (_) => ref
            .read(importNoticeProvider.notifier)
            .show('Name cannot be empty'),
        // Match the display Text style (styleBodySecondary) so the name
        // doesn't jump to a larger font when entering edit mode.
        style: T.styleBodySecondary,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2,
          ),
          filled: true,
          fillColor: T.bgElevated,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: T.purple, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: T.purple, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: T.purple, width: 1),
          ),
        ),
      ),
    );
  }
}

/// Shared delete confirmation dialog.
Future<void> showDeleteDialog(
  BuildContext context,
  String elementName,
  VoidCallback onConfirm,
) {
  return showAppDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.bgElevated,
      title: Text('Delete Element', style: T.styleTitle),
      content: Text(
        "Remove '$elementName' from the session?\n"
        'This cannot be undone.',
        style: T.styleBodySecondary,
      ),
      actions: [
        AppButton(
          label: 'Cancel',
          role: AppButtonRole.quiet,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
        AppButton(
          label: 'Delete',
          role: AppButtonRole.destructive,
          onPressed: () {
            Navigator.of(ctx).pop();
            onConfirm();
          },
        ),
      ],
    ),
  );
}
