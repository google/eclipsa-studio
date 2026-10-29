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

// A WAV without ADM metadata in the Import ADM dialog (ES-1008): the probe
// reports it as a plain WAV, the dialog says so with Import disabled and
// the import fields hidden, and "Open as Plain WAV" closes the dialog with
// that choice. An ADM master keeps the import fields and gets no offer.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eclipsa_studio/import/adm_import_bridge.dart';
import 'package:eclipsa_studio/import/adm_import_flow.dart';
import 'package:eclipsa_studio/state.dart' show IamfProfile;
import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/app_button.dart';
import 'package:eclipsa_studio/widgets/app_dialog.dart';
import 'package:eclipsa_studio/widgets/console_widgets.dart'
    show ConsoleSelector;

import '../support/engine_dylib.dart';

/// The probe JSON the engine writes for a 12-channel WAV with no `axml`
/// chunk: its format, `adm: null` and an empty scene.
const _plainWavProbe = '''
{"ok":true,"format":{"channels":12,"sample_rate":48000,"bits_per_sample":24,
"is_float":false,"num_frames":480000,"duration_s":10.0,"axml_bytes":0,
"chna_bytes":0,"extra_chunks":[{"id":"bext","bytes":602}]},"adm":null,
"scene":{"sources":[],"objects":[]},"unresolved":[],"warnings":[]}''';

const _admProbe = '''
{"ok":true,"format":{"channels":2,"sample_rate":48000,"bits_per_sample":24,
"is_float":false,"num_frames":48000,"duration_s":1.0,"axml_bytes":4096,
"chna_bytes":84,"extra_chunks":[]},"adm":{"objects":0},
"scene":{"sources":[],"objects":[]},"unresolved":[],"warnings":[]}''';

void main() {
  group('decodeAdmProbe', () {
    test('a probe with no ADM metadata is a plain WAV', () {
      final outcome = decodeAdmProbe('/tmp/bed.wav', _plainWavProbe);
      expect(outcome.plainWav, isTrue);
      expect(outcome.error, isNull);
      expect(outcome.data!.channels, 12);
      expect(outcome.data!.sources, isEmpty);
    });

    test('a probe with ADM metadata is not', () {
      final outcome = decodeAdmProbe('/tmp/master.wav', _admProbe);
      expect(outcome.plainWav, isFalse);
      expect(outcome.data, isNotNull);
    });

    test('the engine probes a WAV without axml as a plain WAV', () {
      final dylib = engineDylibOrSkip();
      if (dylib == null) return;
      useEngineDylib(dylib);
      final dir = Directory.systemTemp.createTempSync('adm_no_metadata');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/bed.wav';
      File(path).writeAsBytesSync(wavBytes(channels: 12));

      final json = AdmImportBridge.openAt(dylib.path).probeJson(path);
      final outcome = decodeAdmProbe(path, json);
      expect(outcome.plainWav, isTrue, reason: json);
      expect(outcome.data!.channels, 12);
    });
  });

  group('the Import ADM dialog', () {
    Object? result;

    Future<void> openDialog(
      WidgetTester tester,
      String path,
      String probeJson,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      result = null;
      final outcome = decodeAdmProbe(path, probeJson);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: eclipsaStudioTheme(),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showAppDialog<Object>(
                    context: context,
                    builder: (_) => AdmImportConfigDialog(
                      inPath: path,
                      probing: Future.value(outcome),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a WAV without ADM metadata: the message, Import disabled', (
      tester,
    ) async {
      await openDialog(tester, '/tmp/bed.wav', _plainWavProbe);

      expect(find.text('This WAV file has no ADM metadata.'), findsOneWidget);
      final import = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Import'),
      );
      expect(import.onPressed, isNull);
      // The format shows under the file name; the profile, folder and
      // name, which Open as Plain WAV would drop, are not offered.
      expect(find.text('12 ch · 48 kHz · 24-bit · 00:10.000'), findsOneWidget);
      expect(find.byType(ConsoleSelector<IamfProfile>), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(AppButton, 'Choose…'), findsNothing);
    });

    testWidgets('a WAV without ADM metadata: Open as Plain WAV closes the '
        'dialog with that choice', (tester) async {
      await openDialog(tester, '/tmp/bed.wav', _plainWavProbe);

      await tester.tap(find.widgetWithText(AppButton, 'Open as Plain WAV'));
      await tester.pumpAndSettle();
      // Cancel closes with null, and Import is disabled.
      expect(result, isNotNull);
    });

    testWidgets('an ADM master: no plain-WAV offer, the import fields', (
      tester,
    ) async {
      await openDialog(tester, '/tmp/master.wav', _admProbe);

      expect(find.text('This WAV file has no ADM metadata.'), findsNothing);
      expect(find.widgetWithText(AppButton, 'Open as Plain WAV'), findsNothing);
      expect(find.byType(ConsoleSelector<IamfProfile>), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Choose…'), findsOneWidget);
    });
  });
}
