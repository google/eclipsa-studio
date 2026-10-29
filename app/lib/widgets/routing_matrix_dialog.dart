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

import '../export/iamf_profile_rules.dart';
import '../models/audio_element_enums.dart';
import '../models/layout_916.dart';
import '../state.dart';
import '../theme.dart';
import 'ae_type_badge.dart';
import 'app_button.dart';
import 'app_dialog.dart';
import 'console_widgets.dart';
import 'eyebrow_label.dart';
import 'routing_cell.dart';
import 'routing_labels.dart';

/// Outcome of [showRoutingMatrixDialog].
class RoutingMatrixResult {
  const RoutingMatrixResult({required this.routing, this.config});

  /// The routing to persist: `routing[dest] = src`, `-1` = silence. An
  /// empty list signals identity routing over the full source count (the
  /// engine fast path) — callers persist that as `inputRouting = null`.
  final List<int> routing;

  /// Non-null when the user changed the element's format in the dialog —
  /// apply it alongside the routing (type/layout/order/isDual).
  final ElementConfig? config;
}

/// Show the Format & Routing dialog — the sole surface for switching
/// an element's format (type/layout/order), with the input routing
/// matrix below it.
///
/// Returns the updated routing (plus an optional format change) on
/// Apply, or null on Cancel.
///
/// Axis convention: rows = output (IAMF destination) channels,
/// columns = input (WAV source) channels. Cells are click-to-toggle:
/// tapping a selected cell silences the row (`-1`). Matches the
/// engine's `routing[dest] = src` gather convention. The trivial 1×1
/// matrix (mono or WAV-less source with a mono-out format) is hidden —
/// only the format picker shows.
///
/// The format picker lists the whole config universe with each
/// option's output channel count; only [profile] gates selectability
/// (greyed + "needs Base-Enhanced"). Prominence ranks the rest:
/// exact-count interpretations of the source render at full strength,
/// while other pairings — down-maps, wider beds (unrouted channels
/// stay silent), scene targets over non-ambisonic sources (routed
/// channels are consumed as ACN components) — stay selectable but
/// de-emphasized, with a tooltip spelling out the caveat.
Future<RoutingMatrixResult?> showRoutingMatrixDialog({
  required BuildContext context,
  required AudioElement element,
  required IamfProfile profile,
}) {
  return showAppDialog<RoutingMatrixResult>(
    context: context,
    builder: (_) => _RoutingMatrixDialog(element: element, profile: profile),
  );
}

class _RoutingMatrixDialog extends ConsumerStatefulWidget {
  final AudioElement element;
  final IamfProfile profile;

  const _RoutingMatrixDialog({required this.element, required this.profile});

  @override
  ConsumerState<_RoutingMatrixDialog> createState() =>
      _RoutingMatrixDialogState();
}

class _RoutingMatrixDialogState extends ConsumerState<_RoutingMatrixDialog> {
  /// Routing indexed by output channel: `_routing[dest] = src`,
  /// `-1` = silence. Length matches the selected format's output
  /// channel count (not the WAV's source count).
  late List<int> _routing;

  /// Every format the picker lists: the natural fits first (exact
  /// interpretations, then down-maps), then the rest of the config
  /// universe (selectable but de-emphasized, with a caveat tooltip).
  /// `_config` is the current selection, `_initial` the element's
  /// format on open.
  late List<ElementConfig> _options;
  late ElementConfig _initial;
  late ElementConfig _config;

  /// Labels of the source's exact-count interpretations — the obvious
  /// picks, rendered at full prominence in the picker.
  late Set<String> _exactLabels;

  @override
  void initState() {
    super.initState();
    final el = widget.element;
    _exactLabels = validConfigsForChannelCount(
      _inputChannels,
    ).map((c) => c.label).toSet();
    _options = routableConfigsForChannelCount(_inputChannels);
    final routableLabels = _options.map((c) => c.label).toSet();
    _options = [
      ..._options,
      for (final c in allElementConfigs())
        if (!routableLabels.contains(c.label)) c,
    ];
    final idx = _options.indexWhere((c) => c.label == el.configLabel);
    if (idx >= 0) {
      _initial = _options[idx];
    } else {
      // The element carries a format outside the routable set (e.g. a
      // custom layout) — keep it selectable so opening the dialog never
      // forces a change.
      _initial = (
        label: el.configLabel,
        type: el.type,
        layout: el.layout,
        ambisonicsOrder: el.type == 'Scene' ? el.ambisonicsOrder : null,
        isDual: el.type == 'Object' ? el.isDual : null,
      );
      _options = [_initial, ..._options];
    }
    _config = _initial;
    _routing = _materializeRouting(el, _outputChannelCount());
  }

