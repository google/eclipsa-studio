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

// A session whose video failed to load offers the dead reference for
// removal in the empty video panel; removing it marks the session dirty
// so the next save drops the path.

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:eclipsa_studio/video/video_panel.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _tooltip = 'Remove the missing file gone.mp4 from the session';

void main() {
  Future<ProviderContainer> pumpPanel(
    WidgetTester tester, {
    String? missing,
  }) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    _StubSession.missing = missing;
    final c = ProviderContainer(
      overrides: [
        videoProvider.overrideWith(_StubVideoNotifier.new),
        sessionProvider.overrideWith(_StubSession.new),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 600, child: VideoPanel()),
            ),
          ),
        ),
      ),
    );
    return c;
  }

  testWidgets('a missing video can be removed from the session', (
    tester,
  ) async {
    final c = await pumpPanel(tester, missing: '/media/gone.mp4');
    expect(find.byTooltip(_tooltip), findsOneWidget);
    expect(c.read(sessionProvider).dirty, isFalse);

    await tester.tap(find.byTooltip(_tooltip));
    await tester.pump();
    expect(c.read(sessionProvider).missingMediaPath, isNull);
    expect(c.read(sessionProvider).dirty, isTrue);
    expect(find.byTooltip(_tooltip), findsNothing);
  });

  testWidgets('no remove action without a missing video', (tester) async {
    await pumpPanel(tester);
    expect(find.byTooltip(_tooltip), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });
}

/// A session loaded with [missing] as its media that failed to load.
class _StubSession extends SessionNotifier {
  static String? missing;

  @override
  SessionState build() => SessionState(missingMediaPath: missing);
}

/// The video state without a backend: [VideoNotifier.build] builds a
/// decoder, and these tests need none.
class _StubVideoNotifier extends VideoNotifier {
  @override
  VideoState build() => const VideoState();
}
