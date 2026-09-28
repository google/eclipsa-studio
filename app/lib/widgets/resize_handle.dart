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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';

/// The drag target on the border between two resizable segments.
///
/// It draws nothing at rest. The caller lays it [extent] thick across
/// the border, by default over the segment on the leading side (left
/// of a column border, above a row border) with its trailing edge on
/// the border line; [borderOffset] places the line elsewhere inside
/// the box when that side has no room. Over it the pointer takes the
/// resize cursor at once; after [hoverDelay], and at once when a drag
/// starts, a [lineWidth] line in the accent lights up over the border.
/// The line stays for the whole drag, and stays lit after it if the
/// pointer is still on the handle.
///
/// [axis] is the drag direction:
/// - [Axis.horizontal]: a column border, dragged left and right.
/// - [Axis.vertical]: a row border, dragged up and down.
///
/// Issue ES-748 has the design and the platform references for the delay.
class ResizeHandle extends ConsumerStatefulWidget {
  final Axis axis;
  final ValueChanged<double> onDragUpdate;

  /// Distance of the border line from the box's leading edge, in
  /// 0..[extent]. The lit line ends on it, drawn on its leading side,
  /// or starts on it when there is no room on that side.
  final double borderOffset;

  const ResizeHandle({
    super.key,
    required this.axis,
    required this.onDragUpdate,
    this.borderOffset = extent,
  });

  /// Thickness of the hit area, across the drag axis.
  static const double extent = 8;

  /// Thickness of the lit border line.
  static const double lineWidth = 2;

  /// Hover time before the line lights up, so it does not flash while
  /// the pointer crosses the border on its way elsewhere.
  static const Duration hoverDelay = Duration(milliseconds: 200);

  @override
  ConsumerState<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends ConsumerState<ResizeHandle> {
  bool _dragging = false;
  bool _inside = false;
  bool _hoverLit = false;
  Timer? _hoverTimer;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  void _enter() {
    _inside = true;
    _hoverTimer?.cancel();
    // dispose() cancels the timer, so it never fires unmounted.
    _hoverTimer = Timer(
      ResizeHandle.hoverDelay,
      () => setState(() => _hoverLit = true),
    );
  }

  void _exit() {
    _inside = false;
    _hoverTimer?.cancel();
    if (_hoverLit) setState(() => _hoverLit = false);
  }

  void _dragStart() => setState(() => _dragging = true);

  // A drag that ends on the handle leaves the line lit rather than
  // dropping it for what remains of the hover delay.
  void _dragEnd() => setState(() {
    _dragging = false;
    if (_inside) {
      _hoverTimer?.cancel();
      _hoverLit = true;
    }
  });

  @override
  Widget build(BuildContext context) {
    // The line takes the theme's accent, so the handle tracks the theme
    // itself rather than relying on an ancestor that happens to watch
    // it (the const-skip pattern).
    ref.watch(themeModeProvider);
    final lit = _dragging || _hoverLit;
    final horizontal = widget.axis == Axis.horizontal;

    return GestureDetector(
      // Opaque so the box takes hits across its whole extent; it draws
      // nothing at rest.
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: horizontal ? (_) => _dragStart() : null,
      onHorizontalDragUpdate: horizontal
          ? (d) => widget.onDragUpdate(d.delta.dx)
          : null,
      onHorizontalDragEnd: horizontal ? (_) => _dragEnd() : null,
      onHorizontalDragCancel: horizontal ? _dragEnd : null,
      onVerticalDragStart: horizontal ? null : (_) => _dragStart(),
      onVerticalDragUpdate: horizontal
          ? null
          : (d) => widget.onDragUpdate(d.delta.dy),
      onVerticalDragEnd: horizontal ? null : (_) => _dragEnd(),
      onVerticalDragCancel: horizontal ? null : _dragEnd,
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        onEnter: (_) => _enter(),
        onExit: (_) => _exit(),
        child: SizedBox(
          width: horizontal ? ResizeHandle.extent : null,
          height: horizontal ? null : ResizeHandle.extent,
          child: lit ? _line(horizontal) : null,
        ),
      ),
    );
  }

  /// The lit line, ending on the border, or starting on it when the
  /// border is closer than [ResizeHandle.lineWidth] to the leading edge.
  Widget _line(bool horizontal) {
    const w = ResizeHandle.lineWidth;
    final start = (widget.borderOffset - w).clamp(0.0, ResizeHandle.extent - w);
    final line = Container(
      key: const ValueKey('resize-handle-line'),
      color: T.purple,
    );
    return Stack(
      children: [
        horizontal
            ? Positioned(left: start, width: w, top: 0, bottom: 0, child: line)
            : Positioned(top: start, height: w, left: 0, right: 0, child: line),
      ],
    );
  }
}