  // ── Derived properties ─────────────────────────────────────────

  int get _inputChannels => widget.element.wavInfo?.channels ?? 1;

  int _outputChannelCount() =>
      elementConfigChannelCount(_config, _inputChannels);

  /// Seed `_routing` from the element's current `inputRouting`. Null
  /// = identity = `[0, 1, ..., n-1]`. Length is clamped/padded to
  /// the output channel count so existing routings survive layout
  /// changes without crashing (unused tails become `-1` = silent).
  List<int> _materializeRouting(AudioElement el, int outCh) {
    final r = el.inputRouting;
    if (r == null) {
      return List<int>.generate(outCh, (i) => i);
    }
    return List<int>.generate(outCh, (i) => i < r.length ? r[i] : -1);
  }

  bool get _isIdentity {
    for (var i = 0; i < _routing.length; i++) {
      if (_routing[i] != i) return false;
    }
    return true;
  }

  /// Switch the target format: resize the routing to the new output
  /// count, preserving edits on surviving rows and seeding new rows
  /// with identity where a source channel exists.
  void _selectFormat(ElementConfig cfg) {
    setState(() {
      final old = _routing;
      _config = cfg;
      final outCh = _outputChannelCount();
      _routing = List<int>.generate(outCh, (i) {
        if (i < old.length) return old[i];
        return i < _inputChannels ? i : -1;
      });
    });
  }

  void _apply() {
    // Identity routing collapses to [] (persisted as null — the engine
    // fast path) only when output and source counts match; a down-mapped
    // format always keeps an explicit matrix so the element's channel
    // shape is self-describing (export validation reads it).
    final routing = _isIdentity && _routing.length == _inputChannels
        ? const <int>[]
        : List<int>.from(_routing);
    Navigator.of(context).pop(
      RoutingMatrixResult(
        routing: routing,
        config: _config.label == _initial.label ? null : _config,
      ),
    );
  }

  // ── UI ─────────────────────────────────────────────────────────

  static const double _cellSize = 28.0;
  static const double _rowHeaderW = 64.0;

  List<String> _outputLabels(int count) {
    if (_config.type == 'Scene') {
      return ambisonicsOrderLabels(_config.ambisonicsOrder ?? 1);
    }
    return iamfChannelLabels(
      channelCount: count,
      layoutHint: _config.layout ?? '',
    );
  }

  /// Short description of the element's IAMF output, shown rotated
  /// on the left of the matrix so the user knows what rows map to.
  /// Layout only ("Mono", "5.1", "3OA") — the full config label would
  /// overflow the height of a 1–2 row matrix, and the type is already
  /// visible in the format picker directly above.
  String _outputAxisLabel() => _config.layout ?? _config.label;

  /// Source channels referenced by at least one output row. Used to
  /// dim input columns that aren't wired to anything so the user sees
  /// at a glance which WAV channels are contributing.
  Set<int> get _referencedInputs {
    final s = <int>{};
    for (final src in _routing) {
      if (src >= 0) s.add(src);
    }
    return s;
  }

  /// Only the profile gates selectability — any format can be paired
  /// with any source via the matrix (missing sources = silent rows).
  bool _formatEnabled(ElementConfig c) =>
      c.label == _initial.label || profileAllowsConfig(widget.profile, c);

  /// Note text shown right of an option: its output channel count,
  /// plus the profile explainer when the option is disabled.
  String _formatNote(ElementConfig c) {
    final count = '${elementConfigChannelCount(c, _inputChannels)}ch';
    if (_formatEnabled(c)) return count;
    final min = minProfileForConfig(c);
    return '$count · ${min == null ? 'not supported' : 'needs ${min.label}'}';
  }

  ElementConfig _byLabel(String label) =>
      _options.firstWhere((c) => c.label == label);

