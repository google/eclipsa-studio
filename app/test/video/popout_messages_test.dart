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

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:eclipsa_studio/video/popout_appearance.dart';
import 'package:eclipsa_studio/video/video_popout_app.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// The main window's pop-out message rules (ES-786): transport messages wait
// until the pop-out has opened its file, 'close' and 'appearance' are
// always sent, and a rejection by a pop-out without a handler is logged
// at debug, except for 'close'.
void main() {
  group('dropPopoutMessage', () {
    test('drops transport messages before the pop-out is ready', () {
      for (final method in ['seek', 'play', 'pause', 'sync']) {
        expect(dropPopoutMessage(method, ready: false), isTrue, reason: method);
      }
    });

    test('sends close before the pop-out is ready', () {
      expect(dropPopoutMessage('close', ready: false), isFalse);
    });

    // A pop-out whose file fails to load never sends 'requestSync', so it
    // is never marked ready; it must still follow theme and font changes.
    test('sends appearance before the pop-out is ready', () {
      expect(dropPopoutMessage(appearanceMethod, ready: false), isFalse);
    });

    test('sends everything once the pop-out is ready', () {
      for (final method in [
        'seek',
        'play',
        'pause',
        'sync',
        'close',
        appearanceMethod,
      ]) {
        expect(dropPopoutMessage(method, ready: true), isFalse, reason: method);
      }
    });
  });

  group('isUnregisteredPopoutRejection', () {
    final unregistered = WindowChannelException(
      'CHANNEL_UNREGISTERED',
      'Channel "eclipsa/video_popout" not accessible',
    );

    test('an unregistered channel during sync or seek is a close race', () {
      expect(isUnregisteredPopoutRejection('sync', unregistered), isTrue);
      expect(isUnregisteredPopoutRejection('seek', unregistered), isTrue);
    });

    test(
      'an appearance that arrives before the handler is logged at debug',
      () {
        expect(
          isUnregisteredPopoutRejection(appearanceMethod, unregistered),
          isTrue,
        );
      },
    );

    test('a quit request to a pop-out without a handler is expected', () {
      // A pop-out still starting has not registered its handler yet. A
      // timeout is not a rejection: the pop-out did not confirm that its
      // backend stopped.
      expect(
        isUnregisteredPopoutRejection('shutdownForQuit', unregistered),
        isTrue,
      );
      expect(
        isUnregisteredPopoutRejection(
          'shutdownForQuit',
          TimeoutException('no reply'),
        ),
        isFalse,
      );
    });

    test('a rejected close is not', () {
      expect(isUnregisteredPopoutRejection('close', unregistered), isFalse);
    });

    test('other channel errors are not', () {
      final limit = WindowChannelException('CHANNEL_LIMIT_REACHED', 'full');
      expect(isUnregisteredPopoutRejection('sync', limit), isFalse);
      expect(isUnregisteredPopoutRejection('sync', Exception('x')), isFalse);
    });
  });

  // After its backend teardown has started, the pop-out answers only the
  // quit request, which must wait for that teardown (ES-203).
  test('only shutdownForQuit is handled after the pop-out teardown', () {
    expect(handledAfterPopoutTeardown('shutdownForQuit'), isTrue);
    for (final m in ['play', 'pause', 'seek', 'sync', 'close', 'getBounds']) {
      expect(handledAfterPopoutTeardown(m), isFalse, reason: m);
    }
  });
}
