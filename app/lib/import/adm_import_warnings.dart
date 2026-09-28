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

/// One import warning from the probe's "warnings" array (built and deduped
/// on the C++ side; see adm2iamf_ffi.cc BuildWarnings).
class AdmImportWarning {
  const AdmImportWarning({
    required this.severity,
    required this.code,
    required this.message,
  });
  final String severity; // "info" | "warning"
  final String code; // e.g. "channel_fallback"
  final String message;

  /// Notices: routine for a vendor master (non-spec metadata discarded,
  /// channel labels resolved through a documented fallback, an ignored
  /// `bext` chunk). They never change the render, so they sort below the
  /// real warnings and only non-info warnings get the amber treatment
  /// (ES-553). The engine assigns the severity per code.
  bool get isInfo => severity == 'info';
}

/// Decodes the probe's warnings defensively: anything malformed is skipped
/// rather than failing the import.
List<AdmImportWarning> decodeAdmImportWarnings(Map<String, dynamic> probe) {
  final raw = probe['warnings'];
  if (raw is! List) return const [];
  final out = <AdmImportWarning>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final message = e['message'];
    if (message is! String || message.isEmpty) continue;
    final severity = e['severity'];
    final code = e['code'];
    out.add(
      AdmImportWarning(
        severity: severity is String ? severity : 'warning',
        code: code is String ? code : 'unknown',
        message: message,
      ),
    );
  }
  return out;
}

/// The import report box in the config dialog (the `_ValidationPanel`
/// idiom from the IAMF export dialog): what the import will write, then
/// one row per warning — non-info ones amber and first, routine notices
/// below them (ES-553).
///
/// [creates] leads, pinned above the list rather than scrolling with it.
/// It is the one line the user checks before pressing Import, and it must
/// not be pushed out of sight by a master carrying forty notices.
///
/// The list is plain and fixed-height, not a disclosure. Counting notices
/// by code behind a summary line kept a dozen routine ones from looking
/// like breakage, but it also put the message text — the thing a bug
/// report quotes — one click away, and the box changed height when opened,
/// which moved the dialog's buttons. The fixed height holds the layout
/// still whatever the file carries; the list scrolls, because the dialog's
/// content Column has no outer scroll view. Full detail (with codes) is
/// also in the JSONL log.
class AdmImportReportPanel extends StatefulWidget {
  const AdmImportReportPanel({
    super.key,
    required this.warnings,
    this.creates,
    this.expand = false,
  });
  final List<AdmImportWarning> warnings;

  /// What the import will write, already formatted. Null until the dialog
  /// has everything it needs to run.
  final String? creates;

  /// Fill the parent's height (the caller supplies a bounded one) instead
  /// of standing at [_AdmImportReportPanelState._kHeight]. Set where the
  /// panel is the last thing in a column that has slack to give it.
  final bool expand;

  @override
  State<AdmImportReportPanel> createState() => _AdmImportReportPanelState();
}

class _AdmImportReportPanelState extends State<AdmImportReportPanel> {
  /// Roughly six rows at the flow pane's width — enough for the common
  /// case to read at a glance without pushing the dialog's action buttons
  /// off a laptop screen. Held whatever the count, so a file with one
  /// notice and a file with forty lay the dialog out the same.
  static const double _kHeight = 160;

  // Owned explicitly and handed to both the Scrollbar and the scroll view,
  // matching the settings/routing dialogs.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(AdmImportWarning w) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          w.isInfo ? Icons.info_outline : Icons.warning_amber_rounded,
          size: T.iconXs,
          color: w.isInfo ? T.textSecondary : T.meterYellow,
        ),
        const SizedBox(width: T.gapPair),
        Expanded(
          child: Text(
            w.message,
            style: TextStyle(
              color: T.textSecondary,
              fontSize: T.fontBody,
              height: 1.3,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Problems first: a real warning must not be pushed under a run of
    // routine notices in a box that only shows six rows at a time.
    final rows = [
      ...widget.warnings.where((w) => !w.isInfo),
      ...widget.warnings.where((w) => w.isInfo),
    ];
    final amber = widget.warnings.any((w) => !w.isInfo);
    final creates = widget.creates;
    final list = Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scroll,
        // Keep the always-visible thumb off the message text.
        padding: const EdgeInsets.only(right: T.gapMd),
        // The messages are the useful output of a failed or surprising
        // import — a bug report quotes them — so they are selectable.
        // SelectionArea rather than per-row SelectableText: one drag takes
        // the whole box.
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [for (final w in rows) _row(w)],
          ),
        ),
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.gapMd),
      decoration: BoxDecoration(
        color: T.bgControls,
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: amber ? T.meterYellow.withValues(alpha: 0.3) : T.border,
        ),
      ),
      child: Column(
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (creates != null) ...[
            Text(
              creates,
              style: TextStyle(
                color: T.textPrimary,
                fontSize: T.fontSmall,
                height: 1.35,
              ),
            ),
            if (rows.isNotEmpty) ...[
              const SizedBox(height: T.gapSm),
              Container(height: 1, color: T.border),
              const SizedBox(height: T.gapSm),
            ],
          ],
          if (rows.isNotEmpty) _bound(list),
        ],
      ),
    );
  }

  /// The list either stands at its own height or takes the one the parent
  /// hands down. Either way it is bounded, which is what the scroll view
  /// needs — the dialog's content Column has no outer scroll view.
  Widget _bound(Widget child) => widget.expand
      ? Expanded(child: child)
      : SizedBox(height: _kHeight, child: child);
}
