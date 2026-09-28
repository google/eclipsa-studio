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

/// Output-path rules for the export dialog: the auto-derived default
/// path, the path after a target switch, the save panel's answer, and
/// the check that decides whether a path may be written without the
/// save panel. The dialog passes in a file-existence callback;
/// [isSameOutputPath] reads the file system itself.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether [a] and [b] name the same file. When both exist the file
/// system decides, so a case-only difference on a case-insensitive
/// volume or a path through a symbolic link still matches. Otherwise the
/// canonicalized paths are compared. Returns false when either is null
/// or empty.
bool isSameOutputPath(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
  try {
    if (File(a).existsSync() && File(b).existsSync()) {
      return FileSystemEntity.identicalSync(a, b);
    }
  } on FileSystemException {
    // Fall through to the string comparison.
  }
  return p.equals(p.canonicalize(a), p.canonicalize(b));
}

/// The save panel's answer [picked] with exactly one `.ext` suffix: a
/// doubled `.ext.ext` is collapsed and a missing one is appended. The
/// comparison ignores case.
String normalizeSavePanelPath(String picked, String ext) {
  final dotExt = '.$ext';
  var out = picked;
  while (out.toLowerCase().endsWith('$dotExt$dotExt')) {
    out = out.substring(0, out.length - dotExt.length);
  }
  if (!out.toLowerCase().endsWith(dotExt)) out = '$out$dotExt';
  return out;
}

/// First of `dir/stem.ext`, `dir/stem-01.ext` … `dir/stem-99.ext` that
/// does not exist and is not [avoid] (the session's source video). When
/// all 100 are taken it returns `dir/stem-99.ext`; the dialog's
/// pre-export check then shows the save panel for it.
String uniqueOutputPath(
  String dir,
  String stem,
  String ext, {
  required bool Function(String path) exists,
  String? avoid,
}) {
  bool taken(String path) => exists(path) || isSameOutputPath(path, avoid);
  var path = p.join(dir, '$stem.$ext');
  if (!taken(path)) return path;
  for (var i = 1; i <= 99; i++) {
    final suffix = i.toString().padLeft(2, '0');
    path = p.join(dir, '$stem-$suffix.$ext');
    if (!taken(path)) return path;
  }
  return path;
}

/// Whether the export must show the save panel before it writes
/// [outputPath]. It must when the path is unconfirmed, when it names the
/// session's source video ([sourceVideoPath]), or when it names an
/// existing file other than [pickedPath], the last save-panel answer the
/// dialog accepted unchanged.
bool outputNeedsSavePanel({
  required String outputPath,
  required bool confirmed,
  required String? pickedPath,
  required String? sourceVideoPath,
  required bool Function(String path) exists,
}) {
  if (!confirmed) return true;
  if (isSameOutputPath(outputPath, sourceVideoPath)) return true;
  return exists(outputPath) && !isSameOutputPath(outputPath, pickedPath);
}
