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

// The Session Settings "Object mixes" row: Base-Advanced requires a mix
// presentation with object-based elements to hold only those, and the
// first mix presentation to be one of these when any includes them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/session_settings_dialog.dart';

import 'support/golden_fonts.dart';

AudioElement _element(int id, String type) => AudioElement(
  id: id,
  name: '$type $id',
  type: type,
  layout: type == 'Object' ? 'Mono' : 'Stereo',
  codec: 'LPCM',
  color: 0xFF000000,
);

/// A mix presentation that includes the elements [ids].
Mix _mix(int id, List<int> ids) => Mix(
  id: id,
  name: 'Mix $id',
  subMixes: [
    SubMix(
      elementSettings: [for (final e in ids) MixElementSettings(elementId: e)],
    ),
  ],
);

class _Elements extends ElementsNotifier {
  _Elements(this.value);
  final List<AudioElement> value;
  @override
  List<AudioElement> build() => value;
}

class _Mixes extends MixesNotifier {
  _Mixes(this.value);
  final List<Mix> value;
  @override
  List<Mix> build() => value;
}

class _Profile extends IamfProfileNotifier {
  _Profile(this.value);
  final IamfProfile value;
  @override
  IamfProfile build() => value;
}

Future<void> _pump(
  WidgetTester tester, {
  required IamfProfile profile,
  required List<AudioElement> elements,
  required List<Mix> mixes,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        iamfProfileProvider.overrideWith(() => _Profile(profile)),
        elementsProvider.overrideWith(() => _Elements(elements)),
        mixesNotifierProvider.overrideWith(() => _Mixes(mixes)),
      ],
      child: MaterialApp(
        theme: eclipsaStudioTheme(),
        home: const Scaffold(body: SessionSettingsDialog()),
      ),
    ),
  );
}

void main() {
  setUpAll(loadGoldenFonts);

  final object = _element(1, 'Object');
  final channel = _element(2, 'Channel');

  testWidgets('an object and a channel element in one mix is not met', (
    tester,
  ) async {
    await _pump(
      tester,
      profile: IamfProfile.baseAdvanced,
      elements: [object, channel],
      mixes: [
        _mix(1, [1, 2]),
      ],
    );
    expect(find.text('Object mixes'), findsOneWidget);
    expect(find.textContaining('Not met'), findsOneWidget);
    expect(
      find.textContaining(
        'Give object-based elements their own mix presentation',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an object-only mix after the first is not met', (tester) async {
    await _pump(
      tester,
      profile: IamfProfile.baseAdvanced,
      elements: [object, channel],
      mixes: [
        _mix(1, [2]),
        _mix(2, [1]),
      ],
    );
    expect(find.textContaining('Not met'), findsOneWidget);
    expect(
      find.textContaining('Move an object-only mix presentation first'),
      findsOneWidget,
    );
  });

  testWidgets('an object-only first mix is met', (tester) async {
    await _pump(
      tester,
      profile: IamfProfile.baseAdvanced,
      elements: [object, channel],
      mixes: [
        _mix(1, [1]),
        _mix(2, [2]),
      ],
    );
    expect(find.text('Met'), findsOneWidget);
    expect(find.textContaining('Not met'), findsNothing);
  });

  testWidgets('a session without objects reads No objects', (tester) async {
    await _pump(
      tester,
      profile: IamfProfile.baseAdvanced,
      elements: [channel],
      mixes: [
        _mix(1, [2]),
      ],
    );
    expect(find.text('No objects'), findsOneWidget);
  });

  // Both hints are wider than the dialog leaves them at every font
  // size, so they wrap; with the bundled fonts the longer one overflowed
  // the row by 95 px at the Medium size before the row wrapped.
  testWidgets('the hints wrap inside the dialog at every font size', (
    tester,
  ) async {
    addTearDown(() => T.setFontMode(FontSizeMode.medium));
    for (final font in FontSizeMode.values) {
      T.setFontMode(font);
      for (final mixes in [
        [
          _mix(1, [1, 2]),
        ],
        [
          _mix(1, [2]),
          _mix(2, [1]),
        ],
      ]) {
        await _pump(
          tester,
          profile: IamfProfile.baseAdvanced,
          elements: [object, channel],
          mixes: mixes,
        );
        expect(tester.takeException(), isNull, reason: font.name);
      }
    }
  });

  testWidgets('profiles without the rule have no Object mixes row', (
    tester,
  ) async {
    await _pump(
      tester,
      profile: IamfProfile.advanced1,
      elements: [object, channel],
      mixes: [
        _mix(1, [1, 2]),
      ],
    );
    expect(find.text('Object mixes'), findsNothing);
  });
}
