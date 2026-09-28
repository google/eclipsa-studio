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

# Build a pinned, minimal LGPL FFmpeg (video decode) plus dav1d for the
# FFmpeg-in-engine video backend (engine/video, issue ES-249) and vendor it
# into this directory.
#
# "Minimal LGPL" = configured --disable-gpl --disable-nonfree with encoders,
# muxers, programs, filters, avdevice and networking dropped — a decode-only
# build carrying no GPL code, so we can ship the dylibs. All native LGPL
# decoders/demuxers/parsers stay enabled (robust across source formats), plus
# libdav1d (BSD-2) for fast AV1 and VideoToolbox for the planned HW-decode
# step. Everything is dynamically linked with @rpath install names and copied
# into the app bundle's Frameworks/ beside libgpac (see build.sh
# embed_engine_libs) — mirrors how GPAC is vendored (build_gpac.sh).
#
# Outputs (git-ignored — produced here, not checked in):
#   lib/libavutil.dylib lib/libavcodec.dylib lib/libavformat.dylib
#   lib/libswscale.dylib lib/libswresample.dylib lib/libdav1d.dylib
#   include/            the public FFmpeg headers (libav*/ , libsw*/)
#
# macOS/arm64 only for now; the Windows DLLs are a follow-up (see README.md).
set -euo pipefail

# ── Pin points ───────────────────────────────────────────────────────────
FFMPEG_TAG="n8.0"      # FFmpeg 8.0 release tag
DAV1D_TAG="1.5.1"      # dav1d 1.5.1 release tag

# Match the engine's deployment target (--macos_minimum_os in
# engine/.bazelrc) so the dylibs link without a version-mismatch warning.
MIN_MACOS="12.0"

# The av* libraries we ship, in dependency order (avutil first). dav1d is
# handled separately because FFmpeg links it in.
FFMPEG_LIBS=(avutil avcodec avformat swscale swresample)
ALL_LIBS=("${FFMPEG_LIBS[@]}" dav1d)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── Build tools ──────────────────────────────────────────────────────────
# nasm: FFmpeg + dav1d x86/arm SIMD. meson/ninja: dav1d build system.
# pkg-config: FFmpeg's --enable-libdav1d discovery.
missing=()
for tool in nasm meson ninja pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing build tools: ${missing[*]} …"
    brew install "${missing[@]}"
  else
    echo "ERROR: missing build tools: ${missing[*]} (brew install them)" >&2
    exit 1
  fi
fi

prefix="$work/install"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

# ── dav1d (BSD-2-Clause) — fast AV1 decoder ──────────────────────────────
echo "Cloning dav1d ${DAV1D_TAG} …"
git clone --quiet --depth 1 --branch "$DAV1D_TAG" \
  https://code.videolan.org/videolan/dav1d.git "$work/dav1d"
echo "Building dav1d …"
meson setup "$work/dav1d/build" "$work/dav1d" \
  --prefix="$prefix" --libdir=lib --buildtype=release \
  --default-library=shared \
  -Denable_tools=false -Denable_tests=false \
  -Dc_args="-mmacosx-version-min=${MIN_MACOS}" \
  -Dc_link_args="-mmacosx-version-min=${MIN_MACOS}" >/dev/null
ninja -C "$work/dav1d/build" install >/dev/null

# Point FFmpeg's link at a dav1d whose install name is already @rpath, so the
# resulting libavcodec records @rpath/libdav1d.dylib (canonicalized below).
dav1d_real="$(find "$prefix/lib" -maxdepth 1 -name 'libdav1d.*.dylib' \
  ! -type l | head -1)"
install_name_tool -id "@rpath/libdav1d.dylib" "$dav1d_real"

# ── FFmpeg (LGPL-2.1) — decode only ──────────────────────────────────────
echo "Cloning ffmpeg ${FFMPEG_TAG} …"
git clone --quiet --depth 1 --branch "$FFMPEG_TAG" \
  https://github.com/FFmpeg/FFmpeg.git "$work/ffmpeg"
