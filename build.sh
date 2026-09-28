#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# build.sh — Build, run, and package Eclipsa Studio for macOS
#
# Usage:
#   ./build.sh clean                         # clean build and re-fetch deps
#   ./build.sh clean --deep                  # ... + wipe Pods, bazel disk cache, ~/.pub-cache
#   ./build.sh lint                          # clang-format + clang-tidy + dart format
#   ./build.sh lint --check                  # verify formatting only (CI gate, no writes)
#   ./build.sh gen-version                   # stamp version.dart + engine_version.h (no build)
#   ./build.sh gen-tokens                    # regenerate theme_tokens.dart from app/design/tokens/
#   ./build.sh gen-tokens --check            # verify theme_tokens.dart is current (CI gate)
#   ./build.sh gen-components                # regenerate component_index.dart from app/design/components.json
#   ./build.sh gen-components --check        # verify component_index.dart is current (CI gate)
#   ./build.sh gen-icon                      # regenerate app/design/brand (SVG + PNG) and the platform app icons
#   ./build.sh gen-icon --check              # verify all of those are current (CI gate)
#   ./build.sh engine                        # build the C++ engine dylib (optimized)
#   ./build.sh run                           # build engine + run (release + lint)
#   ./build.sh run debug                     # ... debug mode (fastbuild engine, hot reload, no lint)
#   ./build.sh run fresh                     # ... + reset prefs and recents first
#   ./build.sh run debug fresh               # ... debug + reset prefs and recents
#   ./build.sh run --no-lint                 # ... release + skip linting
#   ./build.sh test-iamf FILE.iamf           # ... release + auto-open an IAMF for QC
#   ./build.sh package                       # build + sign + notarize (DMG)
#   ./build.sh package --no-notarize         # build + sign (skip notarize)
#   ./build.sh package upload                # build + sign + notarize + upload
#   ./build.sh package gh-release            # ... + draft GitHub release (DMG + notes)
#   ./build.sh package upload gh-release     # ... + gdrive upload + draft GitHub release
#   ./build.sh package --no-notarize upload  # build + sign + upload (skip notarize)
#   ./build.sh package --allow-dirty         # package off-tag / dirty tree (pre-release DMG)
#
# ─── Releasing ──────────────────────────────────────────────────────────
#
# Tag is the source of truth for release versions. `./build.sh package`
# reads `git describe --tags --match='v*'` and passes the result to
# `flutter build macos` as --build-name / --build-number, which overrides
# pubspec.yaml at build time and stamps the correct version into the
# app bundle's Info.plist (CFBundleShortVersionString / CFBundleVersion).
# pubspec.yaml's version is a fallback only — build.sh generates
# lib/generated/version.dart from the nearest v* tag for all commands.
#
# To cut a release:
#
#     # 1. Add the version's notes to RELEASES.md and commit
#     #    (docs(release): release notes for 0.2.0)
#     git tag -a v0.2.0 -m "Release 0.2.0"
#     ./build.sh package upload gh-release   # build, sign, notarize,
#     #   upload DMG to gdrive, and open a DRAFT GitHub release with the
#     #   DMG + notes attached. No public release/tag is created yet.
#     # 2. Verify the DMG, then publish:
#     git push origin v0.2.0                 # push the annotated tag
#     gh release edit v0.2.0 --draft=false   # flip the draft live
#
# Releases must be on an exact v* tag with a clean tree. For pre-release
# or ad-hoc test builds, pass --allow-dirty — the DMG name will include
# the full `git describe` output so pre-release artifacts are obvious.
#
# ─── Signing one-time setup ─────────────────────────────────────────────
#
# 1. Install a "Developer ID Application" certificate in the login keychain
#    and set DEVELOPER_ID_APP to its identity.
#
# 2. Store notarization credentials:
#
#      xcrun notarytool store-credentials "eclipsa-notary" \
#        --apple-id "<Apple ID email>" \
#        --team-id "<Team ID>" \
#        --password "app-specific-password"
#
# 3. rclone (only for upload):
#      brew install rclone
#      rclone config   # add a "gdrive" remote
#
# 4. gh (only for gh-release):
#      brew install gh
#      gh auth login   # authenticate against the eclipsa-studio repo
#
# ─── Configuration ──────────────────────────────────────────────────────
#
# Override via environment variables, e.g.:
#   DEVELOPER_ID_APP="Developer ID Application: Other (XYZ)" ./build.sh package
#

set -euo pipefail

APP_NAME="Eclipsa Studio"
BUNDLE_ID="com.eclipsa.studio"

# The public tree ships DEFAULT_DEVELOPER_ID_APP empty (the open-source
# export blanks it); set DEVELOPER_ID_APP in the environment there.
DEFAULT_DEVELOPER_ID_APP=""
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-$DEFAULT_DEVELOPER_ID_APP}"
APP_PASSWORD_KEYCHAIN="${APP_PASSWORD_KEYCHAIN:-eclipsa-notary}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:Builds/EclipsaStudio}"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT/app"

ENGINE_SRC="$REPO_ROOT/engine"
ENGINE_OUT="$ENGINE_SRC/build"
FLUTTER_DIR="$REPO_ROOT/app"
# Written by debug runs; `kill -USR1 $(cat "$FLUTTER_PID_FILE")` hot reloads.
FLUTTER_PID_FILE="$FLUTTER_DIR/build/flutter_run.pid"
DYLIB_NAME="libeclipsa_studio_engine.dylib"
GPAC_DIR="$ENGINE_SRC/deps/gpac"
GPAC_LIB="libgpac.dylib"
# Vendored LGPL FFmpeg (+ dav1d) for the video backend (ES-249, macOS-only).
FFMPEG_DIR="$ENGINE_SRC/deps/ffmpeg"
FFMPEG_LIBS=(
  libavutil.dylib
  libavcodec.dylib
  libavformat.dylib
  libswscale.dylib
  libswresample.dylib
  libdav1d.dylib
)

# ─── Helpers ─────────────────────────────────────────────────────────────

step=0
info()  { step=$((step + 1)); echo ""; echo "[$step] $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
warn()  { echo "WARNING: $*" >&2; }

# Minimum Flutter version, taken from app/pubspec.yaml's `flutter:`
# environment constraint so the gate cannot drift from the constraint pub
# itself enforces. Prints nothing when no lower bound is declared.
required_flutter_version() {
  [[ -f "$FLUTTER_DIR/pubspec.yaml" ]] || return 0
  sed -n 's/^[[:space:]]*flutter:[[:space:]]*["'\'']\{0,1\}[>^]=\{0,1\}[[:space:]]*\([0-9][0-9.]*\).*/\1/p' \
    "$FLUTTER_DIR/pubspec.yaml" | head -1
}