  Widget _formatPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EyebrowLabel('Audio Element Type'),
        const SizedBox(height: T.gapPair),
        ConsoleSelector<String>(
          value: _config.label,
          items: [for (final c in _options) (c.label, c.label)],
          itemEnabled: (label) => _formatEnabled(_byLabel(label)),
          itemNote: (label) => _formatNote(_byLabel(label)),
          // Exact-count interpretations of the source are the obvious
          // picks; everything else stays selectable but de-emphasized,
          // with a tooltip spelling out what the pairing does.
          itemProminent: (label) => _exactLabels.contains(label),
          // The 9.1.6 row's tooltip spells out the WAV's channel order.
          itemTooltip: (label) {
            final c = _byLabel(label);
            return [
              layout916OrderTooltip(c.layout ?? ''),
              configMismatchCaveat(c, _inputChannels),
            ].whereType<String>().join('\n\n');
          },
          itemLeading: (label) {
            final c = _byLabel(label);
            return AeTypeGlyph(type: c.type, size: T.iconXs);
          },
          onChanged: (label) {
            if (label == _config.label) return;
            _selectFormat(_byLabel(label));
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Self-track theme/font: shown via showDialog, so no parent rebuild
    // reaches it on a theme switch.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final outCh = _routing.length;
    final inCh = _inputChannels;
    final outLabels = _outputLabels(outCh);
    // 20 = axisGutter for the rotated row-axis label in _buildMatrix.
    final totalWidth = 20 + _rowHeaderW + _cellSize * inCh + 24;

    return AlertDialog(
      backgroundColor: T.bgSurface,
      title: Text(
        'Type & Routing — ${widget.element.name}',
        style: T.styleHeading,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: totalWidth.clamp(260, 700), child: _formatPicker()),
            // Hide only the trivial 1×1 matrix (mono source, mono-out
            // format). A wide legacy format over a mono source (possible
            // via the _initial escape hatch) still gets its real N×1
            // matrix.
            if (inCh > 1 || outCh > 1) ...[
              const SizedBox(height: T.gapSection),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: totalWidth.clamp(260, 700),
                      child: _buildMatrix(outCh, inCh, outLabels),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        Row(
          children: [
            // Re-seed the matrix to identity for the *current* format —
            // undoing in-dialog edits is Cancel's job, so this leaves
            // the type selection alone. Hidden with the matrix (1×1),
            // where it would be meaningless.
            if (inCh > 1 || outCh > 1)
              AppButton(
                label: 'Reset Routing',
                role: AppButtonRole.quiet,
                onPressed: () => setState(() {
                  _routing = List<int>.generate(
                    outCh,
                    (i) => i < inCh ? i : -1,
                  );
                }),
              ),
            const Spacer(),
            AppButton(
              label: 'Cancel',
              role: AppButtonRole.quiet,
              onPressed: () => Navigator.of(context).pop(null),
            ),
            const SizedBox(width: 8),
            AppButton(
              label: 'Apply',
              role: AppButtonRole.affirmative,
              onPressed: _apply,
            ),
          ],
        ),
      ],
    );
  }

  // ── Matrix ─────────────────────────────────────────────────────

  Widget _buildMatrix(int outCh, int inCh, List<String> outLabels) {
    final referenced = _referencedInputs;
    final axisLabelStyle = TextStyle(
      fontSize: T.fontCaption,
      color: T.textSecondary,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.3,
    );
    const double axisGutter = 20.0; // Width reserved for the rotated
    // row-axis label on the far left.
    const double sourceHeaderHeight = 18.0;
    const double columnNumbersHeight = 16.0;
    const double headerSpacing = 6.0 + 4.0; // Matches SizedBoxes below.
    final double headerBlockHeight =
        sourceHeaderHeight + columnNumbersHeight + headerSpacing;
    // A scene's rows group by ambisonic order: ACN 0–3 (1st order),
    // 4–8 (2nd), 9–15 (3rd), 16–24 (4th). Draw a thin divider where
    // each new order starts — row (o+1)² — so the groups read at a
    // glance.
    const double orderDividerH = 7.0;
    final orderBreaks = _config.type == 'Scene'
        ? {
            for (var o = 1; o <= 3; o++)
              if ((o + 1) * (o + 1) < outCh) (o + 1) * (o + 1),
          }
        : const <int>{};
    final double matrixBodyHeight =
        outCh * _cellSize + orderBreaks.length * orderDividerH;

    final columns = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // "Source Channels" axis label, centered over the input columns.
        // The label is wider than a 1–2 column span; the OverflowBox
        // lets it spill symmetrically past the span on one line instead
        // of wrapping into the fixed-height header and clipping (ES-455).
        // The spill stays within the empty row-header corner on the
        // left and the dialog gutter on the right.
        SizedBox(
          height: sourceHeaderHeight,
          child: Row(
            children: [
              SizedBox(width: _rowHeaderW),
              SizedBox(
                width: _cellSize * inCh,
                child: OverflowBox(
                  // Only maxWidth is lifted; the span's tight minWidth
                  // still stretches the Text on wide matrices, where
                  // textAlign (not the box alignment) centers the
                  // glyphs. Both are needed — they cover the two
                  // regimes.
                  maxWidth: double.infinity,
                  alignment: Alignment.center,
                  child: Text(
                    'Source Channels',
                    style: axisLabelStyle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: T.gapPair),
        // Column headers (input channel numbers). Unreferenced columns
        // (no row routes from them) render dimmed so the user sees
        // which WAV channels aren't in use.
        SizedBox(
          height: columnNumbersHeight,
          child: Row(
            children: [
              SizedBox(width: _rowHeaderW),
              for (var c = 0; c < inCh; c++)
                SizedBox(
                  width: _cellSize,
                  child: Center(
                    child: Text(
                      '${c + 1}',
                      style: TextStyle(
                        fontSize: T.fontCaption,
                        color: referenced.contains(c)
                            ? T.textTertiary
                            : T.textGhost,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Matrix rows (one per output channel), with order-group
        // dividers between ambisonic components.
        for (var r = 0; r < outCh; r++) ...[
          if (orderBreaks.contains(r))
            SizedBox(
              height: orderDividerH,
              width: _rowHeaderW + _cellSize * inCh,
              child: Center(
                // Deliberately faint — a hint of grouping, not a rule.
                child: Container(
                  height: 1,
                  width: double.infinity,
                  color: T.border.withValues(alpha: 0.6),
                ),
              ),
            ),
          _buildRow(
            r,
            inCh,
            outLabels.length > r ? outLabels[r] : 'Ch ${r + 1}',
          ),
        ],
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Rotated row-axis label, centered vertically along the row
        // array (not the header block). Reads bottom-to-top, which is
        // the conventional y-axis direction for labelled matrices. The
        // OverflowBox lets a label longer than a short matrix (mono /
        // stereo out) spill symmetrically past the row array instead
        // of ellipsizing.
        SizedBox(
          width: axisGutter,
          child: Column(
            children: [
              SizedBox(height: headerBlockHeight),
              SizedBox(
                height: matrixBodyHeight,
                child: OverflowBox(
                  // Loosen BOTH bounds: without minHeight the child
                  // inherits the SizedBox's tight minimum and the text
                  // stretches to the full column, pinning its glyphs
                  // to the start — the bottom, after rotation.
                  minHeight: 0,
                  maxHeight: double.infinity,
                  alignment: Alignment.center,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text(_outputAxisLabel(), style: axisLabelStyle),
                  ),
                ),
              ),
            ],
          ),
        ),
        columns,
      ],
    );
  }

  Widget _buildRow(int row, int inCh, String rowLabel) {
    final src = _routing[row];
    final silenced = src < 0;
    // A 9.1.6 row's tooltip names the IAMF bitstream channel, by row
    // index as the monitoring routing matrix does (ES-960): L, R and Lss
    // are also other layouts' labels.
    final tooltips = layout916Tooltips(_config.layout ?? '');
    final tip = tooltips != null && row < tooltips.length
        ? tooltips[row]
        : null;
    final label = Text(
      rowLabel,
      style: TextStyle(
        fontSize: T.fontCaption,
        // Dim rows without a routing connection so the user
        // sees which output channels are silent.
        color: silenced ? T.textGhost : T.textSecondary,
      ),
      textAlign: TextAlign.right,
    );
    return SizedBox(
      height: _cellSize,
      child: Row(
        children: [
          SizedBox(
            width: _rowHeaderW,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: tip == null
                  ? label
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Tooltip(message: tip, child: label),
                    ),
            ),
          ),
          for (var c = 0; c < inCh; c++)
            RoutingCell(
              size: _cellSize,
              selected: src == c,
              color: T.purple,
              // Clicking a selected cell again clears the row (no
              // input → output is silenced). Clicking any other cell
              // moves the connection to that column.
              onTap: () => setState(() => _routing[row] = src == c ? -1 : c),
            ),
        ],
      ),
    );
  }
}
