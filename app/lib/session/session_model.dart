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

import 'package:path/path.dart' as p;

import '../logging/log.dart';
import '../models/audio_element_enums.dart';
import '../state.dart';

/// Serializable snapshot of the entire session state.
///
/// Persisted as JSON with the `.esp` file extension.
class SessionModel {
  /// Schema version written to every session file.
  ///
  /// 0.28.0, the first public release, writes and reads version 3 only.
  /// Versions 1 and 2 were written by pre-release builds and are
  /// rejected; a version above 3 is rejected as newer than this build.
  static const int schemaVersion = 3;

  final int sampleRate;
  final List<AudioElement> elements;
  final List<Mix> mixes;

  /// Path of the media attached to the video pane: a video file or a
  /// still image. Written and read as `mediaPath`.
  final String? mediaPath;

  final IamfProfile iamfProfile;

  /// Visualizer module state, keyed by module id. Each entry carries
  /// `{"enabled": bool, ...paramValues}`. Null / missing entries fall
  /// back to each module's declared defaults at load time.
  final Map<String, dynamic>? vizState;

  const SessionModel({
    this.sampleRate = 48000,
    this.elements = const [],
    this.mixes = const [],
    this.mediaPath,
    this.iamfProfile = IamfProfile.baseEnhanced,
    this.vizState,
  });

  /// Default empty session.
  factory SessionModel.empty() => const SessionModel();

  // --- JSON serialization ---

  /// Serialize to a JSON map.
  ///
  /// When [relativeTo] is provided (the session file's parent directory),
  /// all file paths (wavPath, mediaPath) are stored relative to it.
  Map<String, dynamic> toJson({String? relativeTo}) => {
    'version': schemaVersion,
    'sampleRate': sampleRate,
    'iamfProfile': iamfProfile.jsonId,
    'elements': elements
        .map((e) => _elementToJson(e, relativeTo: relativeTo))
        .toList(),
    'mixes': mixes.map(_mixToJson).toList(),
    if (mediaPath != null) 'mediaPath': _toRelative(mediaPath!, relativeTo),
    if (vizState != null) 'vizState': vizState,
  };

