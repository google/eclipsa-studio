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

/// Entry in the recent QC files list with a security-scoped bookmark.
///
/// QC files (IAMF / MP4) are self-contained — unlike sessions, there
/// are no referenced media paths — so the bookmarks map only ever
/// holds the file itself. Storing it as a map anyway keeps the
/// on-disk schema parallel to `recent_sessions.json` and leaves room
/// to record companion files (e.g. an `.esp-qc` side-file) later.
class _RecentQcEntry {
  final String path;
  final Map<String, String> bookmarks;

  const _RecentQcEntry(this.path, [this.bookmarks = const {}]);

  Map<String, dynamic> toJson() => {
    'path': path,
    if (bookmarks.isNotEmpty) 'bookmarks': bookmarks,
  };

  factory _RecentQcEntry.fromJson(dynamic j) {
    if (j is String) return _RecentQcEntry(j);
    final map = j as Map<String, dynamic>;
    final path = map['path'] as String;
    final bookmarksRaw = map['bookmarks'] as Map<String, dynamic>?;
    if (bookmarksRaw != null) {
      return _RecentQcEntry(
        path,
        bookmarksRaw.map((k, v) => MapEntry(k, v as String)),
      );
    }
    return _RecentQcEntry(path);
  }
}

/// Persists a list of recently-opened IAMF / MP4 files for Playback
/// (QC) mode.
///
/// Parallel to `RecentSessions`: same 10-entry cap, same macOS
/// security-scoped bookmark plumbing, different on-disk filename.
/// Used by the landing screen's Playback card to populate its
/// "Recent" list.
class RecentQcFiles {
  static const _fileName = 'recent_qc_files.json';
  static const _maxEntries = 10;

  static final _bookmarks = SecureBookmarks();

  RecentQcFiles._();

  /// Get the list of recent QC file paths (most recent first).
  ///
  /// Resolves stored bookmarks to restore sandbox access, silently
  /// prunes entries whose files no longer exist on disk.
  static Future<List<String>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final raw = json.decode(content) as List<dynamic>;
      final entries = raw.map(_RecentQcEntry.fromJson).toList();

      final existing = <String>[];
      final accessible = <_RecentQcEntry>[];
      for (final entry in entries) {
        if (entry.bookmarks.isEmpty) {
          Log.w(
            LogCat.session,
            'No bookmarks stored for QC file ${entry.path}',
          );
        }

        for (final MapEntry(key: filePath, value: data)
            in entry.bookmarks.entries) {
          try {
            final resolved = await _bookmarks.resolveBookmark(data);
            await _bookmarks.startAccessingSecurityScopedResource(resolved);
          } on Exception catch (e) {
            Log.w(
              LogCat.session,
              'Failed to resolve QC bookmark for $filePath',
              e,
            );
          }
        }

        if (await File(entry.path).exists()) {
          existing.add(entry.path);
          accessible.add(entry);
        }
      }

      if (accessible.length < entries.length) {
        await _writeEntries(accessible);
      }

      return existing;
    } on IOException catch (e) {
      Log.w(LogCat.session, 'Failed to load recent QC files (IO)', e);
      return [];
    } on FormatException catch (e) {
      Log.w(LogCat.session, 'Recent QC files list is corrupted, resetting', e);
      return [];
    }
  }

  /// Add a path to the top of the recent list, creating a
  /// security-scoped bookmark for sandboxed reopening.
  static Future<void> add(String path) async {
    try {
      final bookmarks = <String, String>{};
      try {
        final data = await _bookmarks.bookmark(File(path));
        bookmarks[path] = data;
      } on Exception {
        // File not accessible — skip; `load()` will prune it later.
      }

      final entries = await _loadEntries();
      entries.removeWhere((e) => e.path == path);
      entries.insert(0, _RecentQcEntry(path, bookmarks));
      if (entries.length > _maxEntries) {
        entries.removeRange(_maxEntries, entries.length);
      }
      await _writeEntries(entries);
    } on IOException catch (e) {
      Log.w(LogCat.session, 'Failed to update recent QC files', e);
    }
  }

  /// Clear the recent list.
  static Future<void> clear() async {
    await _writeEntries([]);
  }

  /// Folder of the most recent QC file whose directory still exists, for
  /// seeding a file panel's starting location. Deliberately does *not* go
  /// through [load]: seeding a panel needs a path string, not file access,
  /// so resolving the stored bookmarks would be a side effect for nothing.
  /// Null when there is no usable recent entry.
  static Future<String?> lastDirectory() async {
    for (final entry in await _loadEntries()) {
      final dir = p.dirname(entry.path);
      if (Directory(dir).existsSync()) return dir;
    }
    return null;
  }

  static Future<List<_RecentQcEntry>> _loadEntries() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final raw = json.decode(content) as List<dynamic>;
      return raw.map(_RecentQcEntry.fromJson).toList();
    } on Exception {
      return [];
    }
  }

  /// Resolved path to the on-disk recent-QC-files file. Mirrors
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

  static Future<void> _writeEntries(List<_RecentQcEntry> entries) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(entries.map((e) => e.toJson()).toList()),
    );
  }
}
