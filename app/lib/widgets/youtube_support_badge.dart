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

import 'status_tag.dart';

/// "Supported by YouTube" tag shown beside the IAMF profiles that YouTube's
/// upload pipeline accepts (Simple and Base — see
/// [IamfProfile.supportedByYouTube]). A [StatusTag] reading "YouTube" after
/// a play glyph, with the full phrase as its tooltip; rendered both on the
/// profile pickers' option rows and on the closed control when a supported
/// profile is selected, so it stays compact enough not to crowd the label.
///
/// The red is a fixed brand colour, deliberately theme-independent (it must
/// read the same in dark / light / high-contrast), so it is a local const
/// rather than a `T.*` token — a softened red, calmer than YouTube's neon
/// #FF0000 against a dark menu.
class YouTubeSupportBadge extends StatelessWidget {
  const YouTubeSupportBadge({super.key});

  static const Color _red = Color(0xFFD9534F);

  @override
  Widget build(BuildContext context) => const Tooltip(
    message: 'Supported by YouTube',
    child: StatusTag('YouTube', color: _red, icon: Icons.smart_display),
  );
}
