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

import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logging/log.dart';

/// Persistent **folder-scoped** security-scoped bookmarks.
///
/// [RecentSessions] bookmarks individual *files* (the `.esp` + its media) so
/// they can be re-read on reopen. This complements it: it bookmarks the
/// session **folder** so the sandboxed app can *write new files into it*
/// (IAMF exports, ADM-rendered beds, future bounces) without re-prompting —
/// including across launches. A folder grant only exists when the user
/// selected the folder via a picker (e.g. ADM import's "Session folder"); a
/// plain Save-As grants the `.esp` file only, so [capture] is best-effort.
///
/// Access is started and held for the process lifetime (matching
/// [RecentSessions], which never stops accessing); the OS reclaims it on exit.
class FolderBookmarks {
  static const _fileName = 'folder_bookmarks.json';
  static final _bookmarks = SecureBookmarks();

  /// Folders we currently hold a live security-scoped grant for this session.
  static final Set<String> _active = {};

  FolderBookmarks._();

  /// Bookmark [folder] and persist it. No-op (logged) if the folder isn't
  /// currently accessible — e.g. a Save-As that only granted the `.esp` file.
  static Future<void> capture(String folder) async {
    if (!Platform.isMacOS) return;
    try {
      final data = await _bookmarks.bookmark(Directory(folder));
      final map = await _load();
      final key = canonicalFolder(folder);
      map[key] = data;
      await _save(map);
      _active.add(key);
      Log.d(LogCat.session, 'Bookmarked session folder: $key');
    } on Exception catch (e) {
      // Expected when we don't hold a folder-scoped grant (plain Save-As).
      Log.d(LogCat.session, 'Could not bookmark folder $folder: $e');
    }
  }

  /// Resolve [folder]'s stored bookmark and start accessing it, so writes into
  /// the folder succeed without a fresh picker grant. Returns true if the app
  /// now holds write access. Cheap to call repeatedly (cached per session).
  static Future<bool> ensureAccess(String folder) async {
    if (!Platform.isMacOS) return false;
    // A grant on any ancestor covers this folder too (a user who picked the
    // projects folder in the Grant Access panel, ES-628), so look the folder
    // up and then walk up towards the root.
    final candidates = folderBookmarkCandidates(folder);
    if (candidates.any(_active.contains)) return true;
    final map = await _load();
    for (final key in candidates) {
      final data = map[key];
      if (data == null) continue;
      try {
        final resolved = await _bookmarks.resolveBookmark(
          data,
          isDirectory: true,
        );
        final ok = await _bookmarks.startAccessingSecurityScopedResource(
          resolved,
        );
        if (ok) {
          _active.add(key);
          Log.d(LogCat.session, 'Restored access to folder: $key');
          return true;
        }
      } on Exception catch (e) {
        Log.w(LogCat.session, 'Failed to restore folder bookmark $key', e);
      }
    }
    return false;
  }

  /// On-disk path of the bookmark store (for the Settings reset surface).
  static Future<String> get path async => (await _file()).path;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<Map<String, String>> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return {};
      final raw =
          json.decode(await file.readAsString()) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      // Best-effort read: a corrupt store (bad JSON, wrong shape, or a
      // non-string value throwing TypeError on cast — an Error, not an
      // Exception) is non-fatal. Treat it as "no bookmarks".
      return {};
    }
  }

  static Future<void> _save(Map<String, String> map) async {
    final file = await _file();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(map));
  }
}

/// The store key for [folder]: its path with symlinks resolved, so the
/// folder a panel returns as `/tmp/x` and a session path spelled
/// `/private/tmp/x` share one entry. Falls back to the normalized path when
/// the folder cannot be resolved (it need not exist yet).
String canonicalFolder(String folder) {
  try {
    return p.normalize(Directory(folder).resolveSymbolicLinksSync());
  } on FileSystemException {
    return p.normalize(folder);
  }
}

/// [canonicalFolder] of [folder] followed by each of its ancestors up to the
/// root, nearest first — the lookup order for a folder grant.
List<String> folderBookmarkCandidates(String folder) {
  final out = <String>[];
  var dir = canonicalFolder(folder);
  while (true) {
    out.add(dir);
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return out;
}
