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

import 'package:eclipsa_studio/import/adm_import_warnings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AdmImportWarning _w(String severity, String code, String message) =>
    AdmImportWarning(severity: severity, code: code, message: message);

Widget _host(List<AdmImportWarning> warnings, {String? creates}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 440,
        child: AdmImportReportPanel(warnings: warnings, creates: creates),
      ),
    ),
  ),
);

void main() {
  group('decodeAdmImportWarnings', () {
    test('defaults a missing severity to warning and skips junk', () {
      final list = decodeAdmImportWarnings({
        'warnings': [
          {'severity': 'info', 'code': 'extra_chunk', 'message': 'a'},
          {'code': 'x', 'message': 'b'},
          {'severity': 'warning', 'message': ''},
          'not a map',
        ],
      });
      expect(list.length, 2);
      expect(list[0].isInfo, isTrue);
      expect(list[1].severity, 'warning');
      expect(list[1].code, 'x');
    });
  });

  group('AdmImportReportPanel', () {
    testWidgets('lists every notice, no amber', (tester) async {
      final notices = [
        for (var i = 0; i < 12; i++)
          _w('info', 'channel_fallback', 'Channel $i resolved via fallback'),
      ];
      await tester.pumpWidget(_host(notices));

      // Every message is present, not counted behind a summary line: the
      // box scrolls to the ones past its height rather than hiding them.
      for (var i = 0; i < 12; i++) {
        expect(find.text('Channel $i resolved via fallback'), findsOneWidget);
      }
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('holds one height whatever the count', (tester) async {
      await tester.pumpWidget(
        _host([_w('info', 'audit_unknown', 'One notice')]),
      );
      final short = tester.getSize(find.byType(AdmImportReportPanel)).height;
      await tester.pumpWidget(
        _host([
          for (var i = 0; i < 40; i++) _w('info', 'audit_unknown', 'Note $i'),
        ]),
      );
      final long = tester.getSize(find.byType(AdmImportReportPanel)).height;
      // One notice and forty lay the dialog out the same, so the action
      // buttons below the panel never move.
      expect(long, short);
    });

    testWidgets('what the import creates leads, and stays put', (tester) async {
      await tester.pumpWidget(
        _host([
          for (var i = 0; i < 40; i++) _w('info', 'audit_unknown', 'Note $i'),
        ], creates: 'Creates:\nmix.esp\nmix_7.1.4.wav'),
      );
      expect(find.textContaining('mix_7.1.4.wav'), findsOneWidget);
      // Pinned above the list, not scrolled with it: it is the line
      // checked before pressing Import and forty notices must not push it
      // out of sight.
      expect(
        tester.getTopLeft(find.textContaining('mix_7.1.4.wav')).dy,
        lessThan(tester.getTopLeft(find.text('Note 0')).dy),
      );
    });

    testWidgets('messages are selectable', (tester) async {
      await tester.pumpWidget(
        _host([_w('info', 'channel_fallback', 'Channel 0 via fallback')]),
      );
      // The messages are what a bug report quotes, so they sit in a
      // SelectionArea and can be dragged over as one block.
      expect(find.byType(SelectionArea), findsOneWidget);
    });

    testWidgets('warnings sit above the notices', (tester) async {
      await tester.pumpWidget(
        _host([
          _w('info', 'audit_unknown', '3 non-spec elements discarded'),
          _w(
            'warning',
            'channel_unresolved',
            'Channel X could not be resolved',
          ),
        ]),
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      // Given in notice-first order, the panel still puts the warning on
      // top so a short box cannot bury it.
      expect(
        tester.getTopLeft(find.text('Channel X could not be resolved')).dy,
        lessThan(
          tester.getTopLeft(find.text('3 non-spec elements discarded')).dy,
        ),
      );
    });
  });
}
