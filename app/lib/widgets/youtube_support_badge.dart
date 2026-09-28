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

/// "Supported by YouTube" tag shown beside the IAMF profiles that YouTube's
/// upload pipeline accepts (Simple and Base — see
/// [IamfProfile.supportedByYouTube]). A compact "YouTube" pill (play glyph +
/// label) with the full phrase as its tooltip; rendered both on the profile
/// pickers' option rows and on the closed control when a supported profile is
/// selected, so it stays compact enough not to crowd the label.
///
/// Based on the [AeTypeBadge] pill style. The red is a fixed brand colour,
/// deliberately theme-independent (it must read the same in dark / light /
/// high-contrast), so it is a local const rather than a `T.*` token — a
/// softened red, calmer than YouTube's neon #FF0000 against a dark menu.
class YouTubeSupportBadge extends ConsumerWidget {
  const YouTubeSupportBadge({super.key});

  static const Color _red = Color(0xFFD9534F);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Self-track the font size: this badge is const-constructed at every call
    // site, so without watching the provider its T.fontCaption read would
    // freeze on a font-size change. The colours are a fixed brand red,
    // so themeMode needn't be watched.
    ref.watch(fontSizeModeProvider);
    return Tooltip(
      message: 'Supported by YouTube',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: _red.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.smart_display, size: 11, color: _red),
            const SizedBox(width: 4),
            Text(
              'YouTube',
              style: TextStyle(
                fontSize: T.fontCaption,
                color: _red,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
