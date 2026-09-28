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
import '../widgets/landing_glow.dart';
import 'workspace_mode.dart';

/// The landing screen's ground, painted by the app root behind the
/// whole window while the landing screen shows (ES-757). The titlebar,
/// the Windows menu bar and the landing screen draw transparent over
/// it by the same [landingVisibleProvider] rule, so the four cannot
/// disagree.
///
/// A vertical gradient from `landingGroundTop` to `landingGroundBottom`,
/// flat where a theme's pair is equal. Dark paints its glow over the
/// ground ([LandingGlow]), as the theme's floating card style asks.
class LandingGround extends ConsumerWidget {
  const LandingGround({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Constructed const, so it watches the theme itself.
    ref.watch(themeModeProvider);
    // The glow belongs to the theme whose landing card floats (Dark).
    final glow = T.cardStyle == CardStyle.floating;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [T.landingGroundTop, T.landingGroundBottom],
            ),
          ),
        ),
        if (glow) const LandingGlow(),
      ],
    );
  }
}
