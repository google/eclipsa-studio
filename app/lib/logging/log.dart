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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Log severity levels, ordered by increasing severity.
enum LogLevel {
  debug,
  info,
  warn,
  error;

  String get label => switch (this) {
    debug => 'DBG',
    info => 'INF',
    warn => 'WRN',
    error => 'ERR',
  };
}

/// Well-known log categories.
abstract final class LogCat {
  static const app = 'app';
  static const elements = 'elements';
  static const engine = 'engine';
  static const session = 'session';
  static const transport = 'transport';
  static const video = 'video';
  static const flutter = 'flutter';
  static const waveform = 'waveform';
  static const meters = 'meters';
  static const audio = 'audio';
  static const device = 'device';
  static const graph = 'graph';
  static const oar = 'oar';
  static const export = 'export';
}

/// A single immutable log entry.
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String category;
  final String message;
  final String? detail;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.detail,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    timestamp: DateTime.parse(json['timestamp'] as String),
    level: LogLevel.values.byName(json['level'] as String),
    category: json['category'] as String,
    message: json['message'] as String,
    detail: json['detail'] as String?,
  );

  Map<String, dynamic> toJson() => {
    // Human-readable local-time timestamp so `cat`/`grep`/`jq`
    // workflows don't need a formatter. `DateTime.parse` round-
    // trips this form (no timezone marker → parsed as local).
    'timestamp': _formatTimestamp(timestamp),
    'level': level.name,
    'category': category,
    'message': message,
    if (detail != null) 'detail': detail,
  };

  String toFormattedString() {
    final d = detail != null ? ' | $detail' : '';
    return '[${_formatTimestamp(timestamp)}] [${level.label}] '
        '[$category] $message$d';
  }

  /// Format a [DateTime] as `YYYY-MM-DD HH:MM:SS.mmm` in local time.
  /// Shared by [toJson] (so the log file is readable) and
  /// [toFormattedString] (so console output matches the file).
  static String _formatTimestamp(DateTime t) =>
      '${t.year}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

/// Structured logger with ring buffer and file output.
class Log {
  Log._();

  /// Singleton instance.
  static final Log instance = Log._();

  /// Ring buffer capacity.
  static const int bufferSize = 500;

  /// Minimum level to record. Entries below this are discarded.
  LogLevel minLevel = LogLevel.debug;

  /// Pending DEBUG and INFO lines are written once they reach this many
  /// UTF-16 code units, or [writeDelay] after the first of them, or on
  /// [flush], whichever comes first. WARN and ERROR lines are written
  /// at once, so a line logged just before a native crash is on disk.
  static const int writeThreshold = 32 * 1024;

  /// How long a pending JSONL line waits before it is written.
  static const Duration writeDelay = Duration(milliseconds: 200);

  final List<LogEntry> _buffer = [];

  /// The open log file, written synchronously. Null when file logging
  /// is off or a write failed.
  RandomAccessFile? _file;

  /// JSONL lines not yet written to [_file].
  final StringBuffer _pending = StringBuffer();

  /// Writes [_pending] [writeDelay] after its first line.
  Timer? _writeTimer;
  String? _logFilePath;

  /// Held open for the process lifetime: the exclusive lock on the log
  /// file's `.lock` sidecar, so a second instance sees the file as taken
  /// (ES-661).
  RandomAccessFile? _lockHandle;

  /// Replaces the lock attempt in tests. Called with the log file's
  /// path; returns the handle holding the lock, or null when another
  /// process holds the file.
  @visibleForTesting
  static RandomAccessFile? Function(String path)? tryLockForTesting;

  /// The resolved log file path, or null if not yet initialized.
  String? get logFilePath => _logFilePath;

  /// All buffered entries (oldest first).
  List<LogEntry> get entries => List.unmodifiable(_buffer);

  /// Initialize file logging. Call once at startup with a writable
  /// directory path. The existing log file (if any) is truncated —
  /// each launch starts from an empty file.
  ///
  /// The file is taken under an exclusive lock on a `<file>.lock`
  /// sidecar, held until the process exits. A second instance of the
  /// app finds it taken and logs to `<name>-<pid>.jsonl` beside it
  /// instead: two processes writing one
  /// path through independent buffered sinks land their bytes at
  /// unrelated offsets and tear each other's records (ES-661).
  /// [logFilePath] reports whichever file was opened.
  ///
  /// [fileName] lets a secondary window (the video pop-out runs its own
  /// Flutter engine and re-enters `main()`) log to a *separate* file, so it
  /// doesn't truncate — and concurrently write to — the main window's log.
  ///
  /// The file is opened synchronously, so an open failure (sandbox
  /// denial, read-only FS, quarantined container, etc.) is caught
  /// here: [_file] stays `null` and the app keeps running with
  /// ring-buffer-only logging. A later write failure (disk full) drops
  /// to the same fallback. Either failure is surfaced through [Log.e],
  /// which reaches the ring buffer and, in debug, `debugPrint`.
  void initFile(
    String dirPath, {
    String fileName = 'eclipsa_studio_log.jsonl',
  }) {
    final primary = p.join(dirPath, fileName);
    String? takenBy;
    try {
      _lockHandle = _tryLock(primary);
      if (_lockHandle != null) {
        _logFilePath = primary;
      } else {
        takenBy = primary;
        _logFilePath = p.join(
          dirPath,
          '${p.basenameWithoutExtension(fileName)}-$pid'
          '${p.extension(fileName)}',
        );
        _lockHandle = _tryLock(_logFilePath!);
      }
      _file = File(_logFilePath!).openSync(mode: FileMode.write);
    } on FileSystemException catch (e) {
      _file = null;
      _lockHandle?.closeSync();
      _lockHandle = null;
      Log.e(LogCat.app, 'file logging disabled', e);
      return;
    }
    if (takenBy != null) {
      Log.w(
        LogCat.app,
        'another instance holds $takenBy; logging to $_logFilePath',
      );
    }
  }

