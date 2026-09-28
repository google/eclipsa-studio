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

import 'dart:convert';
import 'dart:io';

import 'package:eclipsa_studio/debug/control_channel.dart';
import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/workspace/workspace_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The /tab and /loop commands, against a mounted app whose provider
/// container the channel reaches through the navigator.
void main() {
  testWidgets('/tab and /loop drive the tab, the loop region and the '
      'toggle', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(navigatorKey: key, home: const SizedBox()),
      ),
    );
    final container = ProviderScope.containerOf(key.currentContext!);
    // The default transport is 312 s at 48 kHz.
    final rate = container.read(transportProvider).sampleRate;

    await tester.runAsync(() async {
      // See control_channel_test.dart: a real loopback client has to opt
      // out of the test binding's HttpOverrides, which a widget test
      // installs per test.
      HttpOverrides.global = null;
      final dir = await Directory.systemTemp.createTemp(
        'eclipsa_studio_cmd_test',
      );
      final channel = (await DebugControlChannel.start(
        navigatorKey: key,
        stateDir: dir.path,
      ))!;
      final json =
          jsonDecode(
                File(
                  '${dir.path}/eclipsa_studio_control.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final port = json['port']! as int;
      final token = json['token']! as String;

      Future<(int, String)> send(
        String method,
        String path, [
        Object? body,
      ]) async {
        final client = HttpClient();
        try {
          final request = await client.open(method, '127.0.0.1', port, path);
          request.headers.set('x-debug-token', token);
          if (body != null) request.write(jsonEncode(body));
          final response = await request.close();
          final text = await response.transform(utf8.decoder).join();
          return (response.statusCode, text);
        } finally {
          client.close();
        }
      }

      Future<int> post(String path, Object body) async =>
          (await send('POST', path, body)).$1;

      try {
        // Nothing is open yet: no tab to pick and no ruler for a loop.
        expect(await post('/tab', {'tab': 'elements'}), HttpStatus.conflict);
        expect(
          await post('/loop', {'start': 30, 'end': 90}),
          HttpStatus.conflict,
        );
        expect(container.read(loopRegionProvider), isNull);

        container.read(workspaceModeProvider.notifier).enterCreator();

        expect(await post('/tab', {'tab': 'renderer'}), HttpStatus.ok);
        expect(container.read(activeTabProvider), WorkspaceTabs.renderer);
        expect(
          await post('/tab', {'tab': 'inspector'}),
          HttpStatus.badRequest,
          reason: 'inspector is a Playback tab',
        );
        expect(await post('/tab', {'tab': 5}), HttpStatus.badRequest);

        expect(await post('/loop', {'start': 30, 'end': 90}), HttpStatus.ok);
        final region = container.read(loopRegionProvider)!;
        expect(region.startSample, 30 * rate);
        expect(region.endSample, 90 * rate);
        expect(container.read(loopingProvider), isTrue);

        final health =
            jsonDecode((await send('GET', '/health')).$2)
                as Map<String, Object?>;
        expect(health['tab'], WorkspaceTabs.renderer);
        expect(health['looping'], isTrue);
        expect(health['loop'], {'start': 30.0, 'end': 90.0});

        // A wrongly typed field is refused before anything is written.
        expect(
          await post('/loop', {'start': 10, 'end': 20, 'enabled': 'yes'}),
          HttpStatus.badRequest,
        );
        expect(container.read(loopRegionProvider)!.startSample, 30 * rate);
        expect(
          await post('/loop', {'clear': true, 'enabled': true}),
          HttpStatus.badRequest,
        );
        expect(container.read(loopRegionProvider), isNotNull);

        expect(await post('/loop', {'enabled': false}), HttpStatus.ok);
        expect(container.read(loopingProvider), isFalse);
        expect(container.read(loopRegionProvider), isNotNull);

        expect(
          await post('/loop', {'start': 90, 'end': 30}),
          HttpStatus.badRequest,
        );
        expect(await post('/loop', {'start': 30}), HttpStatus.badRequest);

        // A range past the end is clamped to the timeline.
        expect(await post('/loop', {'start': 300, 'end': 400}), HttpStatus.ok);
        expect(
          container.read(loopRegionProvider)!.endSample,
          container.read(transportProvider).durationSamples,
        );

        expect(await post('/loop', {'enabled': true}), HttpStatus.ok);
        expect(await post('/loop', {'clear': true}), HttpStatus.ok);
        expect(container.read(loopRegionProvider), isNull);
        expect(container.read(loopingProvider), isFalse);

        // With no region, clear leaves a whole-timeline loop armed, as
        // Escape does.
        expect(await post('/loop', {'enabled': true}), HttpStatus.ok);
        expect(await post('/loop', {'clear': true}), HttpStatus.ok);
        expect(container.read(loopingProvider), isTrue);

        // Playback shows no loop region, and has the inspector tab.
        container.read(workspaceModeProvider.notifier).enterPlayback();
        expect(
          await post('/loop', {'start': 30, 'end': 90}),
          HttpStatus.conflict,
        );
        expect(await post('/tab', {'tab': 'inspector'}), HttpStatus.ok);
        expect(container.read(activeTabProvider), WorkspaceTabs.inspector);
      } finally {
        await channel.close();
        dir.deleteSync(recursive: true);
      }
    });
  });
}