  /// Deserialize from a JSON map.
  ///
  /// When [resolveFrom] is provided (the session file's parent directory),
  /// relative file paths are resolved to absolute. Absolute paths are
  /// left unchanged.
  factory SessionModel.fromJson(
    Map<String, dynamic> json, {
    String? resolveFrom,
  }) {
    final version = json['version'] as int? ?? 1;
    if (version > schemaVersion) {
      throw FormatException(
        'Session file version $version is newer than supported '
        '($schemaVersion). Please update Eclipsa Studio.',
      );
    }
    if (version < schemaVersion) {
      throw FormatException(
        'Session file version $version was written by a pre-release '
        'build and is not supported (this build reads version '
        '$schemaVersion).',
      );
    }

    // A missing profile falls back silently; an *unknown* string logs
    // at debug level so hand-authored session bugs are findable (ES-490).
    final profileId = json['iamfProfile'] as String?;
    final iamfProfile = IamfProfile.fromJsonId(profileId);
    if (profileId != null && iamfProfile.jsonId != profileId) {
      Log.d(
        LogCat.session,
        'Unknown iamfProfile "$profileId" in session file; '
        'using "${iamfProfile.jsonId}"',
      );
    }

    return SessionModel(
      sampleRate: json['sampleRate'] as int? ?? 48000,
      iamfProfile: iamfProfile,
      elements:
          (json['elements'] as List<dynamic>?)
              ?.map(
                (e) => _elementFromJson(
                  e as Map<String, dynamic>,
                  resolveFrom: resolveFrom,
                ),
              )
              .toList() ??
          [],
      mixes:
          (json['mixes'] as List<dynamic>?)
              ?.map((e) => _mixFromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      mediaPath: _toAbsolute(json['mediaPath'] as String?, resolveFrom),
      vizState: (json['vizState'] as Map<String, dynamic>?),
    );
  }

  /// Encode to a pretty-printed JSON string.
  ///
  /// When [relativeTo] is the session file's parent directory, paths
  /// are stored relative to it.
  String encode({String? relativeTo}) => const JsonEncoder.withIndent(
    '  ',
  ).convert(toJson(relativeTo: relativeTo));

  /// Decode from a JSON string.
  ///
  /// When [resolveFrom] is the session file's parent directory, relative
  /// paths are resolved to absolute.
  factory SessionModel.decode(String source, {String? resolveFrom}) =>
      SessionModel.fromJson(
        json.decode(source) as Map<String, dynamic>,
        resolveFrom: resolveFrom,
      );

  // --- Element serialization ---

  static Map<String, dynamic> _elementToJson(
    AudioElement e, {
    String? relativeTo,
  }) => {
    'id': e.id,
    'name': e.name,
    'type': e.type,
    'layout': e.layout,
    'codec': e.codec,
    'color': e.color,
    'gain': e.gain,
    // Monitoring state only: persisted so a reopened session sounds the
    // way it was left, never read by the export path (ES-284).
    'mute': e.mute,
    'solo': e.solo,
    if (e.wavPath != null) 'wavPath': _toRelative(e.wavPath!, relativeTo),
    'binauralProfile': e.binauralProfile.displayName,
    'binauralMode': e.binauralMode.displayName,
    'azimuth': e.azimuth,
    'elevation': e.elevation,
    'distance': e.distance,
    'isDual': e.isDual,
    'spread': e.spread,
    'ambisonicsOrder': e.ambisonicsOrder,
    if (e.inputRouting != null) 'inputRouting': e.inputRouting,
    if (e.timeOffsetMs != 0) 'timeOffsetMs': e.timeOffsetMs,
  };

  static AudioElement _elementFromJson(
    Map<String, dynamic> j, {
    String? resolveFrom,
  }) {
    final id =
        j['id'] as int? ??
        (throw const FormatException('element missing "id"'));
    final name =
        j['name'] as String? ??
        (throw const FormatException('element missing "name"'));
    final type =
        j['type'] as String? ??
        (throw const FormatException('element missing "type"'));
    if (type != 'Channel' && type != 'Scene' && type != 'Object') {
      // Kept as-is (downstream treats unknown types as channel-like),
      // but findable in the log (ES-490).
      Log.d(
        LogCat.session,
        'Unknown element type "$type" in session file (element $id)',
      );
    }
    final layout = j['layout'] as String? ?? '';
    final codec = j['codec'] as String? ?? '';
    final color = j['color'] as int? ?? 0xFF888888;

    return AudioElement(
      id: id,
      name: name,
      type: type,
      layout: layout,
      codec: codec,
      color: color,
      gain: (j['gain'] as num?)?.toDouble() ?? 0,
      mute: j['mute'] as bool? ?? false,
      solo: j['solo'] as bool? ?? false,
      wavPath: _toAbsolute(j['wavPath'] as String?, resolveFrom),
      binauralProfile: j['binauralProfile'] is String
          ? BinauralProfile.fromString(j['binauralProfile'] as String)
          : BinauralProfile.ambient,
      binauralMode: j['binauralMode'] is String
          ? BinauralMode.fromString(j['binauralMode'] as String)
          : BinauralMode.worldLocked,
      azimuth: (j['azimuth'] as num?)?.toDouble() ?? 0.0,
      elevation: (j['elevation'] as num?)?.toDouble() ?? 0.0,
      distance: (j['distance'] as num?)?.toDouble() ?? 1.0,
      isDual: j['isDual'] as bool? ?? false,
      spread: (j['spread'] as num?)?.toDouble() ?? 60.0,
      ambisonicsOrder: j['ambisonicsOrder'] as int? ?? 1,
      inputRouting: (j['inputRouting'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList(),
      timeOffsetMs: (j['timeOffsetMs'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Resolve an enum by `.name`, falling back to [fallback]. A missing
  /// key (null) falls back silently, but an unknown *string* logs at
  /// debug level so hand-authored session bugs are findable in the log
  /// instead of vanishing into a default (ES-490).
  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? raw,
    T fallback,
    String field,
  ) {
    if (raw is String) {
      for (final v in values) {
        if (v.name == raw) return v;
      }
      Log.d(
        LogCat.session,
        'Unknown $field "$raw" in session file; using "${fallback.name}"',
      );
    }
    return fallback;
  }

  // --- Path helpers ---

  /// Convert an absolute path to relative if [sessionDir] is provided.
  ///
  /// Always emits POSIX (`/`) separators so a `.esp` saved on Windows
  /// still resolves on macOS/Linux and vice versa; `_toAbsolute`'s
  /// `p.join` accepts `/` on every platform.
  static String _toRelative(String absPath, String? sessionDir) {
    if (sessionDir == null) return absPath;
    return p.split(p.relative(absPath, from: sessionDir)).join('/');
  }

  /// Resolve a path to absolute if [sessionDir] is provided.
  /// Leaves absolute paths unchanged.
  static String? _toAbsolute(String? path, String? sessionDir) {
    if (path == null) return null;
    if (sessionDir == null || p.isAbsolute(path)) return path;
    return p.normalize(p.join(sessionDir, path));
  }

  // --- Mix serialization ---

  static Map<String, dynamic> _subMixToJson(SubMix sm) => {
    'label': sm.label,
    'outputMixGain': sm.outputMixGain,
    'elementSettings': sm.elementSettings
        .map(
          (s) => {
            'elementId': s.elementId,
            'included': s.included,
            'mixGain': s.mixGain,
            'headphonesMode': s.headphonesMode.name,
            'binauralProfile': s.binauralProfile.name,
          },
        )
        .toList(),
    'layouts': sm.layouts
        .map(
          (l) => {
            'soundSystem': l.soundSystem.name,
            'integratedLoudness': l.loudness.integratedLoudness,
            'digitalPeak': l.loudness.digitalPeak,
            'truePeak': l.loudness.truePeak,
          },
        )
        .toList(),
  };

  static SubMix _subMixFromJson(Map<String, dynamic> j) {
    return SubMix(
      label: j['label'] as String? ?? 'Main',
      outputMixGain: (j['outputMixGain'] as num?)?.toDouble() ?? 0,
      elementSettings:
          (j['elementSettings'] as List<dynamic>?)
              ?.map(
                (s) => MixElementSettings(
                  elementId: s['elementId'] as int,
                  included: s['included'] as bool? ?? true,
                  mixGain: (s['mixGain'] as num?)?.toDouble() ?? 0,
                  // v1 sessions pre-date the headphonesMode field —
                  // fall back to stereo (mode 0) so loading an old
                  // project doesn't silently rewrite every element to
                  // world-locked binaural on save. New elements get
                  // the binauralWorldLocked UI default from the
                  // MixElementSettings constructor.
                  headphonesMode: _enumByName(
                    HeadphonesRenderingMode.values,
                    s['headphonesMode'],
                    HeadphonesRenderingMode.stereo,
                    'headphonesMode',
                  ),
                  binauralProfile: _enumByName(
                    BinauralProfile.values,
                    s['binauralProfile'],
                    BinauralProfile.ambient,
                    'binauralProfile',
                  ),
                ),
              )
              .toList() ??
          [],
      layouts:
          (j['layouts'] as List<dynamic>?)
              ?.map(
                (l) => MixLayout(
                  soundSystem: _enumByName(
                    SoundSystem.values,
                    l['soundSystem'],
                    SoundSystem.stereo,
                    'soundSystem',
                  ),
                  loudness: LoudnessInfo(
                    integratedLoudness:
                        (l['integratedLoudness'] as num?)?.toDouble() ?? 0,
                    digitalPeak: (l['digitalPeak'] as num?)?.toDouble() ?? 0,
                    truePeak: (l['truePeak'] as num?)?.toDouble(),
                  ),
                ),
              )
              .toList() ??
          const [MixLayout(soundSystem: SoundSystem.stereo)],
    );
  }

  static Map<String, dynamic> _mixToJson(Mix m) => {
    'id': m.id,
    'name': m.name,
    'language': m.language,
    'subMixes': m.subMixes.map(_subMixToJson).toList(),
  };

  static Mix _mixFromJson(Map<String, dynamic> j) {
    final id =
        j['id'] as int? ?? (throw const FormatException('mix missing "id"'));
    final name =
        j['name'] as String? ??
        (throw const FormatException('mix missing "name"'));

    return Mix(
      id: id,
      name: name,
      language: j['language'] as String? ?? 'en',
      subMixes: (j['subMixes'] as List<dynamic>)
          .map((s) => _subMixFromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
