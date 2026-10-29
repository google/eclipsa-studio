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

/// The app's launch parameters: which file to open at startup, and the
/// smoke-test and help flags. Pure, so the parsing and the file-type
/// check are unit-testable; main.dart applies the result.
library;

import 'dart:convert' show latin1;

/// How a launch file is to be opened.
enum LaunchOpenKind {
  /// `--open`: read the type from the file (see [classifyLaunchFile]).
  auto,

  /// A session, opened in Creator.
  session,

  /// A `.iamf` file or an MP4 with an IAMF track, opened in Playback.
  playback,
}

/// The parsed launch parameters.
class LaunchArgs {
  const LaunchArgs({
    this.openPath,
    this.openKind = LaunchOpenKind.auto,
    this.openSource,
    this.quitAfterLoad = false,
    this.help = false,
    this.unknown = const [],
    this.notes = const [],
  });

  /// The file to open at startup, or null.
  final String? openPath;
  final LaunchOpenKind openKind;

  /// Where [openPath] came from, for the log: the option or the
  /// environment variable.
  final String? openSource;

  final bool quitAfterLoad;
  final bool help;

  /// Options in the app's own arguments that are not launch parameters.
  final List<String> unknown;

  /// Remarks for the log, such as an option that replaced an earlier one.
  final List<String> notes;
}

const _fileOptions = {
  '--open': LaunchOpenKind.auto,
  '--session': LaunchOpenKind.session,
  '--playback': LaunchOpenKind.playback,
  // Old name of --playback, kept for existing scripts.
  '--iamf': LaunchOpenKind.playback,
};

/// Environment variables read when no file option is given, in order of
/// precedence.
const _launchEnvironment = [
  ('ECLIPSA_STUDIO_OPEN', LaunchOpenKind.auto),
  ('ECLIPSA_STUDIO_IAMF', LaunchOpenKind.playback),
  ('ECLIPSA_STUDIO_SESSION', LaunchOpenKind.session),
];

/// The help text `--help` prints.
const launchHelp = '''
Usage: Eclipsa Studio [--open <file>] [--quit-after-load] [--help]

  --open <file>       Open a file at launch. A session opens in Creator; a
                      .iamf file or an MP4 with an IAMF track opens in
                      Playback. The type is read from the file's content.
  --session <file>    Open a session in Creator.
  --playback <file>   Open a .iamf file or an MP4 with an IAMF track in
                      Playback.
  --iamf <file>       Old name of --playback.
  --quit-after-load   Exit once the file is open: 0 when it opened, 1 when
                      it did not, 2 when no file was given or it does not
                      exist.
  --help, -h          Print this help and exit.

Each option also takes the form --open=<file>. When several file options
are given, the last one is used.

Environment, read when no file option is given: ECLIPSA_STUDIO_OPEN as
--open, ECLIPSA_STUDIO_IAMF as --playback, ECLIPSA_STUDIO_SESSION as
--session. ECLIPSA_STUDIO_QUIT_AFTER_LOAD=1 is read as --quit-after-load.
''';

/// Parses the launch parameters from [args] (main()'s arguments) and
/// [extraArgs] (the process's own arguments, which on some platforms
/// carry the same options), then falls back to [environment].
///
/// Only [args] is checked for unknown options: [extraArgs] also carries
/// the engine's and the platform's own flags.
LaunchArgs parseLaunchArgs(
  List<String> args, {
  List<String> extraArgs = const [],
  Map<String, String> environment = const {},
}) {
  String? path;
  var kind = LaunchOpenKind.auto;
  String? source;
  var quit = false;
  var help = false;
  final unknown = <String>[];
  final notes = <String>[];

  void take(String option, String value) {
    if (path != null && path != value) {
      notes.add('$option $value replaces $source $path');
    }
    path = value;
    kind = _fileOptions[option]!;
    source = option;
    if (option == '--iamf') notes.add('--iamf is an old name of --playback');
  }

  void scan(List<String> list, {required bool reportUnknown}) {
    for (var i = 0; i < list.length; i++) {
      final arg = list[i];
      final eq = arg.indexOf('=');
      final name = eq > 0 ? arg.substring(0, eq) : arg;
      if (_fileOptions.containsKey(name)) {
        final value = eq > 0
            ? arg.substring(eq + 1)
            // The next argument, unless it is another option.
            : (i + 1 < list.length && !list[i + 1].startsWith('-')
                  ? list[++i]
                  : '');
        if (value.isEmpty) {
          notes.add('$name needs a file and was ignored');
        } else {
          take(name, value);
        }
      } else if (arg == '--quit-after-load') {
        quit = true;
      } else if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (reportUnknown && arg.startsWith('-')) {
        unknown.add(arg);
      }
    }
  }

  scan(args, reportUnknown: true);
  scan(extraArgs, reportUnknown: false);

  if (path == null) {
    for (final (name, envKind) in _launchEnvironment) {
      final value = environment[name];
      if (value != null && value.isNotEmpty) {
        path = value;
        kind = envKind;
        source = name;
        break;
      }
    }
  }
  if (environment['ECLIPSA_STUDIO_QUIT_AFTER_LOAD'] == '1') quit = true;

  return LaunchArgs(
    openPath: path,
    openKind: kind,
    openSource: source,
    quitAfterLoad: quit,
    help: help,
    unknown: unknown,
    notes: notes,
  );
}

