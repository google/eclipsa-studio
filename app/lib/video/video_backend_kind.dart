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

import 'dart:io' show Platform;

/// The desktop operating systems Eclipsa Studio targets. Kept separate from
/// `dart:io`'s `Platform` so the backend-selection logic below is pure and
/// unit-testable without a real platform.
enum TargetOs { macos, windows }

/// The OS this process is running on.
///
/// Eclipsa Studio ships on macOS and Windows only; anything else (there is
/// no Linux build) is treated as macOS, which selects the always-available
/// cross-platform default.
TargetOs currentTargetOs() =>
    Platform.isWindows ? TargetOs.windows : TargetOs.macos;

/// Identifies a video playback backend (issue ES-249).
///
/// All backends are pull-based today: the platform-native defaults
/// (AVFoundation on macOS, Media Foundation on Windows) plus the
/// cross-platform FFmpeg-in-engine path. The free-running players evaluated
/// under this seam (media_kit/libmpv, fvp/libmdk) were retired.
///
/// ## Adding a backend
/// Add the dependency, implement `VideoBackend`, add an enum arm here (the
/// [VideoBackendKindMeta] switches are exhaustive, so the compiler enumerates
/// every arm you must fill in), wire it in `video_backend_factory.dart`, and —
/// for a *native* (non-pub-plugin) backend only — register its platform
/// controller under `app/macos/Runner/` (AVFoundation, FFmpeg) or
/// `app/windows/runner/` (Media Foundation, FFmpeg).
///
/// ## Removing a backend
/// Compiler-guided: delete the arm and let the exhaustive switches drive the
/// change. The compiler does not enforce the remaining steps: the pub
/// dependency, the factory case, the tests and preference degradation.
enum VideoBackendKind {
  /// Resolve to the per-platform recommended backend at load time.
  auto,

  /// macOS-native AVFoundation (the macOS default — ES-249 step 3).
  avFoundation,

  /// FFmpeg decode in the C++ engine, pulled over the eclipsa_studio_video_*
  /// FFI and rendered as a Flutter texture (D3D11VA/DXGI on Windows,
  /// VideoToolbox/ CVPixelBuffer on macOS) with a software-image fallback.
  /// Cross-platform: the vendored LGPL FFmpeg ships on both macOS and Windows —
  /// selectable, ES-249 step 5.
  ffmpegEngine,

  /// Native Windows Media Foundation (IMFSourceReader + D3D11) — the Windows
  /// default and the counterpart of [avFoundation] on macOS. Pull-based,
  /// zero-copy DXGI texture (ES-262).
  mediaFoundation,

  /// A user-supplied still image shown statically in the video slot (ES-192).
  /// Chosen by file type at load time — never by the user, so it is hidden
  /// from the settings selector and rejected as a preference value
  /// ([VideoBackendKindMeta.userSelectable]).
  stillImage,
}

/// The fallback-of-last-resort every other backend degrades to when it can't
/// run: an unsupported or stale selection ([resolveBackendKind]), a backend
/// whose native constructor throws (`video_provider.dart`), and the pop-out
/// window's construction/open failures (`video_popout_app.dart`).
/// FFmpeg-in-engine is the one backend guaranteed to construct on *both*
/// platforms: it is pure Dart + FFI against the engine library the app cannot
/// run without, with no per-window native controller to be missing.
///
/// This constant is the single point every fallback site routes through, so
/// repointing it (as when media_kit handed the role to FFmpeg-in-engine) is a
/// one-line change here rather than a six-site grep-and-replace. Whatever it
/// names must stay implemented and cross-platform — asserted in
/// `test/video/video_backend_kind_test.dart`.
const VideoBackendKind kHardFallbackBackend = VideoBackendKind.ffmpegEngine;

extension VideoBackendKindMeta on VideoBackendKind {
  /// Short label for the settings selector.
  // Labels name the underlying decode technology (not the Flutter wrapper),
  // so they read cleanly in the settings selector and line up with the
  // planned backends below.
  String get label => switch (this) {
    VideoBackendKind.auto => 'Auto',
    VideoBackendKind.avFoundation => 'AVFoundation',
    VideoBackendKind.ffmpegEngine => 'FFmpeg',
    VideoBackendKind.mediaFoundation => 'Media Foundation',
    VideoBackendKind.stillImage => 'Still Image',
  };

  /// Whether the user can pick this kind (settings selector, persisted
  /// preference). [VideoBackendKind.stillImage] is selected by file type in
  /// `VideoNotifier.loadFile`, never by the user.
  bool get userSelectable => this != VideoBackendKind.stillImage;

