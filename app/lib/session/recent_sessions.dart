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

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logging/log.dart';

/// Entry in the recent sessions list with security-scoped bookmarks.
class _RecentEntry {
  final String path;

  /// Bookmarks for the session file and all referenced media files.
  /// Keys are absolute file paths, values are bookmark data strings.
  final Map<String, String> bookmarks;

  const _RecentEntry(this.path, [this.bookmarks = const {}]);

  Map<String, dynamic> toJson() => {
    'path': path,
    if (bookmarks.isNotEmpty) 'bookmarks': bookmarks,
  };

  /// Null for an entry in any other shape, such as the plain-string
  /// form that pre-release builds wrote: the caller skips it instead of
  /// failing the whole list with a TypeError.
  static _RecentEntry? tryFromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final path = j['path'];
    if (path is! String) return null;
    final bookmarksRaw = j['bookmarks'];
    if (bookmarksRaw is! Map<String, dynamic>) return _RecentEntry(path);
    return _RecentEntry(path, {
      for (final MapEntry(:key, :value) in bookmarksRaw.entries)
        if (value is String) key: value,
    });
  }

  /// The entries of a decoded recent-sessions file. A file that is not a
  /// JSON list yields none.
  static List<_RecentEntry> listFromJson(Object? decoded) => [
    if (decoded is List<dynamic>)
      for (final j in decoded) ?tryFromJson(j),
  ];
}

/// Persists a list of recently-opened session file paths.
///
/// On macOS, stores security-scoped bookmarks for the session file
/// and all referenced media (WAV, video) so the sandboxed app can
/// reopen everything across launches without re-prompting.
class RecentSessions {
  static const _fileName = 'recent_sessions.json';
  static const _maxEntries = 10;

  static final _bookmarks = SecureBookmarks();

  RecentSessions._();

  /// The session paths a decoded recent-sessions file yields, in order;
  /// entries in any shape other than `{path, bookmarks?}` are skipped.
  @visibleForTesting
  static List<String> pathsFromJson(Object? decoded) =>
      _RecentEntry.listFromJson(decoded).map((e) => e.path).toList();

  /// Get the list of recent session paths (most recent first).
  ///
  /// Resolves all stored bookmarks to restore sandbox access.
  static Future<List<String>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final entries = _RecentEntry.listFromJson(json.decode(content));

      final existing = <String>[];
      final accessible = <_RecentEntry>[];
      for (final entry in entries) {
        if (entry.bookmarks.isEmpty) {
          Log.w(LogCat.session, 'No bookmarks stored for ${entry.path}');
        }

        // Resolve all bookmarks to restore sandbox access
        for (final MapEntry(key: filePath, value: data)
            in entry.bookmarks.entries) {
          try {
            final resolved = await _bookmarks.resolveBookmark(data);
            await _bookmarks.startAccessingSecurityScopedResource(resolved);
          } on Exception catch (e) {
            Log.w(
              LogCat.session,
              'Failed to resolve bookmark for $filePath',
              e,
            );
          }
        }

        // Check if session file is accessible
        if (await File(entry.path).exists()) {
          existing.add(entry.path);
          accessible.add(entry);
        }
      }

      // Silently prune inaccessible entries from the persisted list.
      if (accessible.length < entries.length) {
        await _writeEntries(accessible);
      }

      return existing;
    } on IOException catch (e) {
      Log.w(LogCat.session, 'Failed to load recent sessions (IO)', e);
      return [];
    } on FormatException catch (e) {
      Log.w(LogCat.session, 'Recent sessions file is corrupted, resetting', e);
      return [];
    }
  }

  /// Add a path to the top of the recent list.
  ///
  /// [mediaPaths] are additional files (WAV, video) referenced by
  /// the session. Bookmarks are created for all accessible files.
  static Future<void> add(
    String path, {
    List<String> mediaPaths = const [],
  }) async {
    try {
      final allPaths = {path, ...mediaPaths};
      final bookmarks = <String, String>{};

      for (final filePath in allPaths) {
        try {
          final data = await _bookmarks.bookmark(File(filePath));
          bookmarks[filePath] = data;
        } on Exception {
          // File not accessible — skip (e.g. first load before
          // user has granted access to media files).
        }
      }

      Log.d(
        LogCat.session,
        'Bookmarked ${bookmarks.length}/${allPaths.length} files',
      );

      final entries = await _loadEntries();
      entries.removeWhere((e) => e.path == path);
      entries.insert(0, _RecentEntry(path, bookmarks));
      if (entries.length > _maxEntries) {
        entries.removeRange(_maxEntries, entries.length);
      }
      await _writeEntries(entries);
    } on IOException catch (e) {
      Log.w(LogCat.session, 'Failed to update recent sessions', e);
    }
  }

  /// Clear the recent list.
  static Future<void> clear() async {
    await _writeEntries([]);
  }

  /// Folder of the most recent session whose directory still exists, for
  /// seeding a file panel's starting location. Deliberately does *not* go
  /// through [load]: seeding a panel needs a path string, not file access,
  /// so resolving every stored bookmark would be a side effect for nothing.
  /// Null when there is no usable recent entry.
  static Future<String?> lastDirectory() async {
    for (final entry in await _loadEntries()) {
      final dir = p.dirname(entry.path);
      if (Directory(dir).existsSync()) return dir;
    }
    return null;
  }

  static Future<List<_RecentEntry>> _loadEntries() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      return _RecentEntry.listFromJson(json.decode(content));
    } on Exception {
      return [];
    }
  }

  /// Resolved path to the on-disk recent-sessions file. Mirrors
  /// `AppPreferences.path` so the Settings dialog can show users
  /// exactly which files a reset will affect.
  static Future<String> get path async {
    final file = await _file();
    return file.path;
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  static Future<void> _writeEntries(List<_RecentEntry> entries) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(entries.map((e) => e.toJson()).toList()),
    );
  }
}
