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

/// A reusable text field for in-place label / value editing.
///
/// Owns its own [TextEditingController] and [FocusNode], auto-focuses
/// on first build, and consolidates the full commit/cancel state
/// machine that every ad-hoc inline editor in the app used to
/// reimplement (each with slightly different bugs):
///
/// * **Enter** → commit the current value and exit the field.
/// * **Escape** → revert to [initialValue], then exit the field
///   without committing. [onCancel] fires if provided.
/// * **Tap outside the field** → commit the current value and exit.
/// * **Focus loss for any other reason** (tab, window blur, a
///   programmatic unfocus) → commit the current value and exit.
/// * **Guaranteed single commit** — regardless of how many triggers
///   the user hits in the same edit session, [onCommit] fires at most
///   once.
/// * **No-op commits are suppressed** — if the normalized value is
///   unchanged from [initialValue], [onCommit] is not called. This
///   avoids spurious state updates / persistence churn.
///
/// The widget is purely the edit field. Parents that want a
/// display-mode → edit-mode toggle should render this widget only
/// while editing and flip their own state from [onExit].
class InlineEditField extends StatefulWidget {
  /// The starting value of the field. Also the "revert target" when
  /// the user presses Escape.
  final String initialValue;

  /// Called with the normalized value when the user commits a change.
  /// Not called if the normalized value equals [initialValue], if the
  /// user presses Escape, or if [validate] rejects the value.
  final ValueChanged<String> onCommit;

  /// Called when the user explicitly cancels via Escape. Not called
  /// when [validate] rejects a value — see [onValidationFail] for
  /// that.
  final VoidCallback? onCancel;

  /// Called when [validate] rejects the normalized value on a commit
  /// attempt (Enter, tap-outside, focus loss). Receives the rejected
  /// normalized value. Typical use: push a short notice so the user
  /// knows why their input was discarded instead of silently reverting
  /// to the old value.
  final ValueChanged<String>? onValidationFail;

  /// Called exactly once when the edit session ends, for any reason
  /// (commit, cancel, or rejected-by-validate). Use this to flip a
  /// parent `_editing` flag back to display mode.
  final VoidCallback? onExit;

  /// Optional normalization applied before [validate] and [onCommit].
  /// Typical uses: `String.trim` for text, parse-clamp-format for
  /// numeric values.
  final String Function(String raw)? normalize;

  /// Returns `true` if the normalized value is acceptable. A `false`
  /// return prevents [onCommit] from firing, invokes [onValidationFail]
  /// with the rejected value, and ends the edit session via [onExit].
  /// Defaults to accepting anything.
  final bool Function(String normalized)? validate;

  final TextStyle? style;
  final InputDecoration? decoration;
  final TextAlign textAlign;

  /// Vertical alignment of the text within the field's box. Defaults to
  /// centered so the editing text sits where the display text did —
  /// inline editors live in fixed-height boxes, and a top-aligned field
  /// makes the text visibly jump on enter/exit.
  final TextAlignVertical textAlignVertical;

  final List<TextInputFormatter>? inputFormatters;
  final TextInputType? keyboardType;

  const InlineEditField({
    required this.initialValue,
    required this.onCommit,
    this.onCancel,
    this.onValidationFail,
    this.onExit,
    this.normalize,
    this.validate,
    this.style,
    this.decoration,
    this.textAlign = TextAlign.start,
    this.textAlignVertical = TextAlignVertical.center,
    this.inputFormatters,
    this.keyboardType,
    super.key,
  });

  @override
  State<InlineEditField> createState() => _InlineEditFieldState();
}

class _InlineEditFieldState extends State<InlineEditField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  /// Set to `true` when the user presses Escape. The focus-loss
  /// handler checks this to route the exit to [onCancel] instead of
  /// [onCommit].
  bool _cancelled = false;

  /// Guards against double-firing when multiple exit triggers race
  /// (e.g. onSubmitted → unfocus → focus-loss listener).
  bool _exited = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialValue.length,
    );
    _focusNode = FocusNode(onKeyEvent: _handleKey);
    _focusNode.addListener(_handleFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // Revert the buffer first so the subsequent focus-loss commit
      // check sees the unchanged value and skips onCommit.
      _cancelled = true;
      _controller.text = widget.initialValue;
      _focusNode.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus || _exited) return;
    _exited = true;
    if (_cancelled) {
      widget.onCancel?.call();
    } else {
      final raw = _controller.text;
      final normalized = widget.normalize?.call(raw) ?? raw;
      final valid = widget.validate?.call(normalized) ?? true;
      if (!valid) {
        widget.onValidationFail?.call(normalized);
      } else if (normalized != widget.initialValue) {
        widget.onCommit(normalized);
      }
    }
    widget.onExit?.call();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      style: widget.style,
      decoration: widget.decoration,
      textAlign: widget.textAlign,
      textAlignVertical: widget.textAlignVertical,
      inputFormatters: widget.inputFormatters,
      keyboardType: widget.keyboardType,
      onSubmitted: (_) => _focusNode.unfocus(),
      onTapOutside: (_) {
        if (_focusNode.hasFocus) _focusNode.unfocus();
      },
    );
  }
}