  /// Whether a working implementation ships today. Unimplemented kinds are
  /// hidden from the selector and fall back to [kHardFallbackBackend] if ever
  /// selected (e.g. from a preferences file written by a newer build).
  ///
  /// All concrete kinds are implemented today. Only `auto` is a non-concrete
  /// alias that resolves via [resolveAuto].
  bool get implemented => switch (this) {
    VideoBackendKind.auto ||
    VideoBackendKind.avFoundation ||
    VideoBackendKind.ffmpegEngine ||
    VideoBackendKind.mediaFoundation ||
    VideoBackendKind.stillImage => true,
  };

  /// Operating systems this backend can run on. Cross-platform backends and
  /// `auto` list both; native / platform-vendored backends list only their OS.
  /// `ffmpegEngine` is cross-platform — the engine links the vendored LGPL
  /// FFmpeg on both macOS (build_ffmpeg.sh) and Windows (build_ffmpeg.ps1), so
  /// its FFI is in both engine builds. `avFoundation` is macOS-only and
  /// `mediaFoundation` Windows-only (each is that OS's native controller).
  Set<TargetOs> get supportedOs => switch (this) {
    VideoBackendKind.avFoundation => const {TargetOs.macos},
    VideoBackendKind.mediaFoundation => const {TargetOs.windows},
    VideoBackendKind.auto ||
    VideoBackendKind.ffmpegEngine ||
    VideoBackendKind.stillImage => const {TargetOs.macos, TargetOs.windows},
  };
}

/// The concrete backend that `auto` resolves to on [os].
///
/// macOS defaults to AVFoundation — the ES-248 winner (native VideoToolbox
/// decode, ProRes, frame-accurate, no drift loop), validated in ES-249 step 3.
/// Windows defaults to the native Media Foundation backend (IMFSourceReader +
/// D3D11, frame-accurate, no drift loop — ES-262), the Windows counterpart. This
/// is the single place the per-platform default lives.
VideoBackendKind resolveAuto(TargetOs os) => switch (os) {
  TargetOs.macos => VideoBackendKind.avFoundation,
  TargetOs.windows => VideoBackendKind.mediaFoundation,
};

/// Resolve a stored/selected kind to the concrete backend to instantiate on
/// [os]. Maps `auto`, and falls back to [kHardFallbackBackend] for any kind
/// that is unimplemented, unsupported on this platform (e.g. a stale
/// preference, or AVFoundation selected on Windows), or not user-selectable
/// in the first place (`stillImage` is only ever chosen by file type).
VideoBackendKind resolveBackendKind(VideoBackendKind selected, TargetOs os) {
  final concrete = selected == VideoBackendKind.auto
      ? resolveAuto(os)
      : selected;
  if (!concrete.implemented ||
      !concrete.supportedOs.contains(os) ||
      !concrete.userSelectable) {
    return kHardFallbackBackend;
  }
  return concrete;
}

/// Resolve a persisted backend-preference [name] to the kind to start with on
/// [os]. Accepts only a kind that is implemented and supported on this
/// platform; an unknown, unimplemented, or wrong-OS name (e.g. a stale
/// preference, or `avFoundation` carried to Windows) falls back to
/// [VideoBackendKind.auto].
///
/// Used to seed `videoBackendProvider` at startup so the first video backend
/// built is already the selected one — without it the provider starts on
/// `auto` and only swaps on the first load, needlessly spinning up a
/// throwaway player when a different backend is selected/default.
VideoBackendKind videoBackendFromName(String? name, TargetOs os) {
  if (name == null) return VideoBackendKind.auto;
  for (final k in VideoBackendKind.values) {
    if (k.name == name &&
        k.userSelectable &&
        k.implemented &&
        k.supportedOs.contains(os)) {
      return k;
    }
  }
  return VideoBackendKind.auto;
}

/// The backends a user can pick on [os] right now: `auto`, then the
/// platform default ([resolveAuto]) so it leads the selector, then FFmpeg
/// (where supported), then every other implemented backend that supports
/// [os]. Drives the settings selector — keeping the leading (default) option
/// in sync with `resolveAuto` means promoting a backend to default
/// automatically reorders it first; FFmpeg-in-engine sits second (the first
/// alternative) so it's prominent while the pull-based path is exercised. It
/// is available on both macOS and Windows now.
List<VideoBackendKind> availableBackendKinds(TargetOs os) {
  final preferred = resolveAuto(os);
  bool usable(VideoBackendKind k) =>
      k.userSelectable && k.implemented && k.supportedOs.contains(os);
  const ffmpeg = VideoBackendKind.ffmpegEngine;
  return [
    VideoBackendKind.auto,
    if (usable(preferred)) preferred,
    if (ffmpeg != preferred && usable(ffmpeg)) ffmpeg,
    for (final k in VideoBackendKind.values)
      if (k != VideoBackendKind.auto &&
          k != preferred &&
          k != ffmpeg &&
          usable(k))
        k,
  ];
}
