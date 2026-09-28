# Eclipsa Studio

Immersive audio authoring workstation for IAMF (Immersive Audio Model
and Formats) content creation. Flutter desktop UI with a native C++
real-time audio engine connected via `dart:ffi`.

![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue)
![Framework](https://img.shields.io/badge/framework-Flutter-02569B)
![Engine](https://img.shields.io/badge/engine-C%2B%2B20-00599C)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

## Features

- **Audio elements** — import WAV files as Object, Channel or Scene
  type elements with per-element gain.
- **ADM import** — convert ADM BWF masters into a session, with a
  conversion audit and warnings.
- **Multichannel waveform display** — stacked per-channel waveforms
  with zoom, scroll and playhead follow modes.
- **Video reference** — load MP4/MOV/MKV/AVI/WebM/M4V/MXF video, or a
  still image (PNG/JPEG/WebP/BMP/GIF), synced to the audio transport,
  with inline, fullscreen and pop-out windows (multi-monitor
  supported).
- **Mix presentations** — per-element mute/solo/gain with real-time
  multichannel level meters.
- **Routing matrix** — per-element input-channel routing.
- **Spatial renderer** — 3D speaker visualisation of the active
  monitoring layout.
- **OAR monitoring** — Open Audio Renderer with monitoring layouts
  from Stereo through 5.1, 5.1.2, 5.1.4, 7.1, 7.1.2, 7.1.4 and 9.1.6
  to Binaural (via HRTF), plus an always-on −1 dBFS peak limiter on
  the rendered output.
- **Loudness metering** — live ITU-R BS.1770-4 integrated,
  short-term, momentary loudness and true peak via
  `google/loudness_ebur128`.
- **Loudness Report** — offline measurement of every mix
  presentation × layout (View > Loudness Report…; Creator mode only
  for now).
- **Playback (QC) mode** — open an `.iamf` bitstream or IAMF-in-MP4
  file read-only for QC playback, alongside the WAV-based Creator
  mode.
- **Session management** — save/load `.esp` sessions with recent
  file history.
- **Transport** — play, pause, stop, seek, loop regions, playhead
  follow (off / step / continuous).
- **Themes & scaling** — four themes (Dark, the default; Light; Classic;
  High contrast), with Small/Medium/Large font scaling.
- **IAMF & MP4 export** — `File > Export…` streams each element
  through the export pipeline (gain → routing → resample → pad)
  straight into iamf-tools' push-PCM encoder (no temporary WAV files)
  to produce a standalone `.iamf` bitstream or an IAMF-in-MP4 `.mp4`
  muxed with the session video. Opus or PCM codec settings, profile
  picker, stream-fed EBU R128 loudness measurement, and live
  progress.

## Prerequisites

macOS is the primary target; Windows is supported via a parallel
build script. Linux is experimental.

### First-time setup on a clean macOS

1. **Xcode** — install from the Mac App Store (the full app, not only
   the Command Line Tools; `xcodebuild` is required for Flutter macOS
   builds). After installation:

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch     # installs CoreSimulator + others
   sudo xcodebuild -license accept
   ```

2. **Homebrew** (<https://brew.sh>) installs the remaining tools.

3. **Flutter** — `>=3.47.5` (see `environment.flutter` in
   `app/pubspec.yaml`):

   ```bash
   brew install --cask flutter
   ```

   The Homebrew cask can lag behind stable; if `flutter --version`
   reports something older, run `flutter upgrade`.

4. **Bazelisk** — builds the C++ engine. Use `bazelisk` (not raw
   `bazel`) so it honours `engine/.bazelversion`:

   ```bash
   brew install bazelisk
   ```

5. **CocoaPods** — Flutter macOS dependency. Typically already present;
   if not: `brew install cocoapods`.

6. **Optional: `llvm`** — for `clang-format` / `clang-tidy` linting:

   ```bash
   brew install llvm
   ```

Verify the installation:

```bash
flutter doctor          # should be all-green for the macOS toolchain
bazel --version         # bazelisk will fetch the pinned version on first run
```

### First-time setup on a clean Windows

1. **Visual Studio 2022** — install with the **"Desktop development with
   C++"** workload (which includes MSVC, the Windows SDK, and CMake).
   Required by both Bazel (for the engine DLL) and Flutter (for
   `flutter build windows`).

2. **Git for Windows** — <https://git-scm.com/download/win>. Bazel reads
   `BAZEL_SH` from the bundled `bash.exe` for some shell-style actions.

3. **Flutter** — <https://docs.flutter.dev/get-started/install/windows>.
   Add `flutter\bin` to `PATH`.

4. **Bazelisk** — pins to `engine/.bazelversion`:

   ```powershell
   choco install bazelisk        # or scoop install bazelisk
   ```

5. **Python 3** — used by `scripts/release_notes.py` to generate
   `app/assets/releases.json` (a bundled Flutter asset). Any 3.8+ from
   <https://python.org> or the Microsoft Store works.

Verify:

```powershell
flutter doctor          # all-green for the Windows toolchain
bazel --version
python --version
```

## Build & Run

Always use the top-level build script. A bare `flutter run` skips the
C++ engine build and waveform/audio features will not work.

**macOS** (`build.sh`):

```bash
./build.sh run                # build engine + run (release + lint)
./build.sh run debug          # ... debug mode (fastbuild engine, hot reload, no lint)
./build.sh run fresh          # ... + reset prefs and recents first
./build.sh test-session       # build engine + run with a session auto-loaded
./build.sh lint               # clang-format + clang-tidy + dart format
./build.sh lint --check       # verify formatting only (CI check, no writes)
./build.sh engine             # rebuild only the C++ engine dylib (optimized)
./build.sh gen-version        # stamp version.dart, engine_version.h + releases.json (no build)
./build.sh clean              # flutter clean + bazel clean + pub get
./build.sh package            # build + sign + notarize (DMG)
```

Add `--no-lint` to a release build to skip the lint/format pass
(clang-format, clang-tidy and `dart format`). Debug builds never lint.

**Windows** (`build.ps1`):

```powershell
.\build.ps1 run               # build engine + run (release + opt engine)
.\build.ps1 run debug         # ... debug mode (fastbuild engine, hot reload)
.\build.ps1 run fresh         # ... + reset prefs and recents first
.\build.ps1 test-session      # build + run with a .esp session auto-loaded
.\build.ps1 build             # build engine + flutter build (release, no run)
.\build.ps1 clean             # flutter clean + bazel clean + pub get
.\build.ps1 clean --deep      # ... + bazel expunge + wipe pub cache
.\build.ps1 engine            # rebuild only the C++ engine DLL
.\build.ps1 reset-prefs       # delete saved preferences and recents
.\build.ps1 lint              # dart format + clang-format/clang-tidy
.\build.ps1 lint --check      # verify formatting only (CI check, no writes)
.\build.ps1 package           # release build + portable zip in dist\
```

Windows `package` produces an unsigned portable
zip; a signed installer is tracked in
ES-279.

Packaged release builds (`./build.sh package`) require a Developer ID
Application certificate in the login keychain, with `DEVELOPER_ID_APP` set
to its identity, and a stored notarisation profile (the setup steps are in
the comment header of `build.sh`).

### Running with a test session

`./build.sh test-session` is `./build.sh run` plus a `.esp` session file
opened automatically on launch. Use it when iterating on a feature that
needs media loaded; it skips the manual File > Open step on every run.
The session path comes from the first argument, falling back to the
`ECLIPSA_STUDIO_TEST_SESSION` environment variable:

```bash
./build.sh test-session /path/to/demo.esp
# or set a default once in the shell rc:
export ECLIPSA_STUDIO_TEST_SESSION="$HOME/eclipsa-test-media/demo.esp"
./build.sh test-session
```

Test media (WAV/MP4 files and `.esp` sessions) lives **outside** the
repo and is never committed.

### C++ engine tests

```bash
cd engine
bazel test //...                          # all tests
bazel test //test:loudness_meter_test     # single target
bazel test //... --config=tsan            # ThreadSanitizer
bazel test //... --config=asan            # AddressSanitizer
```

### Dart analysis

```bash
cd app
flutter analyze lib/
```

### Continuous integration

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on
GitHub-hosted runners. Every push and pull request runs the `checks` job
on Linux: the release-notes check, `dart format`, the design-token,
component-index and app-icon drift checks, and `flutter analyze`. Pushes
to `main` also run the `macos` job: `./build.sh engine`, `bazel test //...`
and `flutter test`. The development repository additionally runs the
engine tests under ASan+UBSan and TSan, the C++ format check and a
Windows build on self-hosted runners; every check has a local command
in the sections above.

## Project Structure

Eclipsa Studio is organised around a **standalone C++ audio engine**
(`engine/`) and a **Flutter UI** (`app/`) as two siblings at the repo
root. The engine is kept UI-agnostic so it can be reused outside the
app (tests, tooling, other hosts). Subcomponents of the engine live in
named subdirectories (`graph/`, `renderer/`, `meters/`, `io/`, `wav/`,
`dsp/`, `iamf/`, `bounce/`, `mix_renderer/`, `waveform/`, `video/`,
`adm_import/`, `tools/`); lifecycle, transport and the audio thread are
the loose files at `engine/`.

## Third-Party Dependencies

The dependency inventory spans four mechanisms. Everything is pinned
and reproducible: Bazel Central Registry versions, git commits, or
sha256-verified archives.

- **C++ engine, Bazel-managed** ([`engine/MODULE.bazel`](engine/MODULE.bazel))
  — BCR modules (abseil-cpp, eigen, googletest, protobuf, …), plus
  git-pinned overrides for `iamf_tools`, `oar`, and `loudness_ebur128`,
  and a sha256-pinned `http_archive` for libsamplerate. Enumerate the
  full transitive graph with `bazel mod graph` (from `engine/`).
- **Vendored source and license texts** ([`third_party/`](third_party/))
  — one directory per dependency, each with a `METADATA` recording
  provenance. The directories carry only the license and notice texts
  the distributed binaries oblige us to carry: the Steinberg ASIO® SDK host
  subset (fetched from Steinberg by the Windows build and compiled into
  the engine), FFmpeg and GPAC (built at build time), ANGLE (distributed
  as dynamically linked libraries) and the bundled fonts.

  <img src="app/assets/asio/asio_compatible_logo_bw.png" alt="ASIO Compatible logo" height="48"> ASIO is a trademark of Steinberg Media Technologies GmbH, registered in Europe and other countries.
- **C++ engine, build scaffolding** ([`engine/deps/`](engine/deps/))
  — our own scripts and Bazel wrappers for libraries Bazel cannot fetch
  and build itself: ffmpeg, gpac, the ANGLE build script, and the
  libsamplerate BUILD wrapper. The source is downloaded at build time
  and git-ignored; what is checked in is the recipe. `ls engine/deps`
  lists them.
- **Flutter app** ([`app/pubspec.yaml`](app/pubspec.yaml), locked in
  `app/pubspec.lock`) — Dart/Flutter packages; inspect with
  `flutter pub deps` from `app/` (add `--json` for tooling).
- **Native plugin dependencies** — pods pulled one level deeper by
  Flutter plugins on macOS, locked in `app/macos/Podfile.lock`.

License attributions:
[`third_party/THIRD_PARTY_NOTICES.txt`](third_party/THIRD_PARTY_NOTICES.txt)
aggregates the notices for everything statically linked into the
engine and for the libraries distributed beside the app. It is
generated by `scripts/collect_third_party_notices.py` from the
`MODULE.bazel` pins and the texts under `third_party/`, so it stays in
lockstep with the versions built.
Dart/Flutter package licenses are embedded by the Flutter build and
viewable in-app (Eclipsa Studio menu → Third-Party Licenses…).

## Disclaimer

This is not an officially supported Google product. This project is not eligible for the [Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

## License

Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied. See the License for the specific language governing
permissions and limitations under the License.

The Apache 2.0 grant above covers this project's own source. Third-party
components keep their own licenses; see
[`third_party/THIRD_PARTY_NOTICES.txt`](third_party/THIRD_PARTY_NOTICES.txt).

The bundled typefaces are not covered by the Apache 2.0 grant. Inter
and JetBrains Mono (`app/assets/fonts/*.ttf`) are licensed under the
SIL Open Font License 1.1, with the license texts under
[`third_party/fonts/`](third_party/fonts/), one directory per family.
Both families are distributed unmodified, and neither declares a Reserved Font
Name.
