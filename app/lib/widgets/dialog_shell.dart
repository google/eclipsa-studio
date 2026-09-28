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
import 'app_button.dart';

/// How [DialogShell] sizes its body slot.
enum DialogBodyFit {
  /// Body takes its intrinsic height; the dialog hugs its content.
  intrinsic,

  /// Body may shrink below, but never grow past, the dialog's max
  /// height — for scrollable content that should hug when short. The
  /// cap is [DialogShell.maxHeight] when given, else the route's own
  /// constraints (screen minus inset).
  flexible,

  /// Body fills all remaining height (requires [DialogShell.height]
  /// or [DialogShell.maxHeight]).
  expand,
}

/// Shared modal dialog scaffold: one shell recipe and one footer-action
/// convention for every window-style dialog.
///
/// Owns the surface (elevated background, radius, hairline border), the
/// 24 px content padding, the optional title/subtitle block, and the
/// right-aligned footer row. The standard dismiss affordance is a
/// bottom-right affirmative [AppButton] labelled "Done"
/// ([DialogShell.done]); dialogs whose body scrolls under the footer
/// set [footerDivider] so a hairline marks the boundary.
///
/// Two dialog layers exist deliberately:
///  * panels — window-style surfaces (settings, browsers, reports) use
///    this shell with an AppButton footer;
///  * alerts — confirmations and error notices stay on Material
///    [AlertDialog] (or `showOkDialog`/`showWarningDialog`) with
///    [AppButton] actions: Cancel is a quiet button directly left of
///    the affirmative, destructive non-affirmative and tertiary
///    actions go far left (a destructive *primary* like Delete stays
///    rightmost), and destructive actions take the destructive role, a
///    rim with an errorRed label, never the accent fill.
///
/// Dismissal policy (ES-639): every dialog is shown through
/// `showAppDialog`, which turns the background barrier off, so a click
/// outside never closes a dialog, and binds Esc to pop with null, the
/// outcome of the Cancel or Done button. Dialogs that report a running
/// operation with no user action pass `DialogEscape.none`; a dialog
/// that binds Esc itself (the export dialog) does the same.
class DialogShell extends ConsumerWidget {
  final String? title;
  final String? subtitle;
  final Widget child;

  /// Footer actions, right-aligned with 8 px gaps. Null hides the
  /// footer entirely (e.g. progress dialogs).
  final List<Widget>? actions;

  final double width;
  final double? height;
  final double? maxHeight;
  final DialogBodyFit bodyFit;

  /// Hairline between body and footer. Set when the body scrolls, so
  /// content sliding under the footer reads as clipped, not cut off.
  final bool footerDivider;

  /// Null defers to [Dialog]'s own default inset.
  final EdgeInsets? insetPadding;

  /// Drawn under the title, inside the head, with the head's 24 px
  /// padding around it: the Settings dialog's tab row. It sits in the
  /// head in every theme, so the dialog's geometry does not depend on
  /// which theme grounds the head; the raised style draws the tab row
  /// on the `chromeBg` head.
  final Widget? headBelow;

  const DialogShell({
    super.key,
    this.title,
    this.subtitle,
    required this.child,
    this.actions,
    this.width = 560,
    this.height,
    this.maxHeight,
    this.bodyFit = DialogBodyFit.intrinsic,
    this.footerDivider = false,
    this.insetPadding,
    this.headBelow,
  }) : assert(
         bodyFit != DialogBodyFit.expand || height != null || maxHeight != null,
         'expand body needs a height bound',
       );

  /// The standard dismiss action: an affirmative "Done" button that
  /// pops the dialog.
  static Widget done(BuildContext context) => AppButton(
    label: 'Done',
    role: AppButtonRole.affirmative,
    onPressed: () => Navigator.of(context).pop(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track theme + font size: the shell reads T.* and its own
    // const constructor makes call sites canonicalizable — without
    // these watches a const-constructed panel would freeze on the old
    // theme (the const-skip trap).
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final actions = this.actions;
    final body = switch (bodyFit) {
      DialogBodyFit.intrinsic => child,
      DialogBodyFit.flexible => Flexible(child: child),
      DialogBodyFit.expand => Expanded(child: child),
    };

    // The raised style draws a dialog as two grounds, the way its
    // landing card and its element panel are drawn: a `chromeBg` head
    // carrying the title over a `bgSurface` body. The head is the
    // rectangle the title block already occupied -- the 24 px padding
    // moves inside it, and the 24 px gap below the title splits 12 px
    // inside the head and 12 px above the body -- so
    // the dialog's size and the title's position are the same in every
    // theme and only the ground changes. The title keeps the app's own
    // case and size; case is content, not a drawing (the workspace tabs
    // are capitalised in every theme).
    final raised = T.chromeStyle == ChromeStyle.raised;
    final head = title == null && headBelow == null
        ? null
        : Container(
            width: double.infinity,
            color: raised ? T.chromeBg : null,
            // The raised head is the chrome ground over a `chromeRim`
            // line, as the top bar is: on Light `chromeBg` equals the
            // dialog's `bgSurface`, so the line is what marks the head.
            // Drawn in the foreground so it adds no height and the
            // dialog's geometry stays the same in every theme.
            foregroundDecoration: raised
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: T.chromeRim)),
                  )
                : null,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, T.gapMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: raised
                        ? T.styleDialogTitle.copyWith(color: T.chromeInk)
                        : T.styleDialogTitle,
                  ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: raised
                        ? T.styleBodySecondary.copyWith(color: T.chromeInk)
                        : T.styleBodySecondary,
                  ),
                ],
                if (headBelow != null) ...[
                  if (title != null) const SizedBox(height: T.gapXl),
                  headBelow!,
                ],
              ],
            ),
          );

    return Dialog(
      insetPadding: insetPadding,
      backgroundColor: raised ? T.bgSurface : T.bgElevated,
      // Clipped so the head takes the dialog's own top corners.
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.radius),
        side: BorderSide(color: T.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: width,
          maxWidth: width,
          minHeight: height ?? 0,
          maxHeight: height ?? maxHeight ?? double.infinity,
        ),
        child: Column(
          mainAxisSize: bodyFit == DialogBodyFit.expand
              ? MainAxisSize.max
              : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?head,
            // The head sits above the body in a column of its own, so
            // the body's section has to carry the fit that used to be
            // the shell's: a Column hands its children unbounded
            // height, and both a Flexible body and an Expanded one need
            // a bounded box to size against.
            _fit(
              bodyFit,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  head == null ? 24 : T.gapMd,
                  24,
                  24,
                ),
                child: Column(
                  mainAxisSize: bodyFit == DialogBodyFit.expand
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    body,
                    if (actions != null) ...[
                      if (footerDivider) ...[
                        const SizedBox(height: T.gapMd),
                        Container(height: 1, color: T.border),
                        const SizedBox(height: T.gapMd),
                      ] else
                        const SizedBox(height: T.gapXl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          for (var i = 0; i < actions.length; i++) ...[
                            if (i > 0) const SizedBox(width: T.gapSm),
                            actions[i],
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// [child] under the flex the [DialogBodyFit] asks for, so the body
  /// section gets the bounded height its own fit needs.
  static Widget _fit(DialogBodyFit fit, {required Widget child}) =>
      switch (fit) {
        DialogBodyFit.intrinsic => child,
        DialogBodyFit.flexible => Flexible(child: child),
        DialogBodyFit.expand => Expanded(child: child),
      };
}
