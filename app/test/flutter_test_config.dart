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

// Runs before every test file. Golden comparisons allow a difference of up
// to 0.1% of the image's pixels: the meter goldens, recorded on macOS 26,
// differ from the same painters on the macOS 15 image of the GitHub-hosted
// runners by 1 to 9 pixels of text anti-aliasing (0.02% at most). A real
// change to a painter moves far more than that.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The share of pixels a golden may differ by and still pass.
const double kGoldenTolerancePercent = 0.1;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final previous = goldenFileComparator as LocalFileComparator;
  // LocalFileComparator takes the test file's URI and uses its directory;
  // a placeholder file name in the same directory keeps the golden paths
  // resolving as before.
  goldenFileComparator = _TolerantGoldenComparator(
    previous.basedir.resolve('placeholder_test.dart'),
  );
  await testMain();
}

class _TolerantGoldenComparator extends LocalFileComparator {
  _TolerantGoldenComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= kGoldenTolerancePercent) {
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    throw FlutterError(error);
  }
}
