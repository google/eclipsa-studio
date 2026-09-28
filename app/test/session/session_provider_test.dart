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

import 'package:eclipsa_studio/export/iamf_profile_rules.dart';
import 'package:eclipsa_studio/renderer/viz_state.dart';
import 'package:eclipsa_studio/session/session_model.dart';
import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// [VizStateNotifier] whose [apply] throws, simulating a provider
/// mutation failing partway through `_applySession` — after `loading`
/// has been set but before the final state replacement clears it.
class _ThrowingVizNotifier extends VizStateNotifier {
  @override
  void apply(Map<String, dynamic>? json) {
    throw StateError('viz apply exploded');
  }
}

void main() {
  _classifyTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mid-apply failure clears loading so dirty tracking still works',
    () async {
      final dir = await Directory.systemTemp.createTemp('esp_test');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/session.esp';
      await File(
        path,
      ).writeAsString(const SessionModel().encode(relativeTo: dir.path));

      final container = ProviderContainer(
        overrides: [vizStateProvider.overrideWith(_ThrowingVizNotifier.new)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(sessionProvider.notifier);
      final ok = await notifier.loadFile(path);

      expect(ok, isFalse);
      final session = container.read(sessionProvider);
      expect(
        session.loading,
        isFalse,
        reason: 'a latched loading flag permanently disables DirtyTracker',
      );
      expect(session.lastError, contains('Could not load'));

      // DirtyTracker's guard (`!session.loading`) must pass again.
      notifier.markDirty();
      expect(container.read(sessionProvider).dirty, isTrue);
    },
  );

  test('unreadable file reports error without touching loading', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(sessionProvider.notifier);
    final ok = await notifier.loadFile('/nonexistent/nowhere.esp');

    expect(ok, isFalse);
    final session = container.read(sessionProvider);
    expect(session.loading, isFalse);
    expect(session.lastError, contains('Could not read'));
  });

  group('load-time profile validation (ES-490)', () {
    AudioElement object(int id) => AudioElement(
      id: id,
      name: 'Obj $id',
      type: 'Object',
      layout: 'Mono',
      codec: 'LPCM',
      color: 0xFF000000,
    );

    test('conflicting session raises a non-modal notice with a bump', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionProvider.notifier);

      // Base forbids object-based elements — the issue's repro case.
      notifier.warnOnProfileConflicts(
        SessionModel(iamfProfile: IamfProfile.base, elements: [object(1)]),
      );

      final notice = container.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(
        notice!.severity,
        ImportNoticeSeverity.warning,
        reason: 'a warning dialog, never an import blocker',
      );
      expect(notice.title, 'Profile Conflict');
      expect(notice.message, contains('Base'));
      expect(notice.message, contains('object-based'));
      expect(notice.actionLabel, 'Switch to Base-Advanced');

      // The offered action performs the bump.
      notice.onAction!();
      expect(container.read(iamfProfileProvider), IamfProfile.baseAdvanced);
    });

    test('session that fits no profile still warns, without an action', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionProvider.notifier);

      notifier.warnOnProfileConflicts(
        SessionModel(
          iamfProfile: IamfProfile.base,
          elements: [for (var i = 1; i <= 29; i++) object(i)],
        ),
      );

      final notice = container.read(importNoticeProvider);
      expect(notice, isNotNull);
      expect(notice!.actionLabel, isNull);
      expect(notice.onAction, isNull);
    });

    test('clean session raises no notice', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionProvider.notifier);

      notifier.warnOnProfileConflicts(
        const SessionModel(iamfProfile: IamfProfile.baseAdvanced),
      );

      expect(container.read(importNoticeProvider), isNull);
    });

    test('profileLoadWarning names the profile and every conflict', () {
      final conflicts = profileConflicts(
        elements: [object(1)],
        mixes: [kDefaultMix],
        profile: IamfProfile.base,
      );
      expect(conflicts, isNotEmpty);
      final msg = profileLoadWarning(IamfProfile.base, conflicts);
      expect(msg, contains('does not fit its Base profile'));
      for (final c in conflicts) {
        expect(msg, contains(c.message));
      }
    });
  });
}

// ES-628: which remedy a failed WAV load is offered depends on where the file
// sits relative to the session and on whether the platform sandboxes reads.
void _classifyTests() {
  group('classifyMissingWav', () {
    test('beside or below the session on macOS is a grant problem', () {
      expect(
        classifyMissingWav(
          path: '/s/proj/bed.wav',
          sessionDir: '/s/proj',
          exists: false,
          isMacOS: true,
        ),
        MissingWavKind.noAccess,
      );
      expect(
        classifyMissingWav(
          path: '/s/proj/stems/a.wav',
          sessionDir: '/s/proj',
          exists: false,
          isMacOS: true,
        ),
        MissingWavKind.noAccess,
      );
    });

    test('inside a granted session folder the stat is trusted again', () {
      // The grant is what made the stat reliable: absent is missing (the
      // remedy is Locate…), present-but-unopenable is unreadable. Neither
      // sends the user back to the folder panel that cannot help (ES-628).
      expect(
        classifyMissingWav(
          path: '/s/proj/bed.wav',
          sessionDir: '/s/proj',
          exists: false,
          folderGranted: true,
          isMacOS: true,
        ),
        MissingWavKind.notFound,
      );
      expect(
        classifyMissingWav(
          path: '/s/proj/stems/a.wav',
          sessionDir: '/s/proj',
          exists: true,
          folderGranted: true,
          isMacOS: true,
        ),
        MissingWavKind.unreadable,
      );
    });

    test('elsewhere on macOS: present-but-unopenable vs absent', () {
      expect(
        classifyMissingWav(
          path: '/exports/mix.wav',
          sessionDir: '/s/proj',
          exists: true,
          isMacOS: true,
        ),
        MissingWavKind.noAccess,
      );
      expect(
        classifyMissingWav(
          path: '/exports/mix.wav',
          sessionDir: '/s/proj',
          exists: false,
          isMacOS: true,
        ),
        MissingWavKind.notFound,
      );
    });

    test('without a sandbox every failure is not-found', () {
      expect(
        classifyMissingWav(
          path: '/proj/bed.wav',
          sessionDir: '/proj',
          exists: true,
          isMacOS: false,
        ),
        MissingWavKind.notFound,
      );
    });

    test('a file the parser rejected is never a grant problem', () {
      // Beside the session and present, which the rules above would call
      // noAccess — but no grant makes a damaged file readable.
      expect(
        classifyMissingWav(
          path: '/s/proj/bed.wav',
          sessionDir: '/s/proj',
          exists: true,
          rejected: true,
          isMacOS: true,
        ),
        MissingWavKind.unreadable,
      );
    });

    test('no session folder (unsaved) falls back to the exists check', () {
      expect(
        classifyMissingWav(
          path: '/x/a.wav',
          sessionDir: null,
          exists: false,
          isMacOS: true,
        ),
        MissingWavKind.notFound,
      );
    });
  });
}
