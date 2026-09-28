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

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:eclipsa_studio/video/video_popout_app.dart';
import 'package:eclipsa_studio/video/video_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// The main window's pop-out message rules (ES-786): messages wait for the
// pop-out's handler, and a message that races the pop-out's close is
// logged at debug, except 'close'.
void main() {
  group('dropPopoutMessage', () {
    test('drops everything but close before the pop-out is ready', () {
      for (final method in ['seek', 'play', 'pause', 'sync', 'appearance']) {
        expect(dropPopoutMessage(method, ready: false), isTrue, reason: method);
      }
      expect(dropPopoutMessage('close', ready: false), isFalse);
    });

    test('sends everything once the pop-out is ready', () {
      for (final method in ['seek', 'play', 'pause', 'sync', 'close']) {
        expect(dropPopoutMessage(method, ready: true), isFalse, reason: method);
      }
    });
  });

  group('isClosingPopoutRejection', () {
    final unregistered = WindowChannelException(
      'CHANNEL_UNREGISTERED',
      'Channel "eclipsa/video_popout" not accessible',
    );

    test('an unregistered channel during sync or seek is a close race', () {
      expect(isClosingPopoutRejection('sync', unregistered), isTrue);
      expect(isClosingPopoutRejection('seek', unregistered), isTrue);
    });

    test('a rejected close is not', () {
      expect(isClosingPopoutRejection('close', unregistered), isFalse);
    });

    test('other channel errors are not', () {
      final limit = WindowChannelException('CHANNEL_LIMIT_REACHED', 'full');
      expect(isClosingPopoutRejection('sync', limit), isFalse);
      expect(isClosingPopoutRejection('sync', Exception('x')), isFalse);
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