/// The number of leading bytes [classifyLaunchFile] reads.
const launchSniffBytes = 32;

/// The kind of file at [path], from its first bytes [head]: an MP4
/// (`ftyp` box at offset 4) or a raw IA sequence (an IA sequence header
/// OBU, type 31, followed by `iamf`) is a Playback file; a JSON object
/// is a session. Without [head] (the file could not be read, as in the
/// app's sandbox) or when its bytes match none of these, the extension
/// decides: `.esp` is a session, `.iamf` and `.mp4` are Playback files.
/// Returns null when neither decides.
LaunchOpenKind? classifyLaunchFile(String path, List<int>? head) {
  if (head != null && head.isNotEmpty) {
    // One char per byte, so offsets and ASCII tags match the bytes.
    final text = latin1.decode(head);
    if (text.length >= 8 && text.substring(4, 8) == 'ftyp') {
      return LaunchOpenKind.playback;
    }
    if ((head[0] >> 3) == 31 && text.contains('iamf')) {
      return LaunchOpenKind.playback;
    }
    var i = 0;
    // A UTF-8 byte-order mark, then whitespace.
    if (head.length >= 3 &&
        head[0] == 0xEF &&
        head[1] == 0xBB &&
        head[2] == 0xBF) {
      i = 3;
    }
    while (i < head.length && _isJsonSpace(head[i])) {
      i++;
    }
    if (i < head.length && head[i] == 0x7B) return LaunchOpenKind.session;
  }
  final lower = path.toLowerCase();
  if (lower.endsWith('.esp')) return LaunchOpenKind.session;
  if (lower.endsWith('.iamf') || lower.endsWith('.mp4')) {
    return LaunchOpenKind.playback;
  }
  return null;
}

bool _isJsonSpace(int b) => b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D;

/// How the launch file was resolved.
enum LaunchFileStatus {
  /// No file was named: no file option, environment variable or
  /// `startup_session.txt`.
  none,

  /// A session to load in Creator.
  session,

  /// A `.iamf` file or an MP4 with an IAMF track to open in Playback.
  playback,

  /// A file was named but does not exist.
  missing,

  /// `--open` named a file that is neither a session nor a Playback file.
  unclassified,
}

/// The launch file, resolved by [resolveLaunchFile].
class LaunchFile {
  const LaunchFile(this.status, {this.path, this.source});

  final LaunchFileStatus status;
  final String? path;

  /// The option, the environment variable, or `startup_session.txt`.
  final String? source;

  /// Whether the startup may reopen the last project instead: only when
  /// no file was named, so a named file, even a missing one, is never
  /// replaced by the last project.
  bool get allowReopenLastProject => status == LaunchFileStatus.none;
}

/// Whether the startup may reopen the last project for [launch], whose
/// file resolved to [file]: only when no file was named and
/// `--quit-after-load` is off. With `--quit-after-load` and no file the
/// app exits 2, as `--help` states, instead of loading the last project.
bool mayReopenLastProject(LaunchArgs launch, LaunchFile file) =>
    file.allowReopenLastProject && !launch.quitAfterLoad;

/// Resolves the file [launch] names. [exists] and [readHead] reach the
/// file system ([readHead] returns the first [launchSniffBytes] bytes, or
/// null when the file cannot be read). [takeStartupSession] returns the
/// path in `startup_session.txt` and deletes that file, or null when it
/// is absent; it is called only when no option or variable names a file.
LaunchFile resolveLaunchFile(
  LaunchArgs launch, {
  required bool Function(String path) exists,
  required List<int>? Function(String path) readHead,
  String? Function()? takeStartupSession,
}) {
  var path = launch.openPath;
  var source = launch.openSource;
  var kind = launch.openKind;
  if (path == null) {
    final startup = takeStartupSession?.call();
    if (startup == null || startup.isEmpty) {
      return const LaunchFile(LaunchFileStatus.none);
    }
    path = startup;
    source = 'startup_session.txt';
    kind = LaunchOpenKind.session;
  }
  if (!exists(path)) {
    return LaunchFile(LaunchFileStatus.missing, path: path, source: source);
  }
  if (kind == LaunchOpenKind.auto) {
    kind = classifyLaunchFile(path, readHead(path)) ?? LaunchOpenKind.auto;
  }
  return LaunchFile(
    switch (kind) {
      LaunchOpenKind.session => LaunchFileStatus.session,
      LaunchOpenKind.playback => LaunchFileStatus.playback,
      LaunchOpenKind.auto => LaunchFileStatus.unclassified,
    },
    path: path,
    source: source,
  );
}