# Installed Flutter version, from `flutter --version --machine` (stable JSON)
# rather than the human banner. Prints nothing if it cannot be determined;
# jq is not a dependency of this script, so the field is read with sed. A
# failing flutter call must not trip `set -e`/pipefail: its output, if any,
# is still read, and an empty result takes the warn path.
installed_flutter_version() {
  { flutter --version --machine 2>/dev/null || true; } \
    | sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

# True when dotted version $1 is lower than $2. Compared field by field in
# bash rather than with `sort -V`, which BSD sort has not always had. A
# pre-release suffix (3.48.0-1.2.pre on beta) is dropped first, and 10# keeps
# a zero-padded field from being read as octal.
version_lt() {
  local -a a b
  local i x y
  IFS=. read -r -a a <<< "${1%%-*}"
  IFS=. read -r -a b <<< "${2%%-*}"
  for ((i = 0; i < 3; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 1
}

# Fail before the engine build when the installed Flutter is older than the
# constraint. Without this, pub reports the mismatch only after Bazel has
# built the engine, which takes several minutes. A pre-release (3.47.5-0.1.pre)
# counts as its release here, although pub orders it earlier; pub still
# rejects it after the engine build.
#
# Only the lower bound is enforced: being ahead of the pinned version is the
# normal state right after `flutter upgrade`. An unreadable version warns
# rather than fails, leaving pub as the backstop; a build must not be blocked
# by an unexpected `--machine` payload.
require_flutter_version() {
  command -v flutter >/dev/null || die "flutter not found in PATH"
  local required installed
  required=$(required_flutter_version)
  [[ -n "$required" ]] || return 0
  installed=$(installed_flutter_version)
  if [[ -z "$installed" ]]; then
    warn "could not read the Flutter version; skipping the version check"
    return 0
  fi
  if version_lt "$installed" "$required"; then
    die "Flutter $installed is older than the $required required by" \
        "app/pubspec.yaml — run 'flutter upgrade'"
  fi
}

# Resolve a clang tool from PATH, falling back to Homebrew's keg-only
# llvm (not symlinked into PATH by default). Prints the resolved path,
# or nothing when the tool is unavailable.
find_clang_tool() {
  if command -v "$1" >/dev/null; then
    command -v "$1"
    return
  fi
  local brew_tool
  for brew_tool in /opt/homebrew/opt/llvm/bin/"$1" \
                   /usr/local/opt/llvm/bin/"$1"; do
    if [[ -x "$brew_tool" ]]; then
      echo "$brew_tool"
      return
    fi
  done
}

# Lint C++ engine source: clang-format (in-place) + clang-tidy (warnings).
# Skipped when --no-lint is passed.
lint_engine() {
  # $1: "true" → check-only mode (CI gate). clang-format runs --dry-run
  # -Werror (no in-place writes, non-zero exit on any diff) and clang-tidy
  # is skipped. Default ("false") fixes formatting in place.
  local check="${1:-false}"
  info "Linting C++ engine source…"

  # Collect project source files (exclude deps, bazel output, build/).
  # third_party/ is excluded too even though engine/third_party/ was
  # renamed to engine/deps/: its build outputs (fetched FFmpeg/GPAC
  # headers) are git-ignored, so a machine that built before the rename
  # keeps a stale engine/third_party/ that checkout will not remove.
  # Without this the formatter walks into vendored dav1d headers.
  local all_files=()
  while IFS= read -r f; do
    all_files+=("$f")
  done < <(find "$ENGINE_SRC" \( -name '*.cc' -o -name '*.h' \) \
             -not -path '*/deps/*' \
             -not -path '*/third_party/*' \
             -not -path '*/bazel-*' \
             -not -path '*/build/*' | sort)

  if [[ ${#all_files[@]} -eq 0 ]]; then
    echo "  No C++ source files found."
    return
  fi

  # ── clang-format ───────────────────────────────────────────────────────
  # Default fixes in place (-i). Check mode verifies only: --dry-run -Werror
  # exits non-zero on any diff without touching the tree.
  local clang_format
  clang_format=$(find_clang_tool clang-format)
  local fmt_failed=false
  if [[ -n "$clang_format" ]]; then
    if $check; then
      echo "  clang-format: checking ${#all_files[@]} files…"
      # Capture diagnostics (clang-format prints them to stderr) so the
      # final verdict can list the offending files, then replay them.
      local fmt_out
      if ! fmt_out=$("$clang_format" --dry-run -Werror "${all_files[@]}" 2>&1)
      then
        fmt_failed=true
        printf '%s\n' "$fmt_out" >&2
        LINT_CHECK_CC_FILES=$(printf '%s\n' "$fmt_out" \
          | sed -n 's/^\([^:]*\):[0-9][0-9]*:[0-9][0-9]*: error: .*/\1/p' \
          | sed "s|^$REPO_ROOT/||" | sort -u)
        echo "  clang-format: needs formatting — run ./build.sh lint." >&2
      fi
    else
      echo "  clang-format: formatting ${#all_files[@]} files…"
      "$clang_format" -i "${all_files[@]}"
    fi
  else
    echo "  clang-format not found — skipping (brew install llvm)."
  fi

  # ── clang-tidy (warnings only, non-blocking) ──────────────────────────
  # Skipped in check mode: it never gates (warnings only), and recompiling
  # every TU without Bazel's include paths just adds noise + minutes to CI.
  # Skip test/ files — they depend on gtest headers managed by Bazel.
  if ! $check; then
    local clang_tidy
    clang_tidy=$(find_clang_tool clang-tidy)
    if [[ -n "$clang_tidy" ]]; then
      local cc_files=()
      for f in "${all_files[@]}"; do
        [[ "$f" == *.cc && "$f" != */test/* ]] && cc_files+=("$f")
      done
      if [[ ${#cc_files[@]} -gt 0 ]]; then
        echo "  clang-tidy: checking ${#cc_files[@]} translation units…"
        local had_warnings=false
        for f in "${cc_files[@]}"; do
          if ! "$clang_tidy" --quiet "$f" \
                -- -std=c++20 \
                   -I"$ENGINE_SRC" \
                   -I"$ENGINE_SRC/deps/dr_wav" 2>/dev/null; then
            had_warnings=true
          fi
        done
        if $had_warnings; then
          echo "  clang-tidy: warnings found (see above)."
        else
          echo "  clang-tidy: clean ✓"
        fi
      fi
    else
      echo "  clang-tidy not found — skipping (brew install llvm)."
    fi
  fi

  # Check mode signals an unformatted tree to the caller (CI gate).
  if $check && $fmt_failed; then
    return 1
  fi
  return 0
}

# Format Dart source in place: `dart format` over app/lib + app/test.
# `dart format` enforces the repo's Dart style (Google Dart style, trailing
# commas, lines <= 80); its default 80-column profile matches, so there is
# no --line-length override.
# Mirrors clang-format's fix-in-place behavior and runs in the same
# contexts as lint_engine (skipped under --no-lint / debug runs).
format_dart() {
  # $1: "true" → check-only mode (CI gate): --set-exit-if-changed reports a
  # diff via non-zero exit without rewriting. Default formats in place.
  local check="${1:-false}"
  info "Formatting Dart source…"

  # Prefer a standalone `dart`; otherwise use the one bundled with flutter.
  local dart_bin=""
  if command -v dart >/dev/null; then
    dart_bin=$(command -v dart)
  elif command -v flutter >/dev/null; then
    dart_bin="$(dirname "$(command -v flutter)")/dart"
  fi

  if [[ -n "$dart_bin" && -x "$dart_bin" ]]; then
    if $check; then
      echo "  dart format --set-exit-if-changed: lib/ test/…"
      # Capture the "Changed <path>" lines so the final verdict can
      # list the offending files, then replay the output.
      local dart_out dart_rc=0
      dart_out=$("$dart_bin" format --output=none --set-exit-if-changed \
        "$FLUTTER_DIR/lib" "$FLUTTER_DIR/test" 2>&1) || dart_rc=$?
      printf '%s\n' "$dart_out"
      if (( dart_rc != 0 )); then
        LINT_CHECK_DART_FILES=$(printf '%s\n' "$dart_out" \
          | sed -n 's/^Changed //p' | sed "s|^$REPO_ROOT/||" | sort -u)
        return 1
      fi
    else
      echo "  dart format: lib/ test/…"
      "$dart_bin" format "$FLUTTER_DIR/lib" "$FLUTTER_DIR/test"
    fi
  else
    echo "  dart not found — skipping (install the Flutter/Dart SDK)."
  fi
}

# Write lib/generated/version.dart with an explicit version string. This is
# the only thing that sets the in-app version (About dialog, landing screen,
# status bar); the file is gitignored, so every build path must stamp it.
write_version_dart() {
  local ver="$1"
  mkdir -p "$FLUTTER_DIR/lib/generated"
  cat > "$FLUTTER_DIR/lib/generated/version.dart" <<DART
// Generated by build.sh — do not edit by hand.
const appVersion = '$ver';
DART
  echo "Version: v$ver"
}

# Write engine/generated/engine_version.h so eclipsa_studio_version() reports the
# same version as the app instead of a hand-maintained literal. The file is
# gitignored; a bare `bazel build` without it falls back to "dev"
# (see the __has_include block in engine/engine.cc).
write_engine_version_header() {
  local ver="$1"
  mkdir -p "$ENGINE_SRC/generated"
  cat > "$ENGINE_SRC/generated/engine_version.h" <<HDR
// Generated by build.sh — do not edit by hand.
#ifndef ECLIPSA_STUDIO_GENERATED_ENGINE_VERSION_H_
#define ECLIPSA_STUDIO_GENERATED_ENGINE_VERSION_H_
#define ECLIPSA_STUDIO_ENGINE_VERSION "$ver"
#endif  // ECLIPSA_STUDIO_GENERATED_ENGINE_VERSION_H_
HDR
}

# Resolve the version string from git describe (run/build paths).
# On an exact clean tag: "0.2.0". Off-tag or dirty: "0.2.0-dev".
# Falls back to the version in pubspec.yaml if no v* tags exist.
compute_dev_version() {
  if git describe --tags --match='v*' >/dev/null 2>&1; then
    local describe
    describe=$(git describe --tags --dirty --match='v*')
    local nearest
    nearest=$(git describe --tags --abbrev=0 --match='v*')
    if [[ "$describe" == "$nearest" ]]; then
      echo "${nearest#v}"
    else
      echo "${nearest#v}-dev"
    fi
  else
    grep '^version:' "$FLUTTER_DIR/pubspec.yaml" | sed 's/version: *//;s/+.*//'
  fi
}

# Stamp lib/generated/version.dart + engine/generated/engine_version.h.
# The `package` path uses the resolved VERSION_FULL instead (see below) so
# the in-app version matches the DMG / Info.plist exactly.
generate_version_dart() {
  local ver
  ver=$(compute_dev_version)
  write_version_dart "$ver"
  write_engine_version_header "$ver"
}

# Generate app/assets/releases.json from RELEASES.md so the in-app
# What's New dialog (and any other release-aware UI) can render
# notes from a structured source. Sourced from the public release
# notes file at the repo root.
generate_releases_json() {
  local script="$REPO_ROOT/scripts/release_notes.py"
  local out_dir="$FLUTTER_DIR/assets"
  local out_file="$out_dir/releases.json"
  if [[ ! -x "$script" ]]; then
    echo "warning: scripts/release_notes.py not executable; skipping releases.json" >&2
    return
  fi
  mkdir -p "$out_dir"
  # Write to a temp file first: `> "$out_file"` would truncate the
  # asset before Python runs, so a failure (e.g. the Windows-glyph
  # gate in release_notes.py, ES-263) would ship an empty dialog.
  # Failure is fatal, matching build.ps1 — the gate is only a gate
  # if it stops the build.
  local tmp_file="$out_file.tmp"
  if ! "$script" json > "$tmp_file"; then
    rm -f "$tmp_file"
    die "scripts/release_notes.py json failed — fix RELEASES.md (see errors above)"
  fi
  mv "$tmp_file" "$out_file"
  echo "Generated $out_file"
}

# Print the size of a path if it exists, else "—".
size_of() {
  if [[ -e "$1" ]]; then
    du -sh "$1" 2>/dev/null | cut -f1
  else
    echo "—"
  fi
}

# Remove caches that `flutter clean` and `bazel clean` leave behind.
# Invoked from `clean --deep`. Blasts CocoaPods artifacts, the Bazel disk
# cache (via --expunge), and ~/.pub-cache. The pub cache is shared with
# every Flutter project on this machine — the warning is intentional.
deep_clean() {
  info "Deep clean: removing caches…"

  # CocoaPods artifacts — regenerated on next `pod install` during
  # `flutter pub get`.
  local pods_dir="$FLUTTER_DIR/macos/Pods"
  local pods_lock="$FLUTTER_DIR/macos/Podfile.lock"
  local pods_symlinks="$FLUTTER_DIR/macos/.symlinks"
  if [[ -d "$pods_dir" ]]; then
    echo "  • Pods/ ($(size_of "$pods_dir"))"
    rm -rf "$pods_dir"
  fi
  if [[ -f "$pods_lock" ]]; then
    echo "  • Podfile.lock"
    rm -f "$pods_lock"
  fi
  if [[ -d "$pods_symlinks" ]]; then
    echo "  • macos/.symlinks/"
    rm -rf "$pods_symlinks"
  fi

  # Bazel disk cache — `bazel clean --expunge` in the engine dir wipes
  # the output tree AND the execroot under ~/Library/Caches/bazel.
  if [[ -d "$ENGINE_SRC" ]] && command -v bazel >/dev/null; then
    echo "  • bazel disk cache (expunge)"
    (cd "$ENGINE_SRC" && bazel clean --expunge 2>/dev/null || true)
  fi

  # ~/.pub-cache — holds every version of every package every Flutter
  # project on this machine has ever resolved. Big, but system-wide.
  local pub_cache="$HOME/.pub-cache"
  if [[ -d "$pub_cache" ]]; then
    echo "  • ~/.pub-cache ($(size_of "$pub_cache")) — affects ALL Flutter projects"
    rm -rf "$pub_cache"
  fi
}

# Resolve the release version from git tags. Tag is source of truth —
# pubspec.yaml is only a dev-mode default. Sets these globals:
#
#   BUILD_NAME    e.g. "0.1.0"       — from nearest v* tag, minus leading v
#   BUILD_NUMBER  e.g. "137"         — total commit count on HEAD
#   VERSION_FULL  e.g. "0.1.0" or   — full `git describe` output (minus v),
#                 "0.1.0-3-gabc-dirty" used for DMG naming
#   VERSION_CLEAN true/false         — HEAD is on exact v* tag AND tree clean
#
# Dies if no v* tags exist, or if the state is unclean and ALLOW_DIRTY is
# false. BUILD_NAME / BUILD_NUMBER are always the nearest-tag values so
# flutter build's --build-name / --build-number stamp a valid semver into
# Info.plist even for pre-release DMGs.
resolve_version() {
  command -v git >/dev/null || die "git not found in PATH"

  local describe
  describe=$(git describe --tags --dirty --match='v*' 2>/dev/null || true)
  [[ -n "$describe" ]] || die \
"No v* tags found. Create one before packaging:

    git tag -a v0.1.0 -m 'Release 0.1.0'

Then run ./build.sh package again."

  local nearest
  nearest=$(git describe --tags --abbrev=0 --match='v*')
  BUILD_NAME="${nearest#v}"
  BUILD_NUMBER=$(git rev-list --count HEAD)
  VERSION_FULL="${describe#v}"

  local dirty=false
  local on_tag=false
  [[ "$describe" == *-dirty ]] && dirty=true
  if git describe --tags --exact-match --match='v*' >/dev/null 2>&1; then
    on_tag=true
  fi

  VERSION_CLEAN=false
  if $on_tag && ! $dirty; then
    VERSION_CLEAN=true
  fi

  info "Resolving release version…"
  echo "  Nearest tag:   v$BUILD_NAME"
  echo "  Build number:  $BUILD_NUMBER (total commit count)"
  echo "  Describe:      $VERSION_FULL"
  if $VERSION_CLEAN; then
    echo "  State:         clean release ✓"
  else
    echo "  State:         PRE-RELEASE (off-tag or dirty)"
    if ! $ALLOW_DIRTY; then
      die "Refusing to package a pre-release build.
  • Commit your changes and tag the release, or
  • Pass --allow-dirty for an ad-hoc pre-release DMG."
    fi
  fi
}

# Ensure the vendored libgpac (the MP4 muxer's LGPL dependency, linked
# dynamically) exists before Bazel tries to link against it. The .dylib and
# headers are build outputs, not checked in (see
# engine/deps/gpac/README.md), and the engine's cc_import references
# them by path — so a clean checkout would fail the engine build without
# this. build_gpac.sh clones + compiles GPAC, which is slow, so skip it when
# the outputs are already present AND were produced by the current recipe.
# Mirrors build.ps1's Ensure-Gpac.
#
# The freshness check stamps the outputs with a SHA-256 of build_gpac.sh
# plus every patch it applies (lib/.build_id) and rebuilds when it's
# missing or stale. On the persistent
# CI runner (checkout keeps warm artifacts) this matters: without it, a copy
# vendored by an older recipe — e.g. before the GPAC pin bump or a link-flag
# fix landed — would be reused forever, silently shipping the stale library.
# Delete engine/deps/gpac/lib to force a rebuild by hand.
ensure_gpac() {
  local recipe="$GPAC_DIR/build_gpac.sh"
  local stamp="$GPAC_DIR/lib/.build_id"
  local want_id
  want_id="$(cat "$recipe" "$GPAC_DIR"/patches/*.patch 2>/dev/null \
    | shasum -a 256 | awk '{print $1}')"
  local have_id=""
  if [[ -f "$stamp" ]]; then have_id="$(tr -d '[:space:]' < "$stamp")"; fi
  if [[ -f "$GPAC_DIR/lib/$GPAC_LIB" \
     && -n "$(ls -A "$GPAC_DIR/include/gpac" 2>/dev/null)" \
     && "$have_id" == "$want_id" ]]; then
    return 0
  fi
  info "Building vendored libgpac (one-time, for the MP4 muxer)…"
  "$GPAC_DIR/build_gpac.sh"
  printf '%s\n' "$want_id" > "$stamp"
}

# Ensure the vendored LGPL FFmpeg (+ dav1d) exists before Bazel links the
# video backend against it. Like libgpac, the dylibs + headers are build
# outputs (not checked in) referenced by //deps/ffmpeg's cc_import, so
# a clean checkout would fail the (macOS) engine build without this.
# build_ffmpeg.sh builds FFmpeg + dav1d from source, which is slow, so skip
# when the libraries and headers are already present AND were produced by the
# current recipe — the same lib/.build_id SHA-256 stamp as ensure_gpac (and
# build.ps1's Ensure-Ffmpeg), so a recipe change (FFmpeg pin bump,
# configure-flag fix) can't silently reuse stale dylibs on the persistent CI
# runner. Delete engine/deps/ffmpeg/lib to force a rebuild by hand.
ensure_ffmpeg() {
  local recipe="$FFMPEG_DIR/build_ffmpeg.sh"
  local stamp="$FFMPEG_DIR/lib/.build_id"
  local want_id
  want_id="$(shasum -a 256 "$recipe" | awk '{print $1}')"
  local have_id=""
  if [[ -f "$stamp" ]]; then have_id="$(tr -d '[:space:]' < "$stamp")"; fi
  local have=true
  for lib in "${FFMPEG_LIBS[@]}"; do
    [[ -f "$FFMPEG_DIR/lib/$lib" ]] || have=false
  done
  if $have \
     && [[ -n "$(ls -A "$FFMPEG_DIR/include/libavcodec" 2>/dev/null)" ]] \
     && [[ "$have_id" == "$want_id" ]]; then
    return 0
  fi
  info "Building vendored FFmpeg + dav1d (one-time, for the video backend)…"
  "$FFMPEG_DIR/build_ffmpeg.sh"
  printf '%s\n' "$want_id" > "$stamp"
}

# Build the C++ audio engine via Bazel and copy the dylib to engine/build/.
# Pass "opt" for an optimized build (-c opt: release runs and packaged
# DMGs — DSP code is ~5× faster than fastbuild, see issue ES-87). Default
# is Bazel's fastbuild (-O0) to keep debug iteration quick. The
# bazel-bin symlink always points at the latest build's output tree, so
# the copy below is mode-agnostic.
build_engine() {
  command -v bazel >/dev/null || die "bazel not found in PATH — brew install bazelisk"
  ensure_gpac
  ensure_ffmpeg
  # Plain string, expanded unquoted: macOS bash 3.2 + `set -u` rejects
  # the empty-array "${arr[@]}" idiom.
  local bazel_mode=""
  if [[ "${1:-}" == "opt" ]]; then
    bazel_mode="-c opt"
    info "Building C++ audio engine (optimized)…"
  else
    info "Building C++ audio engine…"
  fi
  (cd "$ENGINE_SRC" && bazel build $bazel_mode //:eclipsa_studio_engine)
  mkdir -p "$ENGINE_OUT"
  rm -f "$ENGINE_OUT/$DYLIB_NAME"
  cp "$ENGINE_SRC/bazel-bin/$DYLIB_NAME" "$ENGINE_OUT/$DYLIB_NAME"
  echo "Engine: $ENGINE_OUT/$DYLIB_NAME"
}

# Path-hygiene gate (ES-374): no shipped native dylib may embed the
# builder's home directory or Bazel output root. Bazel hands clang
# relative paths, so __FILE__ in third-party asserts stays relative
# (external/…) — this guards against a toolchain or vendored-build
# regression re-introducing absolute paths. App.framework is excluded:
# Flutter's AOT tooling embeds the dart_plugin_registrant.dart file URI
# (repo path) and offers no trim flag short of --obfuscate; accepted.
check_path_leaks() {
  local frameworks_dir="$1"
  info "Checking embedded dylibs for local build paths…"
  local f
  for f in "$frameworks_dir"/*.dylib; do
    [[ -e "$f" ]] || continue
    if strings -a "$f" | grep -qE '/Users/|_bazel_|execroot/'; then
      die "local build path leaked into $(basename "$f") — see ES-374:
$(strings -a "$f" | grep -E '/Users/|_bazel_|execroot/' | head -5)"
    fi
  done
  echo "No local build paths in shipped dylibs."
}

# Build the release .app. The Xcode project pins Release signing to the
# Developer ID identity (Manual style, the team set in project.pbxproj),
# which only exists on machines provisioned for distribution. On any other
# machine, fall back to ad-hoc signing ("Sign to Run Locally") by driving
# xcodebuild directly with signing overrides — same derived-data layout as
# the flutter tool, so the .app lands at the usual Products/Release path.
# Ad-hoc apps run fine on the machine that built them (Gatekeeper only
# vets quarantined downloads); `package` still hard-requires the real
# identity.
flutter_build_release() {
  if [ -n "$DEVELOPER_ID_APP" ] \
      && security find-identity -v -p codesigning 2>/dev/null \
      | grep -q -F "$DEVELOPER_ID_APP"; then
    flutter build macos --release
  else
    info "No Developer ID identity in keychain — ad-hoc signing (local run only)…"
    flutter build macos --release --config-only
    xcodebuild -workspace "$FLUTTER_DIR/macos/Runner.xcworkspace" \
      -scheme Runner -configuration Release \
      -derivedDataPath "$FLUTTER_DIR/build/macos" \
      -quiet \
      CODE_SIGN_STYLE=Automatic \
      CODE_SIGN_IDENTITY="-" \
      DEVELOPMENT_TEAM="" \
      PROVISIONING_PROFILE_SPECIFIER="" \
      build
  fi
}

# Copy the engine dylib — and the LGPL libraries it dynamically links — into a
# bundle's Frameworks dir. The engine references @rpath/libgpac.dylib (the MP4
# muxer) and @rpath/libav*.dylib + @rpath/libdav1d.dylib (the video backend),
# which resolve via the app's @executable_path/../Frameworks rpath, so unless
# they sit beside the engine it fails to dlopen at runtime ("Library not
# loaded: @rpath/…"). All are produced by build_engine (which vendors them via
# ensure_gpac / ensure_ffmpeg), so call this only after it. rm-then-cp because
# an existing copy may be code-signed / read-only. $1 = the
# .../Contents/Frameworks dir.
embed_engine_libs() {
  local fw="$1"
  rm -f "$fw/$DYLIB_NAME"
  cp "$ENGINE_OUT/$DYLIB_NAME" "$fw/$DYLIB_NAME"
  rm -f "$fw/$GPAC_LIB"
  cp "$GPAC_DIR/lib/$GPAC_LIB" "$fw/$GPAC_LIB"
  for lib in "${FFMPEG_LIBS[@]}"; do
    rm -f "$fw/$lib"
    cp "$FFMPEG_DIR/lib/$lib" "$fw/$lib"
  done
}


# ─── Global flags ────────────────────────────────────────────────────────

SKIP_LINT=false
ALLOW_DIRTY=false
for arg in "$@"; do
  [[ "$arg" == "--no-lint"     ]] && SKIP_LINT=true
  [[ "$arg" == "--allow-dirty" ]] && ALLOW_DIRTY=true
done

# ─── Commands ────────────────────────────────────────────────────────────

case "${1:-}" in
  lint)
    # `--check` is the CI gate: verify formatting without writing and exit
    # non-zero if anything is unformatted. Run both checks (|| capture) so
    # all problems surface in one pass rather than failing fast on the first.
    # The verdict prints LAST (ES-337): per-file diagnostics scroll away and
    # pipes like `| tail` mask the exit code, so the outcome must be the
    # final line either way.
    CHECK=false
    for arg in "$@"; do [[ "$arg" == "--check" ]] && CHECK=true; done
    LINT_CHECK_CC_FILES=""
    LINT_CHECK_DART_FILES=""
    rc=0
    lint_engine "$CHECK" || rc=$?
    format_dart "$CHECK" || rc=$?
    if $CHECK; then
      echo ""
      if (( rc != 0 )); then
        if [[ -n "$LINT_CHECK_CC_FILES" ]]; then
          echo "Unformatted C++ (clang-format):" >&2
          while IFS= read -r f; do echo "  $f" >&2; done \
            <<< "$LINT_CHECK_CC_FILES"
        fi
        if [[ -n "$LINT_CHECK_DART_FILES" ]]; then
          echo "Unformatted Dart (dart format):" >&2
          while IFS= read -r f; do echo "  $f" >&2; done \
            <<< "$LINT_CHECK_DART_FILES"
        fi
        echo "LINT CHECK FAILED — run ./build.sh lint" >&2
      else
        echo "LINT CHECK PASSED"
      fi
    fi
    exit $rc
    ;;

  gen-version)
    # Stamp lib/generated/version.dart + engine/generated/engine_version.h
    # (+ assets/releases.json) without a build. CI runs this before
    # `flutter analyze`, which imports the gitignored generated/version.dart
    # (see app/lib/state.dart).
    generate_version_dart
    generate_releases_json
    ;;

  gen-tokens)
    # Regenerate app/lib/theme_tokens.dart from app/design/tokens/. Unlike
    # gen-version's output this file IS committed, so a fresh clone can
    # `flutter analyze` without Python and colour changes show up as a
    # readable diff. `--check` is the CI drift gate: it verifies the
    # committed file matches the tokens without writing.
    CHECK=false
    for arg in "${@:2}"; do
      case "$arg" in
        --check) CHECK=true ;;
        *)       die "Unknown argument to 'gen-tokens': $arg" ;;
      esac
    done
    if $CHECK; then
      python3 "$REPO_ROOT/scripts/gen_design_tokens.py" --check
    else
      python3 "$REPO_ROOT/scripts/gen_design_tokens.py"
    fi
    ;;

  gen-components)
    # Regenerate app/lib/widgets/component_index.dart. Metadata comes
    # from app/design/components.json; the "used in" map is read out of
    # app/lib/, so the Theme Gallery's usage list cannot drift from the
    # code. Committed like theme_tokens.dart, same reasons. `--check`
    # is the CI drift gate.
    CHECK=false
    for arg in "${@:2}"; do
      case "$arg" in
        --check) CHECK=true ;;
        *)       die "Unknown argument to 'gen-components': $arg" ;;
      esac
    done
    if $CHECK; then
      python3 "$REPO_ROOT/scripts/gen_component_index.py" --check
    else
      python3 "$REPO_ROOT/scripts/gen_component_index.py"
    fi
    ;;

  gen-icon)
    # Regenerate app/design/brand (the SVG masters and the PNG exports)
    # and the platform app icons, the macOS Icon Composer document
    # included, from the geometry in scripts/gen_app_icon.py. Committed like the
    # other generated artifacts, because a build must not need Python
    # to produce an icon. Pure stdlib and no shelling out to a
    # rasteriser, so macOS, Windows and CI all emit the same bytes;
    # `--check` is the CI drift gate.
    CHECK=false
    for arg in "${@:2}"; do
      case "$arg" in
        --check) CHECK=true ;;
        *)       die "Unknown argument to 'gen-icon': $arg" ;;
      esac
    done
    if $CHECK; then
      python3 "$REPO_ROOT/scripts/gen_app_icon.py" --check
    else
      python3 "$REPO_ROOT/scripts/gen_app_icon.py"
      # The Dock and Finder cache an app's icon by bundle path and
      # modification time, and a rebuild that replaces files inside
      # the bundle does not always change the bundle's own mtime, so
      # the next run can show the previous icon. Touch every built
      # bundle so the cache is refreshed on the next launch.
      for bundle in "$FLUTTER_DIR"/build/macos/Build/Products/*/"Eclipsa Studio.app"; do
        if [[ -d "$bundle" ]]; then touch "$bundle"; fi
      done
    fi
    ;;

  engine)
    # Build just the optimized C++ engine dylib: ensure_gpac (vendors
    # libgpac) + bazel build //:eclipsa_studio_engine. Mirrors build.ps1's
    # `engine` (including the version stamp, so the dylib never ships
    # a stale engine_version.h); a single CI entry point before
    # `bazel test //...`.
    generate_version_dart
    build_engine opt
    ;;

  clean)
    DEEP=false
    shift
    for arg in "$@"; do
      case "$arg" in
        --deep) DEEP=true ;;
        *)      die "Unknown argument to 'clean': $arg" ;;
      esac
    done

    info "Running flutter clean…"
    flutter clean || true

    if [[ -d "$ENGINE_SRC" ]]; then
      if ! $DEEP; then
        # Non-deep: plain bazel clean leaves the action/analysis cache
        # and daemon alive for faster rebuilds. Deep mode expunges via
        # deep_clean below.
        (cd "$ENGINE_SRC" && bazel clean 2>/dev/null || true)
      fi
      rm -rf "$ENGINE_OUT"
    fi

    if $DEEP; then
      deep_clean
    fi

    info "Fetching dependencies…"
    flutter pub get
    ;;

  run)
    # Default is release: the fastbuild engine decodes IAMF slower than
    # real-time (constant ring underruns — see ES-90/ES-87), so plain `run`
    # builds optimized and lints. `./build.sh run debug` opts into debug
    # mode (Flutter debug + fastbuild engine, no lint) for hot reload
    # and engine debugging. `release` is accepted as a no-op alias of
    # the default for muscle-memory compatibility.
    FLUTTER_MODE="--release"
    WANT_LINT=true
    FRESH=false
    shift
    for arg in "$@"; do
      case "$arg" in
        debug)
          FLUTTER_MODE=""
          WANT_LINT=false
          ;;
        release)   ;;  # alias of the default
        fresh)     FRESH=true ;;
        --no-lint) ;;  # handled globally via SKIP_LINT
        *)         die "Unknown argument to 'run': $arg" ;;
      esac
    done

    require_flutter_version
    if $FRESH; then
      PREFS_SANDBOXED="$HOME/Library/Containers/com.eclipsa.studio/Data/Library/Application Support/com.eclipsa.studio"
      PREFS_DEBUG="$HOME/Library/Application Support/com.eclipsa.studio"
      for dir in "$PREFS_SANDBOXED" "$PREFS_DEBUG"; do
        rm -f "$dir/preferences.json" \
              "$dir/recent_sessions.json" \
              "$dir/recent_qc_files.json" 2>/dev/null
      done
      echo "✓ Preferences and recents cleared"
    fi

    # Generate version.dart from git tags so the UI shows the correct
    # version. Falls back to pubspec.yaml version if no v* tags exist.
    generate_version_dart
    generate_releases_json

    # Lint only for release builds — keeps debug iteration fast.
    if $WANT_LINT && ! $SKIP_LINT; then
      lint_engine
      format_dart
    fi
    # Release runs get the optimized engine; debug stays fastbuild.
    if [[ -n "$FLUTTER_MODE" ]]; then
      build_engine opt
    else
      build_engine
    fi

    flutter pub get

    if [[ -n "$FLUTTER_MODE" ]]; then
      # Release: don't go through `flutter run --release`. Without a
      # VM-service connection the flutter tool never notices the app
      # quitting, so the terminal hangs until Ctrl-C after the window
      # closes. Release runs gain nothing from the tool anyway (no hot
      # reload), so build the bundle, embed the fresh engine dylib
      # (same pattern as `package`), and exec the binary directly —
      # the terminal returns when the app exits, and stdout/stderr
      # (including the engine's rt log) land here.
      flutter_build_release
      APP_PATH="$FLUTTER_DIR/build/macos/Build/Products/Release/$APP_NAME.app"
      [[ -d "$APP_PATH" ]] || die "Build output not found: $APP_PATH"
      embed_engine_libs "$APP_PATH/Contents/Frameworks"
      info "Launching $APP_NAME (release)…"
      exec "$APP_PATH/Contents/MacOS/$APP_NAME"
    fi

    # Debug: `flutter run` for hot reload. Copy the dylib into the
    # .app bundle's Frameworks dir first so the run picks up the fresh
    # engine instead of a stale cached copy (debug output lands in
    # Products/Debug/).
    APP_FRAMEWORKS="$FLUTTER_DIR/build/macos/Build/Products/Debug/$APP_NAME.app/Contents/Frameworks"
    if [ -d "$APP_FRAMEWORKS" ]; then
      embed_engine_libs "$APP_FRAMEWORKS"
    fi

    # The pid file lets another shell drive the run: SIGUSR1 hot
    # reloads, SIGUSR2 hot restarts.
    flutter run -d macos --pid-file "$FLUTTER_PID_FILE"
    ;;

  test-session)
    # Build + run with a test session auto-loaded. Session path comes
    # from (in priority order):
    #   1. ./build.sh test-session /path/to/session.esp
    #   2. $ECLIPSA_STUDIO_TEST_SESSION env var (set in the shell rc file)
    # Test media lives outside the repo — see .gitignore and README.
    SESSION_PATH="${2:-${ECLIPSA_STUDIO_TEST_SESSION:-}}"
    if [[ -z "$SESSION_PATH" ]]; then
      die "No session path given — pass one as an argument or set ECLIPSA_STUDIO_TEST_SESSION"
    fi
    if [[ ! -f "$SESSION_PATH" ]]; then
      die "Session file not found: $SESSION_PATH"
    fi
    require_flutter_version

    generate_version_dart
    generate_releases_json
    build_engine
    APP_FRAMEWORKS="$FLUTTER_DIR/build/macos/Build/Products/Debug/Eclipsa Studio.app/Contents/Frameworks"
    if [ -d "$APP_FRAMEWORKS" ]; then
      embed_engine_libs "$APP_FRAMEWORKS"
    fi
    flutter pub get
    # One flag per argument: a single "--session $SESSION_PATH" string
    # is split on spaces, so a path with a space in it never arrived.
    flutter run -d macos --pid-file "$FLUTTER_PID_FILE" \
      --dart-entrypoint-args=--session \
      --dart-entrypoint-args="$SESSION_PATH"
    ;;

  test-iamf)
    # Build (release) + run with an IAMF file auto-opened in Playback
    # mode (the app's --iamf flag). Path comes from:
    #   1. ./build.sh test-iamf /path/to/file.iamf
    #   2. $ECLIPSA_STUDIO_IAMF env var
    # Release like the default run: the fastbuild engine decodes IAMF
    # slower than real-time, so QC playback would underrun. The path is
    # passed both on argv and via ECLIPSA_STUDIO_IAMF (the env var is the
    # reliable channel for a directly-exec'd .app bundle).
    IAMF_PATH="${2:-${ECLIPSA_STUDIO_IAMF:-}}"
    if [[ -z "$IAMF_PATH" ]]; then
      die "No IAMF path given — pass one as an argument or set ECLIPSA_STUDIO_IAMF"
    fi
    if [[ ! -f "$IAMF_PATH" ]]; then
      die "IAMF file not found: $IAMF_PATH"
    fi
    require_flutter_version

    generate_version_dart
    generate_releases_json
    build_engine opt
    flutter pub get
    flutter_build_release
    APP_PATH="$FLUTTER_DIR/build/macos/Build/Products/Release/$APP_NAME.app"
    [[ -d "$APP_PATH" ]] || die "Build output not found: $APP_PATH"
    embed_engine_libs "$APP_PATH/Contents/Frameworks"
    # The release .app is sandboxed and can't read arbitrary paths (e.g.
    # /tmp, or the Desktop) without a security-scoped bookmark, which a
    # CLI path has none of. Stage the file inside the app's container so
    # any source path opens regardless of where it lives.
    CONTAINER="$HOME/Library/Containers/com.eclipsa.studio/Data"
    mkdir -p "$CONTAINER" 2>/dev/null || true
    STAGED="$CONTAINER/qc-$(basename "$IAMF_PATH")"
    cp -f "$IAMF_PATH" "$STAGED"
    info "Launching $APP_NAME (release) — opening IAMF: $IAMF_PATH"
    export ECLIPSA_STUDIO_IAMF="$STAGED"
    exec "$APP_PATH/Contents/MacOS/$APP_NAME" --iamf "$STAGED"
    ;;

  package)
    # ── Parse flags ───────────────────────────────────────────────────────
    NO_NOTARIZE=false
    DO_UPLOAD=false
    DO_GH_RELEASE=false
    shift
    for arg in "$@"; do
      case "$arg" in
        --no-notarize) NO_NOTARIZE=true ;;
        --no-lint)     ;;  # handled globally
        --allow-dirty) ;;  # handled globally
        upload)        DO_UPLOAD=true ;;
        gh-release)    DO_GH_RELEASE=true ;;
        *)             die "Unknown argument: $arg" ;;
      esac
    done

    # ── Preflight ────────────────────────────────────────────────────────
    require_flutter_version
    command -v bazel    >/dev/null || die "bazel not found in PATH — brew install bazelisk"
    command -v codesign >/dev/null || die "codesign not found (Xcode required)"
    command -v xcrun    >/dev/null || die "xcrun not found (Xcode required)"
    command -v python3  >/dev/null || die "python3 not found in PATH (third-party notices gates)"

    [ -n "$DEVELOPER_ID_APP" ] \
      || die "DEVELOPER_ID_APP is not set: export the Developer ID Application identity to sign with."
    security find-identity -v -p codesigning | grep -q -F "$DEVELOPER_ID_APP" \
      || die "Signing identity not found in the keychain: $DEVELOPER_ID_APP"

    if $DO_UPLOAD; then
      command -v rclone >/dev/null || die "rclone not found — brew install rclone"
    fi

    if $DO_GH_RELEASE; then
      command -v gh >/dev/null || die "gh not found — brew install gh"
      gh auth status >/dev/null 2>&1 \
        || die "gh not authenticated — run: gh auth login"
    fi

    # ── Resolve version from git tags ────────────────────────────────────
    resolve_version

    # Optional pre-package hook for a clean tagged release: runs
    # .claude/release/gate.py when the checkout has it, and stops the
    # package when it fails. Pre-release builds and checkouts without the
    # file skip it.
    PREPACKAGE_GATE="$REPO_ROOT/.claude/release/gate.py"
    if [[ ! -f "$PREPACKAGE_GATE" ]]; then
      info "No pre-package gate in this checkout; skipping it."
    elif ! $VERSION_CLEAN; then
      info "Pre-release build; skipping the pre-package gate."
    else
      info "Running the pre-package gate for ${BUILD_NAME}…"
      python3 "$PREPACKAGE_GATE" gate "$BUILD_NAME" \
        || die "Pre-package gate failed for $BUILD_NAME (see its output above)"
    fi

    # Stamp the in-app version from the resolved tag (ES-121). version.dart is
    # gitignored, so without this the DMG would ship whatever a prior
    # `run`/`build` left on disk — that's how the 0.14.0 release showed
    # "0.13.0-dev" in the UI. VERSION_FULL is "0.14.0" on a clean tagged
    # release (matching the DMG name and CFBundleShortVersionString) and the
    # full describe for --allow-dirty pre-release DMGs. The engine header
    # gets the same string so eclipsa_studio_version() matches the DMG exactly.
    write_version_dart "$VERSION_FULL"
    write_engine_version_header "$VERSION_FULL"

    # ── Lint + Build C++ engine ──────────────────────────────────────────
    $SKIP_LINT || { lint_engine; format_dart; }
    build_engine opt

    # ── Third-party notices (ES-57) ────────────────────────────────────────
    # Committed outputs must match the pinned engine deps. Runs after
    # build_engine so the bazel external repos are fetched.
    info "Checking third-party notices…"
    python3 "$REPO_ROOT/scripts/collect_third_party_notices.py" --check \
      || die "Third-party notices are stale — regenerate with
  python3 scripts/collect_third_party_notices.py