  /// Takes an exclusive lock on `<path>.lock`, the sidecar that stands
  /// for the log file at [path]. Returns null when another process holds
  /// the lock. Throws on any other failure so [initFile] reports it as
  /// file logging disabled.
  ///
  /// The lock is on a sidecar, not on the log: on Windows `LockFileEx`
  /// blocks writes through any other handle, including the log file's,
  /// and on macOS closing any descriptor on a file drops the process's
  /// `fcntl` locks on it, which copying the log in [exportToFile] does.
  static RandomAccessFile? _tryLock(String path) {
    final hook = tryLockForTesting;
    if (hook != null) return hook(path);
    final handle = File('$path.lock').openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
      return handle;
    } on FileSystemException {
      handle.closeSync();
      return null;
    }
  }

  /// Release the file and its lock. For tests, which open several log
  /// files in one process; the app holds both until it exits.
  @visibleForTesting
  void closeFile() {
    flush();
    _file?.closeSync();
    _file = null;
    _lockHandle?.closeSync();
    _lockHandle = null;
    _logFilePath = null;
  }

  /// Clear all buffered entries.
  void clear() => _buffer.clear();

  void _add(LogLevel level, String category, String message, [Object? error]) {
    if (level.index < minLevel.index) return;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      message: message,
      detail: error?.toString(),
    );

    _buffer.add(entry);
    if (_buffer.length > bufferSize) {
      _buffer.removeAt(0);
    }

    // Append to log file (JSONL).
    if (_file != null) {
      _pending.writeln(json.encode(entry.toJson()));
      if (level.index >= LogLevel.warn.index ||
          _pending.length >= writeThreshold) {
        flush();
      } else {
        _writeTimer ??= Timer(writeDelay, flush);
      }
    }

    // DBG goes to file only; INFO+ goes to console in debug mode.
    if (kDebugMode && level.index >= LogLevel.info.index) {
      debugPrint(entry.toFormattedString());
    }
  }

  /// Query entries with optional filters.
  List<LogEntry> query({
    LogLevel? minLevel,
    String? category,
    int? limit,
    int? sinceMs,
  }) {
    var result = _buffer.where((e) {
      if (minLevel != null && e.level.index < minLevel.index) {
        return false;
      }
      if (category != null && e.category != category) return false;
      if (sinceMs != null && e.timestamp.millisecondsSinceEpoch <= sinceMs) {
        return false;
      }
      return true;
    }).toList();

    if (limit != null && result.length > limit) {
      result = result.sublist(result.length - limit);
    }
    return result;
  }

  /// Write every pending entry to the log file. Synchronous: when it
  /// returns, the entries are in the file (in the OS's page cache, so
  /// they survive the process being killed). Never throws; a write
  /// failure closes the file and leaves ring-buffer-only logging. A
  /// write that fails partway can leave a torn last line in the file.
  void flush() {
    _writeTimer?.cancel();
    _writeTimer = null;
    final file = _file;
    if (file == null || _pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    try {
      file.writeStringSync(text);
    } on FileSystemException catch (e) {
      _file = null;
      try {
        file.closeSync();
      } on FileSystemException {
        // Already failing; the handle is dropped either way.
      }
      Log.e(LogCat.app, 'file logging disabled after a write failure', e);
    }
  }

  /// Copy the current JSONL log file to [outputPath]. The raw JSONL
  /// is now human-readable on its own (timestamps are
  /// `YYYY-MM-DD HH:MM:SS.mmm` local-time strings), so there's no
  /// need to transform it — the copy is strictly more useful for
  /// bug reports because it preserves every field.
  ///
  /// Returns `true` on success, `false` if the log file doesn't
  /// exist yet or the copy failed. On failure the underlying error
  /// is routed through [Log.e] with the file path in [detail].
  static Future<bool> exportToFile(String outputPath) async {
    final inst = instance..flush();

    final logPath = inst._logFilePath;
    if (logPath == null) return false;

    try {
      final file = File(logPath);
      if (!file.existsSync()) return false;
      await file.copy(outputPath);
      return true;
    } on FileSystemException catch (e) {
      Log.e(LogCat.app, 'exportToFile failed', e);
      return false;
    }
  }

  // --- Static convenience methods ---

  /// Log at [LogLevel.debug].
  static void d(String category, String message, [Object? error]) =>
      instance._add(LogLevel.debug, category, message, error);

  /// Log at [LogLevel.info].
  static void i(String category, String message, [Object? error]) =>
      instance._add(LogLevel.info, category, message, error);

  /// Log at [LogLevel.warn].
  static void w(String category, String message, [Object? error]) =>
      instance._add(LogLevel.warn, category, message, error);

  /// Log at [LogLevel.error].
  static void e(String category, String message, [Object? error]) =>
      instance._add(LogLevel.error, category, message, error);
}
