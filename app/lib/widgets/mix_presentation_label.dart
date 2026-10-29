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

/// The label beside the mix presentation switcher. The beveled and
/// raised styles set it uppercase at `fontSmall` in `chromeInk`, with
/// -0.42 tracking in beveled and +0.42 in raised. The recessed and
/// outlined styles draw the app's form label, `T.styleLabel`, in
/// `chromeInk`. The weight is regular in every style so a text role has
/// one weight across the themes.
///
/// A ConsumerWidget that watches theme and font mode: it is constructed
/// `const` in the top bar and the gallery, so without the watch a theme
/// switch would leave it on the old chrome (pinned by
/// test/theme_font_staleness_test.dart).
class MixPresentationLabel extends ConsumerWidget {
  const MixPresentationLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    return switch (T.chromeStyle) {
      // The label is fontSmall in every style, the size `T.styleLabel`
      // sets.
      ChromeStyle.beveled => Text(
        'MIX PRESENTATION',
        style: TextStyle(
          fontSize: T.fontSmall,
          color: T.chromeInk,
          letterSpacing: -0.42,
        ),
      ),
      ChromeStyle.raised => Text(
        'MIX PRESENTATION',
        style: TextStyle(
          fontSize: T.fontSmall,
          color: T.chromeInk,
          letterSpacing: 0.42,
        ),
      ),
      // The form label in the chrome's own ink.
      ChromeStyle.recessed || ChromeStyle.outlined => Text(
        'Mix Presentation',
        style: T.styleLabel.copyWith(color: T.chromeInk),
      ),
    };
  }
}
