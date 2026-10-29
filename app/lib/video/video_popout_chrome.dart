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

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/text_width.dart';
import '../widgets/statusbar.dart';
import '../widgets/window_titlebar.dart';

/// The pop-out video window's chrome around [picture]: the window's
/// own title bar above the picture, a status strip below it, and
/// nothing drawn over the picture (ES-744).
///
/// Outside fullscreen a [WindowFrameStrip] heads the window with the
/// file name as [title], the platform's window controls and drag to
/// move. Closing goes through the window controls. A
/// [StatusbarStrip] under the picture shows [readout], the playhead
/// and the clip's duration, in the middle of the strip. So the
/// picture lies between the two strips and only chrome meets the
/// window's corners, as in the main window.
/// In fullscreen there is neither strip. The picture takes a
/// double-click for fullscreen; the caller wires it. The only key the
/// window acts on is Esc in fullscreen, which runs [onLeaveFullscreen]
/// (ES-797); see [keyResult] for the rest.
///
/// [readout] is a listenable rather than a string because it changes
/// per tick while playing: only the readout's text rebuilds then, not
/// the strips or the picture.
///
/// The pop-out draws in the theme and font size `main()` loads at
/// launch, and follows a change made in the main window while it is
/// open through the `appearance` message on the pop-out channel, which
/// sets `T` and rebuilds this widget.
class PopoutChrome extends StatelessWidget {
  const PopoutChrome({
    super.key,
    required this.title,
    required this.fullscreen,
    required this.readout,
    required this.onClose,
    required this.onToggleFullscreen,
    required this.onLeaveFullscreen,
    required this.picture,
  });

  final String title;
  final bool fullscreen;

  /// The status strip's text: the playhead, then ` / ` and the clip's
  /// duration when it is known, both through `formatDuration`.
  final ValueListenable<String> readout;
  final Future<void> Function() onClose;
  final VoidCallback onToggleFullscreen;

  /// Run by Esc in fullscreen. The fullscreen window has no title bar,
  /// and on Windows no other way out besides a double-click.
  final VoidCallback onLeaveFullscreen;
  final Widget picture;

  /// What the window does with a key event: apart from Esc in fullscreen
  /// it takes no keyboard input (ES-797), but it consumes the event rather
  /// than ignoring it, because macOS plays its alert sound for a key press
  /// no view handles.
  /// Command and Control chords are left unhandled so macOS can match
  /// them against the menu bar, and on Windows Alt chords are left
  /// unhandled so the system handles Alt+F4 and Alt+Space.
  @visibleForTesting
  static KeyEventResult keyResult({
    required bool meta,
    required bool control,
    required bool alt,
    required bool windows,
  }) => meta || control || (windows && alt)
      ? KeyEventResult.ignored
      : KeyEventResult.handled;

  /// The height the two strips add to the picture outside fullscreen.
  static const double chromeHeight = T.titlebar + T.statusbar;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      final keyboard = HardwareKeyboard.instance;
      if (fullscreen &&
          event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          !keyboard.isMetaPressed &&
          !keyboard.isControlPressed &&
          !keyboard.isAltPressed) {
        onLeaveFullscreen();
      }
      return keyResult(
        meta: keyboard.isMetaPressed,
        control: keyboard.isControlPressed,
        alt: keyboard.isAltPressed,
        windows: Platform.isWindows,
      );
    },
    child: Column(
      children: [
        if (!fullscreen) WindowFrameStrip(title: title, onClose: onClose),
        Expanded(
          child: GestureDetector(
            onDoubleTap: onToggleFullscreen,
            child: picture,
          ),
        ),
        if (!fullscreen)
          StatusbarStrip(
            children: [
              const Spacer(),
              ValueListenableBuilder<String>(
                valueListenable: readout,
                builder: (_, text, _) => _Readout(text: text),
              ),
              const Spacer(),
            ],
          ),
      ],
    ),
  );
}

/// The status strip's readout in the bar's own style with tabular
/// figures, in a box as wide as the readout with every digit an 8, so
/// the text does not jitter as the digits change. The box width is
/// measured once per widest string and style, not per tick.
class _Readout extends StatefulWidget {
  const _Readout({required this.text});

  final String text;

  @override
  State<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<_Readout> {
  String? _widest;
  TextStyle? _style;
  double _width = 0;

  @override
  Widget build(BuildContext context) {
    final style = statusbarTextStyle().copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final widest = widget.text.replaceAll(RegExp('[0-9]'), '8');
    if (widest != _widest || style != _style) {
      _widest = widest;
      _style = style;
      _width = widestTextWidth(context, [widest], style);
    }
    return SizedBox(
      width: _width,
      child: Text(widget.text, style: style, maxLines: 1, softWrap: false),
    );
  }
}
