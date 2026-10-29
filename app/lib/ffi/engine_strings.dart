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

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Decodes a NUL-terminated UTF-8 string from the engine. Bytes that are
/// not valid UTF-8, such as a character cut short where a fixed-size
/// engine buffer ends, decode to U+FFFD instead of throwing. [string] must
/// not be `nullptr`. This does not free [string]; the caller releases it.
String decodeEngineString(Pointer<Utf8> string) => utf8.decode(
  string.cast<Uint8>().asTypedList(string.length),
  allowMalformed: true,
);
