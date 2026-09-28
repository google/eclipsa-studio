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

import 'dart:io' show Platform;

/// Where the user changes an output device's sample rate, for UI text:
/// the engine adopts the device's rate and never sets it (see
/// `engine/io/`), so a rate mismatch is fixed in the OS tool.
String get deviceRateTool =>
    Platform.isWindows ? "the device's control panel" : 'Audio MIDI Setup';
