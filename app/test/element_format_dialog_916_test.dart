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

// The add-WAV format dialog explains the 9.1.6 channel order in the
// tooltip of its row (ES-960), gives the default order in the row, names
// ACN/SN3D for ambisonics, and notes that the channels can be routed after
// import.

import 'package:eclipsa_studio/state.dart';
import 'package:eclipsa_studio/widgets/element_format_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the 9.1.6 row carries a channel-order tooltip', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showElementFormatDialog(
                context,
                fileName: 'bed.wav',
                channels: 16,
                profile: IamfProfile.baseEnhanced,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final tips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message ?? '')
        .toList();
    expect(
      tips.where((t) => t.startsWith('Channels in this order')),
      hasLength(1),
    );
    expect(tips.where((t) => t.contains('IAMF bitstream order')), hasLength(1));
  });

  testWidgets('the dialog says where the routing is changed after import', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showElementFormatDialog(
                context,
                fileName: 'bed.wav',
                channels: 16,
                profile: IamfProfile.baseEnhanced,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The channel routing can be changed afterwards: click the '
        'element\'s type in its track panel to open Type & Routing.',
      ),
      findsOneWidget,
    );
    // The 9.1.6 row gives the default order the routing starts from.
    expect(
      find.text(
        'Immersive bed with six heights, default channel order '
        'L R C LFE Lw Rw Lss Rss Lrs Rrs Ltf Rtf Lts Rts Ltr Rtr',
      ),
      findsOneWidget,
    );
    // The ambisonics row names IAMF's convention.
    expect(
      find.text('Third-order ambisonics soundfield, ACN/SN3D'),
      findsOneWidget,
    );
  });
}
