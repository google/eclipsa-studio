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

import 'package:eclipsa_studio/logging/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  setUp(() {
    Log.instance
      ..clear()
      ..minLevel = LogLevel.debug;
  });

  group('LogEntry', () {
    test('toJson includes all fields', () {
      final entry = LogEntry(
        timestamp: DateTime(2024, 1, 15, 14, 28, 1, 234),
        level: LogLevel.warn,
        category: LogCat.waveform,
        message: 'Invalid WAV',
        detail: 'FormatException: bad header',
      );

      final json = entry.toJson();
      // Timestamp is serialized as a human-readable local-time string that
      // DateTime.parse round-trips (see LogEntry.toJson).
      expect(json['timestamp'], '2024-01-15 14:28:01.234');
      expect(json['level'], 'warn');
      expect(json['category'], 'waveform');
      expect(json['message'], 'Invalid WAV');
      expect(json['detail'], 'FormatException: bad header');
    });

    test('toJson omits detail when null', () {
      final entry = LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.info,
        category: LogCat.app,
        message: 'Started',
      );

      expect(entry.toJson().containsKey('detail'), isFalse);
    });

    test('toFormattedString includes all parts', () {
      final entry = LogEntry(
        timestamp: DateTime(2024, 1, 15, 14, 28, 1, 234),
        level: LogLevel.warn,
        category: LogCat.waveform,
        message: 'Invalid WAV',
        detail: 'bad header',
      );

      expect(
        entry.toFormattedString(),
        '[2024-01-15 14:28:01.234] [WRN] [waveform] Invalid WAV | bad header',
      );
    });

    test('toFormattedString without detail', () {
      final entry = LogEntry(
        timestamp: DateTime(2024, 1, 15, 9, 5, 3, 7),
        level: LogLevel.info,
        category: LogCat.app,
        message: 'Started',
      );

      expect(
        entry.toFormattedString(),
        '[2024-01-15 09:05:03.007] [INF] [app] Started',
      );
    });
  });

  group('LogLevel', () {
    test('labels are correct', () {
      expect(LogLevel.debug.label, 'DBG');
      expect(LogLevel.info.label, 'INF');
      expect(LogLevel.warn.label, 'WRN');
      expect(LogLevel.error.label, 'ERR');
    });

    test('index order matches severity', () {
      expect(LogLevel.debug.index, lessThan(LogLevel.info.index));
      expect(LogLevel.info.index, lessThan(LogLevel.warn.index));
      expect(LogLevel.warn.index, lessThan(LogLevel.error.index));
    });
  });

  group('Log static methods', () {
    test('Log.d creates debug entry', () {
      Log.d(LogCat.app, 'test debug');
      expect(Log.instance.entries, hasLength(1));
      expect(Log.instance.entries.first.level, LogLevel.debug);
      expect(Log.instance.entries.first.message, 'test debug');
    });

    test('Log.i creates info entry', () {
      Log.i(LogCat.engine, 'server up');
      expect(Log.instance.entries.first.level, LogLevel.info);
      expect(Log.instance.entries.first.category, 'engine');
    });

    test('Log.w creates warn entry', () {
      Log.w(LogCat.waveform, 'bad file');
      expect(Log.instance.entries.first.level, LogLevel.warn);
    });

    test('Log.e creates error entry', () {
      Log.e(LogCat.video, 'load failed');
      expect(Log.instance.entries.first.level, LogLevel.error);
    });

    test('error object is captured as detail', () {
      final err = FormatException('bad header');
      Log.w(LogCat.waveform, 'Invalid WAV', err);

      final entry = Log.instance.entries.first;
      expect(entry.detail, contains('bad header'));
    });
  });

  group('Ring buffer', () {
    test('entries accumulate', () {
      Log.i(LogCat.app, 'one');
      Log.i(LogCat.app, 'two');
      Log.i(LogCat.app, 'three');
      expect(Log.instance.entries, hasLength(3));
    });

    test('evicts oldest when exceeding bufferSize', () {
      for (var i = 0; i < Log.bufferSize + 10; i++) {
        Log.d(LogCat.app, 'msg $i');
      }
      expect(Log.instance.entries, hasLength(Log.bufferSize));
      // Oldest should be msg 10 (first 10 evicted)
      expect(Log.instance.entries.first.message, 'msg 10');
      expect(Log.instance.entries.last.message, 'msg ${Log.bufferSize + 9}');
    });

    test('clear empties buffer', () {
      Log.i(LogCat.app, 'something');
      Log.instance.clear();
      expect(Log.instance.entries, isEmpty);
    });
  });

  group('minLevel filtering', () {
    test('entries below minLevel are discarded', () {
      Log.instance.minLevel = LogLevel.warn;

      Log.d(LogCat.app, 'debug msg');
      Log.i(LogCat.app, 'info msg');
      Log.w(LogCat.app, 'warn msg');
      Log.e(LogCat.app, 'error msg');

      expect(Log.instance.entries, hasLength(2));
      expect(Log.instance.entries.map((e) => e.level), [
        LogLevel.warn,
        LogLevel.error,
      ]);
    });

    test('minLevel at error only keeps errors', () {
      Log.instance.minLevel = LogLevel.error;

      Log.d(LogCat.app, 'a');
      Log.i(LogCat.app, 'b');
      Log.w(LogCat.app, 'c');
      Log.e(LogCat.app, 'd');

      expect(Log.instance.entries, hasLength(1));
      expect(Log.instance.entries.first.level, LogLevel.error);
    });
  });

  group('query', () {
    setUp(() {
      Log.i(LogCat.app, 'startup');
      Log.w(LogCat.waveform, 'bad wav');
      Log.e(LogCat.video, 'load fail');
      Log.w(LogCat.waveform, 'another bad wav');
      Log.d(LogCat.session, 'debug detail');
    });

    test('no filters returns all', () {
      expect(Log.instance.query(), hasLength(5));
    });

    test('filter by minLevel', () {
      final result = Log.instance.query(minLevel: LogLevel.warn);
      expect(result, hasLength(3));
      expect(result.every((e) => e.level.index >= LogLevel.warn.index), isTrue);
    });

    test('filter by category', () {
      final result = Log.instance.query(category: LogCat.waveform);
      expect(result, hasLength(2));
      expect(result.every((e) => e.category == LogCat.waveform), isTrue);
    });

    test('filter by limit returns last N', () {
      final result = Log.instance.query(limit: 2);
      expect(result, hasLength(2));
      expect(result[0].message, 'another bad wav');
      expect(result[1].message, 'debug detail');
    });

    test('filter by since excludes older entries', () {
      // Get timestamp of the third entry
      final entries = Log.instance.entries;
      final sinceMs = entries[2].timestamp.millisecondsSinceEpoch;
      final result = Log.instance.query(sinceMs: sinceMs);
      // Should only include entries *after* sinceMs
      expect(
        result.every((e) => e.timestamp.millisecondsSinceEpoch > sinceMs),
        isTrue,
      );
    });

    test('combined filters', () {
      final result = Log.instance.query(
        minLevel: LogLevel.warn,
        category: LogCat.waveform,
      );
      expect(result, hasLength(2));
      expect(
        result.every(
          (e) =>
              e.category == LogCat.waveform &&
              e.level.index >= LogLevel.warn.index,
        ),
        isTrue,
      );
    });

    test('limit with other filters', () {
      final result = Log.instance.query(minLevel: LogLevel.warn, limit: 1);
      expect(result, hasLength(1));
      expect(result.first.message, 'another bad wav');
    });
  });

  group('entries is unmodifiable', () {
    test('cannot modify returned list', () {
      Log.i(LogCat.app, 'test');
      expect(
        () => Log.instance.entries.add(
          LogEntry(
            timestamp: DateTime.now(),
            level: LogLevel.debug,
            category: 'x',
            message: 'y',
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('initFile', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('eclipsa_studio_log_test');
    });

    tearDown(() {
      Log.instance.closeFile();
      Log.tryLockForTesting = null;
      dir.deleteSync(recursive: true);
    });

    test('opens the named file and holds its lock', () async {
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      expect(Log.instance.logFilePath, p.join(dir.path, 'a.jsonl'));
      Log.i(LogCat.app, 'hello');
      Log.instance.flush();
      expect(
        File(p.join(dir.path, 'a.jsonl')).readAsStringSync(),
        contains('hello'),
      );
    });

    test('truncates the file left by the previous launch', () {
      File(p.join(dir.path, 'a.jsonl')).writeAsStringSync('stale\n');
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      Log.i(LogCat.app, 'fresh');
      Log.instance.flush();
      final text = File(p.join(dir.path, 'a.jsonl')).readAsStringSync();
      expect(text, isNot(contains('stale')));
      expect(text, contains('fresh'));
    });

    // With an IOSink, a log call or a second flush made while a flush was
    // pending threw StateError and lost the record (ES-848). On quit the
    // pop-out's window close and its quit teardown can both flush.
    test('log calls between repeated flushes all reach the file', () {
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      for (var i = 0; i < 50; i++) {
        Log.i(LogCat.app, 'line $i');
        Log.instance.flush();
        Log.d(LogCat.app, 'after $i');
        Log.instance
          ..flush()
          ..flush();
      }
      final lines = File(
        p.join(dir.path, 'a.jsonl'),
      ).readAsLinesSync().map((l) => LogEntry.fromJson(json.decode(l)));
      expect(lines.map((e) => e.message), [
        for (var i = 0; i < 50; i++) ...['line $i', 'after $i'],
      ]);
    });

    // A line logged just before a native crash must already be on disk.
    test('warn and error lines are written at once', () {
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      final file = File(p.join(dir.path, 'a.jsonl'));
      Log.i(LogCat.app, 'info waits');
      expect(file.readAsStringSync(), isEmpty);
      Log.w(LogCat.app, 'warn now');
      expect(file.readAsStringSync(), contains('warn now'));
      Log.e(LogCat.app, 'error now');
      expect(file.readAsStringSync(), contains('error now'));
    });

    test(
      'pending lines are written after writeDelay without a flush',
      () async {
        Log.instance.initFile(dir.path, fileName: 'a.jsonl');
        Log.i(LogCat.app, 'timed');
        await Future<void>.delayed(Log.writeDelay * 2);
        expect(
          File(p.join(dir.path, 'a.jsonl')).readAsStringSync(),
          contains('timed'),
        );
      },
    );

    test('pending lines are written once they pass writeThreshold', () {
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      final file = File(p.join(dir.path, 'a.jsonl'));
      final big = 'x' * 1024;
      final count = Log.writeThreshold ~/ big.length + 1;
      for (var i = 0; i < count; i++) {
        Log.d(LogCat.app, big);
      }
      // Written without a flush or the timer.
      final written = file.readAsLinesSync().length;
      expect(written, inInclusiveRange(1, count));
      Log.instance.flush();
      expect(file.readAsLinesSync().length, count);
    });

    test('concurrent exports complete and hold every line', () async {
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      Log.i(LogCat.app, 'before export');
      final outs = [for (var i = 0; i < 3; i++) p.join(dir.path, 'out$i')];
      final results = Future.wait([
        for (final out in outs) Log.exportToFile(out),
      ]);
      Log.i(LogCat.app, 'during export');
      expect(await results, [true, true, true]);
      for (final out in outs) {
        expect(File(out).readAsStringSync(), contains('before export'));
      }
      Log.instance.flush();
      expect(
        File(p.join(dir.path, 'a.jsonl')).readAsStringSync(),
        contains('during export'),
      );
    });

    // File.openWrite() opened the file asynchronously, so an open failure
    // escaped the try in initFile and left a sink whose flush never
    // completed and whose later writes threw (ES-848).
    test('an unopenable log file falls back to the ring buffer', () async {
      // A directory at the log path: the lock sidecar opens, the log
      // file does not.
      Directory(p.join(dir.path, 'a.jsonl')).createSync();
      late RandomAccessFile lock;
      Log.tryLockForTesting = (path) =>
          lock = File('$path.lock').openSync(mode: FileMode.append);
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      expect(Log.instance.entries.last.message, 'file logging disabled');
      expect(Log.instance.entries.last.level, LogLevel.error);
      Log.i(LogCat.app, 'still logging');
      Log.instance.flush();
      expect(Log.instance.entries.last.message, 'still logging');
      expect(await Log.exportToFile(p.join(dir.path, 'out')), isFalse);
      // The lock handle is closed with the failed open: a closed
      // RandomAccessFile throws on use.
      expect(lock.positionSync, throwsA(isA<FileSystemException>()));
    });

    // Two processes writing one path through independent buffered sinks
    // land their bytes at unrelated offsets and tear each other's
    // records (ES-661). The second instance takes a name of its own.
    test('logs to a per-process file when another instance holds the '
        'named one', () async {
      final primary = p.join(dir.path, 'a.jsonl');
      Log.tryLockForTesting = (path) =>
          path == primary ? null : File(path).openSync(mode: FileMode.append);
      Log.instance.initFile(dir.path, fileName: 'a.jsonl');
      expect(Log.instance.logFilePath, p.join(dir.path, 'a-$pid.jsonl'));
      expect(
        Log.instance.entries.last.message,
        'another instance holds $primary; logging to '
        '${p.join(dir.path, 'a-$pid.jsonl')}',
      );
      expect(Log.instance.entries.last.level, LogLevel.warn);
      Log.instance.flush();
      expect(File(primary).existsSync(), isFalse, reason: 'untouched');
      expect(File(p.join(dir.path, 'a-$pid.jsonl')).existsSync(), isTrue);
    });
  });
}
