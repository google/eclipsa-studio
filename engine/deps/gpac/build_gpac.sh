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

# Build a clean, dynamically-linkable libgpac for the engine's MP4 muxer
# (engine/iamf/iamf_muxer.cc) and vendor it into this directory.
#
# "Clean" = configured with --static-bin --use-curl=no, which disables
# every external library that isn't statically linkable — so the resulting
# library carries NO FFmpeg / curl / OpenSSL dependency (verify with
# `otool -L lib/libgpac.dylib`: only Apple system frameworks + libSystem).
# That keeps our "no FFmpeg for IAMF" rule intact and matches how
# google/eclipsa-audio-plugin vendors GPAC.
#
# Outputs (git-ignored — produced here, not checked in):
#   lib/libgpac.dylib        the dynamic library the engine links against
#   include/gpac/*.h         the public GPAC headers
#
# macOS only for now; the Windows .dll is built separately (see README.md).
set -euo pipefail

# Pin point — the commit this muxer is verified against (master when
# last bumped). Includes gpac/gpac#3669 (IAMF samples flushed as SAP 1),
# which stops the muxer emitting an empty stss box in the IAMF track —
# forbidden by IAMF-in-ISOBMFF §6.2.5 and flagged by ComplianceWarden.
GPAC_COMMIT="9edee648038ff542530b7a9f0392801ae88ea915"  # GPAC 26.08-DEV, 2026-09-17

# Match the engine's deployment target so the dylib links without a
# version-mismatch warning (--macos_minimum_os in engine/.bazelrc).
MIN_MACOS="12.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Cloning gpac @ ${GPAC_COMMIT} …"
git clone https://github.com/gpac/gpac.git "$work/gpac"
git -C "$work/gpac" checkout --quiet "$GPAC_COMMIT"

# Local fixes on top of the pin, one .patch per fix (see patches/README.md
# for what each one changes and its upstream status). Applied with
# `git apply` so a patch that no longer fits the pinned source fails the
# build instead of silently building without it.
# The existence test skips the unmatched glob when patches/ is empty. The
# CR strip covers a checkout that converted a patch to CRLF.
for patch in "$here"/patches/*.patch; do
  [ -e "$patch" ] || continue
  echo "Applying $(basename "$patch") …"
  sed 's/\r$//' "$patch" | git -C "$work/gpac" apply --verbose
done

echo "Configuring (static-bin, no curl/ffmpeg) …"
# Force-disable optional system libraries GPAC would otherwise auto-detect
# via pkg-config (e.g. Homebrew's freetype / libpng / nghttp2). The muxer
# needs none of them, and the hand-written dylib link below provides only
# Apple frameworks + libz/pthread/m — so any auto-linked dependency shows up
# as undefined symbols at link time. Disabling them keeps the build
# host-independent and the dylib self-contained (verified by otool below).
( cd "$work/gpac" && ./configure --static-bin --use-curl=no \
    --use-png=no --use-jpeg=no --use-freetype=no --use-nghttp2=no \
    --use-mad=no \
    --extra-cflags="-mmacosx-version-min=${MIN_MACOS}" \
    --prefix="$work/install" )

echo "Building …"
make -C "$work/gpac" -j"$(sysctl -n hw.ncpu)"
make -C "$work/gpac" install-lib  # installs the public headers

# --static-bin emits only libgpac_static.a; wrap it into a self-contained
# dynamic library (all gpac symbols force-loaded, system frameworks only).
echo "Linking libgpac.dylib …"
mkdir -p "$here/lib" "$here/include"
clang++ -dynamiclib -arch arm64 -install_name @rpath/libgpac.dylib \
  -mmacosx-version-min="${MIN_MACOS}" \
  -Wl,-force_load,"$work/gpac/bin/gcc/libgpac_static.a" \
  -framework CoreFoundation -framework CoreVideo -framework CoreMedia \
  -framework VideoToolbox -framework CoreServices -framework IOKit \
  -framework Security -framework AudioToolbox -framework OpenGL \
  -lz -lpthread -lm \
  -o "$here/lib/libgpac.dylib"

rm -rf "$here/include/gpac"
cp -R "$work/install/include/gpac" "$here/include/gpac"

echo "Verifying the library is FFmpeg/curl-free …"
if otool -L "$here/lib/libgpac.dylib" | grep -iE 'ffmpeg|avcodec|curl|ssl|freetype|libpng|nghttp'; then
  echo "ERROR: libgpac.dylib pulled in a forbidden dependency" >&2
  exit 1
fi

echo "Done:"
echo "  $here/lib/libgpac.dylib  ($(du -h "$here/lib/libgpac.dylib" | cut -f1))"
echo "  $here/include/gpac/      ($(ls "$here/include/gpac" | wc -l | tr -d ' ') headers)"