and commit the result."

    # ── Build Flutter ─────────────────────────────────────────────────────
    # --build-name / --build-number override pubspec.yaml and stamp the
    # tag version into Info.plist (CFBundleShortVersionString /
    # CFBundleVersion). Tag is source of truth.
    info "Building Flutter release (v$BUILD_NAME build $BUILD_NUMBER)…"
    generate_releases_json
    flutter clean
    flutter pub get
    flutter build macos --release \
      --build-name="$BUILD_NAME" \
      --build-number="$BUILD_NUMBER"

    APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
    ENTITLEMENTS="macos/Runner/Release.entitlements"

    [[ -d "$APP_PATH" ]] || die "Build output not found: $APP_PATH"

    # Every shipped framework must have a license attribution entry —
    # catches new media_kit / plugin frameworks appearing silently.
    info "Verifying framework license attributions…"
    python3 "$REPO_ROOT/scripts/collect_third_party_notices.py" \
      --verify-bundle "$APP_PATH" \
      || die "Unattributed frameworks in the bundle (see above)."

    # ── Embed engine dylib ────────────────────────────────────────────────
    # Includes libgpac.dylib (the MP4 muxer's LGPL dependency); the dylib
    # sign sweep below picks it up automatically.
    info "Embedding engine dylib in app bundle…"
    embed_engine_libs "$APP_PATH/Contents/Frameworks"

    # ── Path hygiene (ES-374) ──────────────────────────────────────────────
    check_path_leaks "$APP_PATH/Contents/Frameworks"

    # ── Sign ─────────────────────────────────────────────────────────────
    info "Signing embedded dylibs…"
    find "$APP_PATH/Contents/Frameworks" -name "*.dylib" -exec \
      codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID_APP" \
      --entitlements "$ENTITLEMENTS" {} \;

    info "Signing embedded frameworks…"
    find "$APP_PATH/Contents/Frameworks" -name "*.framework" -exec \
      codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID_APP" \
      --entitlements "$ENTITLEMENTS" {} \;

    info "Signing main app bundle…"
    codesign --force --options runtime --timestamp \
      --sign "$DEVELOPER_ID_APP" \
      --entitlements "$ENTITLEMENTS" \
      "$APP_PATH"

    # ── Verify ───────────────────────────────────────────────────────────
    info "Verifying code signature…"
    codesign --verify --deep --strict "$APP_PATH"
    echo "Signature OK."

    # ── DMG ──────────────────────────────────────────────────────────────
    # Clean release: EclipsaStudio-0.1.0.dmg
    # Pre-release:   EclipsaStudio-0.1.0-3-gabc123-dirty-20260412-1530.dmg
    if $VERSION_CLEAN; then
      DMG_NAME="EclipsaStudio-${VERSION_FULL}.dmg"
    else
      BUILD_DATE=$(date +%Y%m%d-%H%M)
      DMG_NAME="EclipsaStudio-${VERSION_FULL}-${BUILD_DATE}.dmg"
    fi
    DMG_PATH="build/${DMG_NAME}"

    info "Creating DMG…"
    DMG_STAGE=$(mktemp -d)
    cp -R "$APP_PATH" "$DMG_STAGE/"
    cp "$REPO_ROOT/third_party/THIRD_PARTY_NOTICES.txt" "$DMG_STAGE/"
    # Full user-facing release notes (ES-124), generated from RELEASES.md so
    # there's no second copy to keep in sync. Warn and ship without it only
    # if RELEASES.md has no entries at all — shouldn't abort the package run.
    if python3 "$REPO_ROOT/scripts/release_notes.py" text \
        > "$DMG_STAGE/RELEASE_NOTES.txt"; then
      info "Bundled RELEASE_NOTES.txt"
    else
      echo "warning: could not render RELEASES.md — DMG ships without" \
           "RELEASE_NOTES.txt" >&2
      rm -f "$DMG_STAGE/RELEASE_NOTES.txt"
    fi
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGE" \
      -ov -format UDZO "$DMG_PATH"
    rm -rf "$DMG_STAGE"

    # Sign the DMG itself
    codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG_PATH"

    # ── Notarize ─────────────────────────────────────────────────────────
    if $NO_NOTARIZE; then
      info "Skipping notarization (--no-notarize)."
    else
      info "Submitting for notarization (this may take a few minutes)…"
      xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$APP_PASSWORD_KEYCHAIN" \
        --wait

      info "Stapling notarization ticket…"
      xcrun stapler staple "$DMG_PATH"
    fi

    echo ""
    echo "Ready: app/${DMG_PATH}"

    # ── Upload (optional) ────────────────────────────────────────────────
    if $DO_UPLOAD; then
      info "Uploading to ${RCLONE_REMOTE}…"
      # --timeout 30s: kill the connection if no IO for 30s. Drive's
      # post-upload finalise step has been observed to hang at 100%
      # indefinitely; rclone's default 5m idle timeout makes that
      # invisible. 30s may abort during a legitimate >30s scan on
      # large DMGs — retries cover it. Bump to 60s if false aborts
      # become a problem. rclone copy is idempotent.
      rclone copy "$DMG_PATH" "$RCLONE_REMOTE" \
        --progress \
        --timeout 30s \
        --contimeout 30s \
        --low-level-retries 10 \
        --retries 5 \
        --retries-sleep 30s \
        --stats 10s --stats-one-line
      echo "Upload complete."
    fi

    # ── GitHub release (optional, draft) ─────────────────────────────────
    # A draft release attaches the DMG and the notes for this version
    # (extracted from RELEASES.md) without creating a public release or a
    # git tag — so the DMG can be verified first. After verifying, push
    # the tag and flip the draft live:
    #     git push origin v${BUILD_NAME}
    #     gh release edit v${BUILD_NAME} --draft=false
    if $DO_GH_RELEASE; then
      if $VERSION_CLEAN; then
        TAG="v${BUILD_NAME}"
        info "Creating draft GitHub release ${TAG}…"
        # Extract to a file first — with `--notes-file <(...)` the
        # process substitution's exit status is discarded, so a
        # release_notes.py failure would create a release with
        # silently empty notes.
        NOTES_FILE="$(mktemp)"
        python3 "$REPO_ROOT/scripts/release_notes.py" \
          extract "$BUILD_NAME" > "$NOTES_FILE" \
          || die "release_notes.py extract $BUILD_NAME failed"
        gh release create "$TAG" \
          --draft \
          --title "${APP_NAME} ${BUILD_NAME}" \
          --notes-file "$NOTES_FILE" \
          --target "$(git rev-parse HEAD)" \
          "$DMG_PATH"
        rm -f "$NOTES_FILE"
        echo ""
        echo "Draft release created. Verify the DMG, then publish:"
        echo "    git push origin ${TAG}"
        echo "    gh release edit ${TAG} --draft=false"
      else
        info "Skipping GitHub release (pre-release / dirty build)."
      fi
    fi
    ;;

  reset-prefs)
    # Sandboxed path (release / open .app)
    PREFS_SANDBOXED="$HOME/Library/Containers/com.eclipsa.studio/Data/Library/Application Support/com.eclipsa.studio"
    # Non-sandboxed path (flutter run debug)
    PREFS_DEBUG="$HOME/Library/Application Support/com.eclipsa.studio"
    FOUND=false
    for dir in "$PREFS_SANDBOXED" "$PREFS_DEBUG"; do
      for name in preferences.json recent_sessions.json recent_qc_files.json; do
        if [ -f "$dir/$name" ]; then
          rm "$dir/$name"
          echo "✓ Deleted $dir/$name"
          FOUND=true
        fi
      done
    done
    $FOUND || echo "No preferences or recents files found"
    ;;

  *)
    echo "Usage: ./build.sh <command> [flags]"
    echo ""
    echo "Commands:"
    echo "  lint                         Run clang-format + clang-tidy + dart format"
    echo "  lint --check                 Verify formatting only — CI gate, no writes"
    echo "  gen-version                  Stamp version.dart + engine_version.h (no build)"
    echo "  gen-tokens                   Regenerate theme_tokens.dart from app/design/tokens/"
    echo "  gen-tokens --check           Verify theme_tokens.dart is current — CI gate"
    echo "  gen-components               Regenerate component_index.dart from app/design/components.json"
    echo "  gen-components --check       Verify component_index.dart is current — CI gate"
    echo "  engine                       Build the C++ engine dylib (optimized)"
    echo "  clean                        Clean build and re-fetch dependencies"
    echo "  clean --deep                 ... + wipe Pods, bazel disk cache, ~/.pub-cache"
    echo "  run                          Build engine + run (debug, no lint)"
    echo "  run release                  ... release mode + lint"
    echo "  run fresh                    ... + reset prefs and recents first"
    echo "  run release fresh            ... release + reset prefs and recents"
    echo "  test-session [path]          Build + run with test session"
    echo "  test-iamf [path]             Build + run, auto-open an IAMF for QC (release)"
    echo "  package                      Build, sign, notarize (version from git tag)"
    echo "  package --no-notarize        Build, sign (skip notarize)"
    echo "  package upload               ... + upload to Google Drive"
    echo "  package gh-release           ... + draft GitHub release (DMG + notes)"
    echo "  package --no-notarize upload ... + upload (skip notarize)"
    echo "  package --allow-dirty        Allow off-tag / dirty pre-release DMG"
    echo "  reset-prefs                  Delete saved preferences and recent files"
    echo ""
    echo "Flags:"
    echo "  --no-lint                    Skip clang-format/clang-tidy/dart format (release only)"
    echo "  --allow-dirty                Allow packaging off a tag or with a dirty tree"
    echo ""
    echo "Releasing:"
    echo "  Tag is source of truth. To release:"
    echo "    git tag -a v0.2.0 -m 'Release 0.2.0' && ./build.sh package"
    exit 1
    ;;
esac