echo "Configuring ffmpeg (LGPL, decode-only) …"
# GPL / nonfree are OFF by default (no --disable-gpl option exists), so simply
# not enabling them yields an LGPL-2.1 build. configure output is kept (not
# silenced) so a rejected option or missing dep is visible in the build log.
(
  cd "$work/ffmpeg" && ./configure \
    --prefix="$prefix" \
    --disable-static --enable-shared \
    --install-name-dir='@rpath' \
    --disable-programs --disable-doc \
    --disable-avdevice --disable-avfilter \
    --disable-encoders --disable-muxers \
    --disable-network \
    --disable-autodetect \
    --enable-zlib \
    --enable-libdav1d \
    --enable-videotoolbox \
    --extra-cflags="-mmacosx-version-min=${MIN_MACOS} -I${prefix}/include" \
    --extra-ldflags="-mmacosx-version-min=${MIN_MACOS} -L${prefix}/lib"
)
echo "Building ffmpeg …"
make -C "$work/ffmpeg" -j"$(sysctl -n hw.ncpu)" >/dev/null
make -C "$work/ffmpeg" install >/dev/null

# ── Stage: unversioned real dylibs with @rpath ids + deps ────────────────
# Copy each real (non-symlink) versioned dylib to an unversioned real file,
# then rewrite its id and every inter-lib dependency to @rpath/libNAME.dylib.
# That drops the version/symlink dance so cc_import and the bundle copy each
# reference one deterministic filename.
echo "Staging dylibs (@rpath, unversioned) …"
mkdir -p "$here/lib" "$here/include"
rm -f "$here/lib"/*.dylib
for lib in "${ALL_LIBS[@]}"; do
  src="$(find "$prefix/lib" -maxdepth 1 -name "lib${lib}.*.dylib" \
    ! -type l | head -1)"
  [[ -n "$src" ]] || { echo "ERROR: lib$lib not built" >&2; exit 1; }
  cp "$src" "$here/lib/lib${lib}.dylib"
done
for lib in "${ALL_LIBS[@]}"; do
  target="$here/lib/lib${lib}.dylib"
  install_name_tool -id "@rpath/lib${lib}.dylib" "$target"
  # Rewrite any dependency on one of our libs (versioned @rpath) to the
  # unversioned @rpath leaf we ship.
  while IFS= read -r dep; do
    base="$(basename "$dep")"   # e.g. libavcodec.62.dylib
    short="${base%%.*}"         # e.g. libavcodec
    install_name_tool -change "$dep" "@rpath/${short}.dylib" "$target"
  done < <(otool -L "$target" | awk '/@rpath\/lib(avutil|avcodec|avformat|swscale|swresample|dav1d)\.[0-9]/{print $1}')
done

# Public headers.
rm -rf "$here/include"/*
cp -R "$prefix/include/." "$here/include/"

# ── Verify: no forbidden (non-system, GPL, or absolute) dependency ───────
echo "Verifying dylibs carry only system + @rpath deps …"
for lib in "${ALL_LIBS[@]}"; do
  target="$here/lib/lib${lib}.dylib"
  if otool -L "$target" | tail -n +2 | \
     grep -vE '@rpath/|/usr/lib/|/System/' | grep -q .; then
    echo "ERROR: lib$lib pulled in a forbidden dependency:" >&2
    otool -L "$target" | tail -n +2 | \
      grep -vE '@rpath/|/usr/lib/|/System/' >&2
    exit 1
  fi
done

echo "Done:"
for lib in "${ALL_LIBS[@]}"; do
  f="$here/lib/lib${lib}.dylib"
  echo "  $f  ($(du -h "$f" | cut -f1))"
done
echo "  $here/include/  ($(find "$here/include" -name '*.h' | wc -l \
  | tr -d ' ') headers)"
