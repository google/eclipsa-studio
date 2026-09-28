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
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/log.dart';

/// How [writeStringAtomically] replaced the file.
enum AtomicWriteMode {
  /// macOS: Foundation's atomic write through the `eclipsa/atomic_file`
  /// channel, which works with a grant to the file alone.
  native,

  /// A temp file beside the target, flushed, then renamed over it.
  rename,

  /// The target written in place, used only when the process may not
  /// create a file beside it. An interruption can leave it truncated.
  inPlace,
}

const _channel = MethodChannel('eclipsa/atomic_file');

/// Whether [code], an OS error code, means the process may not write
/// there: EPERM (1) or EACCES (13) on POSIX, ERROR_ACCESS_DENIED (5) on
/// Windows. The sets differ by platform: on POSIX 5 is EIO, an I/O
/// failure that must not take the in-place fallback.
@visibleForTesting
bool isPermissionErrorCode(int? code, {required bool windows}) =>
    windows ? code == 5 : (code == 1 || code == 13);

bool _isPermissionError(FileSystemException e) =>
    isPermissionErrorCode(e.osError?.errorCode, windows: Platform.isWindows);

final _random = Random();

/// Replaces the file at [path] with [content] so that a failed or
/// interrupted write leaves the previous file intact.
///
/// On macOS the write goes through Foundation's atomic write, which the
/// sandbox permits for a file granted by the Save panel even though the
/// app may not create other files beside it. Elsewhere, and when that
/// channel is not registered (tests), a temp file beside [path] is
/// written, flushed and renamed over it.
///
/// The rename gives [path] a new file: a symlinked `.esp` becomes a
/// regular file, and its mode bits and extended attributes are the
/// defaults for a new file.
///
/// Falls back to writing [path] in place only when the process is not
/// permitted to write beside it. Any other failure, such as a full disk,
/// throws a [FileSystemException] and leaves the previous file as it
/// was: falling back there would truncate the last good copy.
Future<AtomicWriteMode> writeStringAtomically(
  String path,
  String content,
) async {
  final bytes = Uint8List.fromList(utf8.encode(content));

  var permissionDenied = false;
  if (Platform.isMacOS) {
    try {
      await _channel.invokeMethod<void>('write', {
        'path': path,
        'bytes': bytes,
      });
      return AtomicWriteMode.native;
    } on MissingPluginException {
      // No runner (unit tests): the rename path below does the same job.
    } on PlatformException catch (e) {
      if (e.code != 'no_permission') {
        throw FileSystemException(e.message ?? e.code, path);
      }
      permissionDenied = true;
      Log.w(
        LogCat.session,
        'Atomic save not permitted for $path: ${e.message}',
      );
    }
  }

  if (!permissionDenied) {
    // A unique name, so two saves in flight cannot share one temp file.
    final tag = _random.nextInt(1 << 32).toRadixString(16);
    final tmp = File('$path.$pid.$tag.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
      return AtomicWriteMode.rename;
    } on FileSystemException catch (e) {
      await _deleteQuietly(tmp);
      if (!_isPermissionError(e)) rethrow;
      Log.w(LogCat.session, 'Cannot write beside $path: ${e.message}');
    }
  }

  Log.w(LogCat.session, 'Saving $path in place: no atomic replace permitted');
  await File(path).writeAsBytes(bytes, flush: true);
  return AtomicWriteMode.inPlace;
}

Future<void> _deleteQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } on FileSystemException {
    // Nothing more to do: the target is untouched either way.
  }
}
