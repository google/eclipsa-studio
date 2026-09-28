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

// Pins the ASIO trademark obligations the Steinberg agreement and usage
// guidelines set (ES-888): the notice text is the one the agreement fixes,
// the Audio settings show the notice only when an ASIO device is
// listed, and every theme shows the same logo at the same size — only
// the plate behind it follows the theme's brightness.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/ffi_bridge.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/asio_trademark_notice.dart';

AudioDeviceInfo _device(int i, String name) =>
    AudioDeviceInfo(index: i, name: name, isDefault: i == 0, maxChannels: 2);

String _shownLogo(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  return (image.image as AssetImage).assetName;
}

/// Fill of the plate drawn behind the logo, or null when there is none.
Color? _plateColour(WidgetTester tester) {
  final boxes = find.ancestor(
    of: find.byType(Image),
    matching: find.byType(DecoratedBox),
  );
  for (final box in tester.widgetList<DecoratedBox>(boxes)) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration.color;
    }
  }
  return null;
}

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  test('notice is the text of section 3.1k of the agreement', () {
    expect(
      kAsioTrademarkNotice,
      'ASIO is a trademark of Steinberg Media Technologies GmbH, '
      'registered in Europe and other countries.',
    );
  });

  test('an ASIO device is recognised by the engine suffix only', () {
    expect(listsAsioDevice(const []), isFalse);
    expect(
      listsAsioDevice([
        _device(0, 'Speakers (Realtek)'),
        _device(1, 'ASIO4ALL'),
      ]),
      isFalse,
      reason:
          'a driver named ASIO4ALL without the suffix is not listed '
          'by the ASIO backend',
    );
    expect(
      listsAsioDevice([
        _device(0, 'Speakers (Realtek)'),
        _device(1, 'Focusrite USB ASIO$kAsioDeviceSuffix'),
      ]),
      isTrue,
    );
  });

  for (final mode in [
    AppThemeMode.light,
    AppThemeMode.dark,
    AppThemeMode.classic,
    AppThemeMode.highContrast,
  ]) {
    testWidgets('shows the logo and the notice in ${mode.name}', (
      tester,
    ) async {
      T.setMode(mode);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: AsioTrademarkNotice())),
        ),
      );
      expect(find.text(kAsioTrademarkNotice), findsOneWidget);
      expect(
        _shownLogo(tester),
        kAsioLogo,
        reason:
            'one lockup in every theme: the SDK ships the ™ and ® '
            'designs at different aspect ratios, so switching asset '
            'with the theme resized the logo',
      );
      expect(
        tester.widget<Image>(find.byType(Image)).height,
        AsioTrademarkNotice.logoHeight,
      );
    });
  }

  testWidgets('a light theme backs the white logo with a plate', (
    tester,
  ) async {
    T.setMode(AppThemeMode.light);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: AsioTrademarkNotice())),
      ),
    );
    expect(
      _plateColour(tester),
      isNotNull,
      reason: 'the bare white mark would be invisible on a light theme',
    );
  });

  for (final mode in [
    AppThemeMode.dark,
    AppThemeMode.classic,
    AppThemeMode.highContrast,
  ]) {
    testWidgets('${mode.name} shows the logo without a plate', (tester) async {
      T.setMode(mode);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: AsioTrademarkNotice())),
        ),
      );
      expect(_plateColour(tester), isNull);
    });
  }
}
