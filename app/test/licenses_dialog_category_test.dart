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

import 'package:eclipsa_studio/widgets/licenses_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

// The Third-Party Licenses dialog groups an entry by the kind main.dart
// recorded for it in nativeKinds; a label with no recorded kind is a pub
// package, whatever characters the label contains.
void main() {
  setUp(LicensesDialog.nativeKinds.clear);
  tearDown(LicensesDialog.nativeKinds.clear);

  test('an engine entry is listed under the native libraries', () {
    LicensesDialog.nativeKinds['zlib — zlib License'] = 'engine';
    expect(
      LicensesDialog.sectionLabelFor('zlib — zlib License'),
      'Audio Engine — Native Libraries',
    );
  });

  test('a framework entry is listed under the bundled frameworks', () {
    LicensesDialog.nativeKinds['ANGLE (libEGL, libGLESv2) — BSD'] = 'framework';
    expect(
      LicensesDialog.sectionLabelFor('ANGLE (libEGL, libGLESv2) — BSD'),
      'Bundled Frameworks',
    );
  });

  test('a label without a recorded kind is a pub package', () {
    expect(
      LicensesDialog.sectionLabelFor('flutter_riverpod'),
      'Flutter & Dart Packages',
    );
    expect(
      LicensesDialog.sectionLabelFor('Eigen — MPL 2.0'),
      'Flutter & Dart Packages',
    );
  });
}
