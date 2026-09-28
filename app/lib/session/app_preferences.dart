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

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logging/log.dart';

/// Simple JSON-based app preferences stored in the app support directory.
class AppPreferences {
  static const _fileName = 'preferences.json';

  // Keys
  static const kReopenLastProject = 'reopen_last_project';
  static const kAudioDeviceName = 'audio_device_name';
  static const kAudioBufferSize = 'audio_buffer_size';
  // Output device selection mode (ES-467): true = follow the OS default
  // output device (switching live when the OS default changes); false =
  // stay pinned to kAudioDeviceName. The pinned name is kept on disk
  // while following, so toggling back restores the last explicit pick.
  static const kAudioFollowSystemDefault = 'audio_follow_system_default';
  static const kThemeMode = 'theme_mode';
  static const kFontSizeMode = 'font_size_mode';
  static const kVideoBackend = 'video_backend';
  static const kTimeDisplay = 'time_display';
  static const kPlayheadFollow = 'playhead_follow';
  static const kReturnOnStop = 'return_on_stop';

  // Window geometry (persisted across launches).
  static const kWindowX = 'window_x';
  static const kWindowY = 'window_y';
  static const kWindowW = 'window_w';
  static const kWindowH = 'window_h';
  static const kWindowFullScreen = 'window_fullscreen';

  // Import
  // Where source *audio* was last picked from (WAV import, ADM master).
  static const kLastImportDir = 'last_import_dir';
  // Where source *video* was last picked from. Separate from
  // kLastImportDir: in a post workflow picture and audio stems live in
  // different trees, so one recent path sends each picker to the other's
  // folder.
  static const kLastVideoImportDir = 'last_video_import_dir';
  // Where an ADM import last wrote its session *to* (the folder holding the
  // .esp and the rendered bed WAV). Kept apart from kLastImportDir: masters
  // are read from a delivery/library folder and land in a projects folder,
  // so one recent path cannot serve both ends.
  static const kLastAdmDestDir = 'last_adm_dest_dir';

  // Export
  // Where deliverables (IAMF / MP4) were last written.
  static const kLastExportDir = 'last_export_dir';
  // Where the diagnostic log was last exported. Its own key so a support
  // dump never redirects the deliverable picker (or vice versa).
  static const kLastLogExportDir = 'last_log_export_dir';
  // What's New dialog — version the user has already seen the
  // What's New dialog for. Show the dialog when the running
  // version differs.
  static const kLastSeenVersion = 'last_seen_version';
  // Safety notice (ES-634): the safety warning shown at launch. The first
  // acceptance's local time and build, and the notice revision the user
  // chose not to see again (null: show it).
  static const kSafetyNoticeAcceptedAt = 'safety_notice_accepted_at';
  static const kSafetyNoticeAcceptedBuild = 'safety_notice_accepted_build';
  static const kSafetyNoticeSuppressedRevision =
      'safety_notice_suppressed_revision';

  // Renderer
  static const kColormap = 'colormap';

  // Monitoring
  // Per-device monitoring blob: device name -> encoded config + labels.
  static const kMonitoringByDevice = 'monitoring_by_device';

  static const _audioKeys = {
    kAudioDeviceName,
    kAudioBufferSize,
    kAudioFollowSystemDefault,
  };

  /// Reset all preferences except audio device settings.
  static Future<void> reset() {
    return _enqueueWrite(() async {
      try {
        final prefs = await load();
        final audioOnly = Map<String, dynamic>.fromEntries(
          prefs.entries.where((e) => _audioKeys.contains(e.key)),
        );
        await _persist(audioOnly);
        Log.i(LogCat.session, 'Preferences reset (audio device kept)');
      } on IOException catch (e) {
        Log.e(LogCat.session, 'Failed to reset preferences', e);
      }
    });
  }

  // Defaults
  static const _defaults = <String, dynamic>{
    kReopenLastProject: false,
    kReturnOnStop: true,
  };

  AppPreferences._();

  /// Load all preferences from disk, merged with defaults.
  static Future<Map<String, dynamic>> load() async {
    final defaults = Map<String, dynamic>.from(_defaults);
    try {
      final file = await _file();
      if (!await file.exists()) return defaults;
      final content = await file.readAsString();
      final stored = json.decode(content) as Map<String, dynamic>;
      defaults.addAll(stored);
      return defaults;
    } on IOException catch (e) {
      Log.w(LogCat.session, 'Failed to load preferences', e);
      return defaults;
    } on FormatException catch (e) {
      Log.e(LogCat.session, 'Preferences file corrupted, using defaults', e);
      return defaults;
    }
  }

  /// Serialises every load→merge→write below. Two saves firing in the
  /// same microtask batch (e.g. theme + font size from one Settings
  /// interaction) would otherwise both load the same stale map, and the
  /// later write would silently drop the earlier one's keys. Callers
  /// composing their own read-modify-write on top of load()/setAll()
  /// (see monitoring_store.dart) still need their own chain — this only
  /// makes each setAll observe the previous one.
  static Future<void> _writeChain = Future<void>.value();

  static Future<void> _enqueueWrite(Future<void> Function() write) {
    final next = _writeChain.then((_) => write());
    // Keep the chain alive after a failure so one bad save can't wedge
    // all later ones; the caller still sees the error via `next`.
    _writeChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Set a single preference key and persist to disk.
  static Future<void> set(String key, dynamic value) async {
    await setAll({key: value});
  }

  /// Set multiple preference keys atomically and persist to disk.
  /// Writes are serialized process-wide, so concurrent calls merge
  /// instead of clobbering each other.
  static Future<void> setAll(Map<String, dynamic> entries) {
    return _enqueueWrite(() async {
      try {
        final prefs = await load();
        prefs.addAll(entries);
        await _persist(prefs);
      } on IOException catch (e) {
        Log.e(LogCat.session, 'Failed to save preferences', e);
      }
    });
  }

  /// Atomically replace the preferences file: write to a temp file in
  /// the same directory, flush, then rename over the target. Rename is
  /// atomic on APFS and NTFS, so a concurrent load() (or an external
  /// reader) sees either the old or the new complete file — never a
  /// torn write that would silently fall back to defaults (ES-420).
  static Future<void> _persist(Map<String, dynamic> prefs) async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json.encode(prefs), flush: true);
    await tmp.rename(file.path);
  }

  static String? _cachedPath;

  static Future<String> get path async {
    final file = await _file();
    return file.path;
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _fileName);
    if (_cachedPath == null) {
      _cachedPath = path;
      Log.d(LogCat.session, 'Preferences path: $path');
    }
    return File(path);
  }
}
