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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../meters/meter_provider.dart';
import '../state.dart';
import '../theme.dart';

/// Full-window takeover shown instead of the workspace when the native
/// engine failed to load (`engineLoadProvider` holds a failure).
///
/// The app is deliberately not operational without the engine — every
/// runtime feature (playback, meters, waveforms, export) depends on it,
/// and a half-working workspace reads as a broken app. This screen
/// states the failure and the remedy for its audience; recovery is a
/// relaunch (or hot restart in development) after fixing the engine.
class EngineUnavailableScreen extends ConsumerWidget {
  const EngineUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);

    // Sourced here rather than passed in so the failure case is
    // guaranteed by construction: this widget is only mounted when
    // the load failed, and the guard below covers the impossible
    // success state without a null-assert.
    final result = ref.watch(engineLoadProvider);
    final failure = result.failure;
    if (failure == null) return const SizedBox.shrink();

    final buildCmd = Platform.isWindows ? r'.\build.ps1 run' : './build.sh run';
    final (remedy, detailIsRelevant) = switch (failure) {
      EngineFailureKind.libraryNotLoaded => (
        'The audio engine library could not be loaded. If Eclipsa '
            'Studio runs from a source checkout, build the engine with '
            '"$buildCmd". If this is an installed copy of '
            'Eclipsa Studio, the installation may be damaged. '
            'Reinstall the app.',
        false, // dlopen search-path dump is long and unhelpful here
      ),
      EngineFailureKind.staleLibrary => (
        'The audio engine library is out of date for this version '
            'of Eclipsa Studio. Rebuild it with "$buildCmd".',
        true,
      ),
      EngineFailureKind.initFailed => (
        'The audio engine failed to start.',
        true,
      ),
    };

    return Scaffold(
      backgroundColor: T.bgDeep,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: T.iconHero,
                color: T.errorRed,
              ),
              const SizedBox(height: 20),
              Text(
                'Audio Engine Unavailable',
                style: TextStyle(
                  color: T.textPrimary,
                  fontSize: T.fontDisplay,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                remedy,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: T.textSecondary,
                  fontSize: T.fontBodyL,
                  height: 1.5,
                ),
              ),
              if (detailIsRelevant && result.failureDetail != null) ...[
                const SizedBox(height: 12),
                SelectableText(
                  result.failureDetail!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  style: TextStyle(
                    color: T.textMuted,
                    fontSize: T.fontSmall,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
