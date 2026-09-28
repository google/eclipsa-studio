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

import 'package:eclipsa_studio/theme.dart';
import 'package:eclipsa_studio/widgets/eclipsa_studio_lockup.dart';
import 'package:eclipsa_studio/widgets/eclipsa_studio_mark.dart';
import 'package:eclipsa_studio/widgets/eclipsa_studio_wordmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The lockup's contract is the brand lockup's three ratios, taken
// from the layout the widget produces rather than from its arithmetic.

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(home: Center(child: child)),
  ),
);

void main() {
  tearDown(() => T.setMode(T.defaultMode));

  testWidgets('the mark and the gap follow the type size', (tester) async {
    const fontSize = 36.0;
    await _pump(tester, const EclipsaStudioLockup(fontSize: fontSize));

    final mark = find.byType(EclipsaStudioMark);
    final markSize = tester.getSize(mark).width;
    expect(markSize, closeTo(fontSize / EclipsaStudioLockup.kTypeRatio, 1e-9));

    // The gap is measured from the cube's silhouette, not its box.
    final silhouette = markSilhouette(markSize).shift(tester.getTopLeft(mark));
    final wordLeft = tester.getTopLeft(find.byType(EclipsaStudioWordmark)).dx;
    expect(
      wordLeft - silhouette.right,
      closeTo(EclipsaStudioLockup.kGap * markSize, 1e-6),
    );
  });

  testWidgets('the release-stage label follows the pair, outside it', (
    tester,
  ) async {
    await _pump(tester, const EclipsaStudioLockup(fontSize: 36));
    final wordmark = tester.getRect(find.byType(EclipsaStudioWordmark));
    final label = tester.getRect(find.byType(ReleaseStageLabel));
    // The two edges meet exactly; the ratio makes the positions
    // irrational, so allow floating-point noise below a micro-pixel.
    expect(label.left, greaterThanOrEqualTo(wordmark.right - 1e-6));
    expect(find.text('BETA'), findsOneWidget);
  });
}
