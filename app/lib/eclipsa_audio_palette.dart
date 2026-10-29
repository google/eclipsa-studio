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

import 'package:flutter/material.dart';

/// The six colours of the Eclipsa Audio logo. They are Google brand
/// greys and are fixed: the logo's colours must not be altered, so
/// these do not vary by theme.
///
/// The greyscale symbol uses [grey400], [grey500] and [grey600] with a
/// [black] or [white] core; the wordmark is [black] on a light ground
/// and [white] on a dark one.
class EclipsaAudioPalette {
  EclipsaAudioPalette._();

  static const Color black = Color(0xFF000000);

  /// Grey 600.
  static const Color grey600 = Color(0xFF80868B);

  /// Grey 500.
  static const Color grey500 = Color(0xFF9AA0A6);

  /// Grey 400.
  static const Color grey400 = Color(0xFFBDC1C6);

  static const Color white = Color(0xFFFFFFFF);
}
