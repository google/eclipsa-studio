<#
 Copyright 2026 Google LLC

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
#>

# Build a pinned, minimal LGPL FFmpeg (video decode) plus dav1d for the
# FFmpeg-in-engine video backend (engine/video, issue ES-249) and vendor it into
# this directory. Windows counterpart of build_ffmpeg.sh; run from anywhere.
#
# Same "minimal LGPL" posture as macOS: configured without --enable-gpl /
# --enable-nonfree with encoders, muxers, programs, filters, avdevice and
# networking dropped -- a decode-only build carrying no GPL code, so we can
# ship the DLLs. All native LGPL decoders/demuxers/parsers stay enabled, plus
# libdav1d (BSD-2) for AV1 and D3D11VA/DXVA2 for hardware decode (the Windows
# analogue of VideoToolbox on macOS). Everything is linked DYNAMICALLY and
# staged beside eclipsa_studio_engine.dll (build.ps1 Build-Engine), mirroring how
# libgpac is vendored (build_gpac.ps1).
#
# Toolchains used (identical split to build_gpac.ps1):
#   * MSYS2 / mingw-w64 (bash + gcc + make + nasm + meson/ninja) -- clones and
#     compiles dav1d and FFmpeg the same way the macOS recipe does, producing
#     the shared DLLs and the public headers.
#   * MSVC lib.exe -- synthesizes the import libraries (avcodec.lib, ...) the
#     engine links against, because the engine itself is built with MSVC and
#     cannot consume MinGW-format import libs (.dll.a). Each import lib is
#     generated from the DLL's own export table (dumpbin /exports -> .def ->
#     lib /def) and given a STABLE, unversioned name so engine BUILD.bazel can
#     reference it even though the DLLs themselves carry FFmpeg's version
#     suffix (avcodec-62.dll etc.). lib/dumpbin are located via vswhere.
#
# Outputs (git-ignored -- produced here, not checked in):
#   lib/avcodec-*.dll lib/avformat-*.dll lib/avutil-*.dll
#   lib/swscale-*.dll lib/swresample-*.dll lib/libdav1d.dll   (runtime DLLs)
#   lib/avcodec.lib lib/avformat.lib lib/avutil.lib
#   lib/swscale.lib lib/swresample.lib                        (MSVC import libs)
#   include/            the public FFmpeg headers (libav*/, libsw*/)
#
# NOTE: like build_gpac.ps1 this recipe has not been through CI yet. The MSYS2
# package list, the FFmpeg version suffixes, and the set of Windows system libs
# the DLLs pull in are the most likely knobs to adjust on first run. Delete
# engine/deps/ffmpeg/lib to force a rebuild by hand.

$ErrorActionPreference = "Stop"

# ── Pin points (keep in lockstep with build_ffmpeg.sh and third_party/ffmpeg/NOTICE) ──
$FfmpegTag = "n8.0"    # FFmpeg 8.0 release tag
$Dav1dTag  = "1.5.1"   # dav1d 1.5.1 release tag

# The av* libraries we generate MSVC import libs for (avutil first). dav1d is
# shipped as a runtime DLL only -- avcodec imports it, the engine never links
# it directly -- so it needs no import lib. Mirrors build_ffmpeg.sh FFMPEG_LIBS.
$FfmpegLibs = @("avutil", "avcodec", "avformat", "swscale", "swresample")

$Here = $PSScriptRoot

function Die($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

# --- Locate MSYS2 bash ----------------------------------------------------
# Honour $env:MSYS2_ROOT if set, else probe the usual install locations.
$bash = $null
$roots = @()
if ($env:MSYS2_ROOT) { $roots += $env:MSYS2_ROOT }
$roots += @("C:\msys64", "C:\tools\msys64", "$env:SystemDrive\msys64")
foreach ($r in $roots) {
    $candidate = Join-Path $r "usr\bin\bash.exe"
    if (Test-Path $candidate) { $bash = $candidate; break }
}
if (-not $bash) {
    Die ("MSYS2 bash not found. Install MSYS2 (https://www.msys2.org), then " +
         "in an MSYS2 MINGW64 shell run:`n" +
         "  pacman -S --needed base-devel git make " +
         "mingw-w64-x86_64-toolchain mingw-w64-x86_64-nasm " +
         "mingw-w64-x86_64-meson mingw-w64-x86_64-ninja " +
         "mingw-w64-x86_64-pkgconf mingw-w64-x86_64-zlib`n" +
         "Set MSYS2_ROOT if it isn't under C:\msys64.")
}
Write-Host "Using MSYS2 bash: $bash"

# --- Locate MSVC lib.exe / dumpbin.exe via vswhere ------------------------
# Same approach as build_gpac.ps1: find the tools directly and invoke them by
# full path rather than sourcing VsDevCmd.bat (lib/dumpbin need no INCLUDE/LIB
# env for /def and /exports).
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Die "vswhere.exe not found -- is Visual Studio (the C++ toolset) installed?"
}
function Find-VsTool($name) {
    $hit = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find "VC\Tools\MSVC\**\bin\Hostx64\x64\$name" | Select-Object -First 1
    if (-not $hit) { Die "$name not found -- is the VS C++ (VC) toolset installed?" }
    return $hit
}
$libExe     = Find-VsTool "lib.exe"
$dumpbinExe = Find-VsTool "dumpbin.exe"
Write-Host "Using MSVC lib.exe:  $libExe"
Write-Host "Using MSVC dumpbin:  $dumpbinExe"

# --- Convert the target dir to an MSYS path (D:\a\b -> /d/a/b) -------------
$drive = $Here.Substring(0, 1).ToLower()
$rest  = $Here.Substring(2) -replace '\\', '/'
$HereMsys = "/$drive$rest"

# --- Build dav1d + FFmpeg under MSYS2 -------------------------------------
# Everything unix-y happens in one bash invocation (dav1d via meson, FFmpeg via
# configure) exactly as build_ffmpeg.sh does; PowerShell handles only the MSVC
# import libs + verification afterwards. The heredoc is single-quoted (no
# PowerShell interpolation); __FFMPEG_TAG__ / __DAV1D_TAG__ / __FF_DIR__ are
# substituted below.
$bashScript = @'
set -euo pipefail

FFMPEG_TAG="__FFMPEG_TAG__"
DAV1D_TAG="__DAV1D_TAG__"
HERE="__FF_DIR__"

# Ensure the MSYS2/mingw-w64 build tools are present, installing them on demand
# (mirrors build_ffmpeg.sh's brew install of nasm/meson/ninja/pkg-config). Only
# touches pacman when something is missing, so a warm runner pays nothing.
need_pkgs=()
command -v nasm  >/dev/null 2>&1 || need_pkgs+=(mingw-w64-x86_64-nasm)
command -v meson >/dev/null 2>&1 || need_pkgs+=(mingw-w64-x86_64-meson)
command -v ninja >/dev/null 2>&1 || need_pkgs+=(mingw-w64-x86_64-ninja)
command -v pkgconf >/dev/null 2>&1 || command -v pkg-config >/dev/null 2>&1 || \
  need_pkgs+=(mingw-w64-x86_64-pkgconf)
if [ ${#need_pkgs[@]} -gt 0 ]; then
  echo "Installing MSYS2 build tools: ${need_pkgs[*]} ..."
  # -Sy refreshes the package DBs first so --needed doesn't reference a stale
  # version the mirror has since dropped.
  pacman -Sy --noconfirm --disable-download-timeout >/dev/null
  pacman -S --needed --noconfirm --disable-download-timeout "${need_pkgs[@]}"
fi
for tool in nasm meson ninja; do
  command -v "$tool" >/dev/null 2>&1 || \
    { echo "ERROR: $tool still missing after pacman install" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
prefix="$work/install"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

# ── dav1d (BSD-2-Clause) — fast AV1 decoder ──────────────────────────────
echo "Cloning dav1d ${DAV1D_TAG} ..."
git clone --quiet --depth 1 --branch "$DAV1D_TAG" \
  https://code.videolan.org/videolan/dav1d.git "$work/dav1d"
echo "Building dav1d ..."
meson setup "$work/dav1d/build" "$work/dav1d" \
  --prefix="$prefix" --libdir=lib --buildtype=release \
  --default-library=shared \
  -Denable_tools=false -Denable_tests=false >/dev/null
ninja -C "$work/dav1d/build" install >/dev/null

# ── FFmpeg (LGPL-2.1) — decode only, D3D11VA/DXVA2 HW ────────────────────
echo "Cloning ffmpeg ${FFMPEG_TAG} ..."
git clone --quiet --depth 1 --branch "$FFMPEG_TAG" \
  https://github.com/FFmpeg/FFmpeg.git "$work/ffmpeg"
echo "Configuring ffmpeg (LGPL, decode-only, d3d11va/dxva2) ..."
# GPL / nonfree are OFF by default. --target-os=mingw32 + --arch=x86_64 target
# native Windows DLLs. --enable-w32threads + -static-libgcc drop libgcc_s, but
# MSYS2's POSIX-threads gcc still links libwinpthread-1.dll — that one is bundled
# into lib/ at the staging step below (redistributable) rather than fought. zlib
# is disabled to avoid dragging zlib1.dll along (reference video containers don't
# need it) — this diverges from macOS's --enable-zlib on purpose.
(
  cd "$work/ffmpeg" && ./configure \
    --prefix="$prefix" \
    --arch=x86_64 --target-os=mingw32 --enable-w32threads \
    --disable-static --enable-shared \
    --disable-programs --disable-doc \
    --disable-avdevice --disable-avfilter \
    --disable-encoders --disable-muxers \
    --disable-network \
    --disable-autodetect \
    --disable-zlib \
    --enable-libdav1d \
    --enable-d3d11va --enable-dxva2 \
    --extra-cflags="-I${prefix}/include" \
    --extra-ldflags="-L${prefix}/lib -static-libgcc"
)
echo "Building ffmpeg ..."
make -C "$work/ffmpeg" -j"$(nproc)" >/dev/null
make -C "$work/ffmpeg" install >/dev/null

# ── Stage the runtime DLLs + headers ─────────────────────────────────────
# FFmpeg installs DLLs to $prefix/bin on Windows; meson puts libdav1d.dll there
# too. Copy every produced DLL (version suffixes and all) into lib/.
echo "Staging DLLs + headers ..."
mkdir -p "$HERE/lib" "$HERE/include"
rm -f "$HERE/lib"/*.dll "$HERE/lib"/*.lib "$HERE/lib"/*.def
cp "$prefix/bin/"*.dll "$HERE/lib/"

# Bundle the mingw-w64 runtime DLLs our libraries pull in. MSYS2's gcc uses the
# POSIX threads model, so libwinpthread-1.dll is linked even with w32threads;
# rather than fight the linker, ship it (permissively licensed, redistributable)
# so the set is self-contained on a clean Windows box. `objdump -p` lists each
# DLL's import names; copy the ones that exist under /mingw64/bin (Windows
# system DLLs like KERNEL32.dll aren't there, so they're skipped). ffi_bridge
# preloads them alongside the av* DLLs.
#
# Collected via a temp file with defensive if-tests (not a `... | while` +
# `&&`-chain) so a stray line or missing path can't trip set -e / pipefail and
# SIGPIPE the pipeline.
deps_file="$work/mingw_deps.txt"
: > "$deps_file"
for dll in "$HERE/lib"/*.dll; do
  objdump -p "$dll" 2>/dev/null | awk '/DLL Name:/{print $3}' >> "$deps_file" || true
done
sort -u "$deps_file" > "$deps_file.u" || true
while IFS= read -r name; do
  src="/mingw64/bin/$name"
  if [ -n "$name" ] && [ -f "$src" ]; then
    cp -n "$src" "$HERE/lib/" || true
  fi
done < "$deps_file.u"

rm -rf "$HERE/include"/*
cp -R "$prefix/include/." "$HERE/include/"

echo "MinGW build done. DLLs in $HERE/lib:"
ls -1 "$HERE/lib"/*.dll
'@

$bashScript = $bashScript.
    Replace('__FFMPEG_TAG__', $FfmpegTag).
    Replace('__DAV1D_TAG__', $Dav1dTag).
    Replace('__FF_DIR__', $HereMsys)

# Hand the script to MSYS2's MINGW64 login shell (sets up /mingw64 on PATH).
$env:MSYSTEM = "MINGW64"
$env:CHERE_INVOKING = "1"
$tmpSh = Join-Path $env:TEMP "build_ffmpeg_win.sh"
# Write LF-only so bash doesn't choke on CRLF.
[System.IO.File]::WriteAllText($tmpSh, ($bashScript -replace "`r`n", "`n"))
$tmpShMsys = "/" + $tmpSh.Substring(0, 1).ToLower() + ($tmpSh.Substring(2) -replace '\\', '/')
try {
    & $bash -l $tmpShMsys
    if ($LASTEXITCODE -ne 0) { Die "MSYS2 FFmpeg build failed (exit=$LASTEXITCODE)" }
} finally {
    Remove-Item $tmpSh -ErrorAction SilentlyContinue
}

# --- Synthesize MSVC import libraries from the DLL export tables ----------
# The engine is MSVC-built and cannot link MinGW's .dll.a import libs, so build
# a proper .lib for each av* DLL from its own exports: dumpbin /exports -> .def
# -> lib /def. The .lib file gets a stable, unversioned name (avcodec.lib) that
# engine BUILD.bazel references, while /name: bakes in the real versioned DLL
# (avcodec-62.dll) the loader must find at runtime.
foreach ($lib in $FfmpegLibs) {
    $dll = Get-ChildItem (Join-Path $Here "lib") -Filter "$lib-*.dll" `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { Die "expected DLL lib\$lib-*.dll not produced by the FFmpeg build" }
    $dllName = $dll.Name
    $def = Join-Path $Here "lib\$lib.def"
    $imp = Join-Path $Here "lib\$lib.lib"

    # dumpbin /exports lists one export per line as:  ordinal  hint  RVA  name
    # Keep only the trailing symbol name from lines that start with a numeric
    # ordinal; that drops the header/summary lines.
    $exports = & $dumpbinExe /nologo /exports $dll.FullName
    $names = foreach ($line in $exports) {
        if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') {
            $matches[1]
        }
    }
    if (-not $names -or $names.Count -eq 0) {
        Die "no exports parsed from $dllName -- dumpbin output format changed?"
    }
    $defLines = @("LIBRARY $dllName", "EXPORTS") + ($names | ForEach-Object { "    $_" })
    Set-Content -Path $def -Value $defLines -Encoding ascii

    & $libExe /nologo /def:"$def" /machine:x64 /name:"$dllName" /out:"$imp"
    if ($LASTEXITCODE -ne 0) { Die "lib.exe failed for $lib (exit=$LASTEXITCODE)" }
    if (-not (Test-Path $imp)) { Die "import library not produced: $imp" }
    Write-Host "  $lib.lib  ->  $dllName  ($($names.Count) exports)"
}

# --- Verify the DLL set is self-contained on a clean Windows box ----------
# Every dependency must be either a Windows system DLL or one we ship in lib/
# (the av*/dav1d DLLs plus the bundled mingw runtime, e.g. libwinpthread-1.dll).
# A msys-2.0.dll dependency is always wrong (it means the build leaked the MSYS
# base runtime — wrong shell); any other non-system DLL that ISN'T in lib/ would
# fail to load. Fail closed (also fail if dumpbin produced nothing).
$staged = @{}
foreach ($f in (Get-ChildItem (Join-Path $Here "lib") -Filter *.dll)) {
    $staged[$f.Name.ToLower()] = $true
}
Write-Host "Verifying the DLL set is self-contained ..."
foreach ($dll in (Get-ChildItem (Join-Path $Here "lib") -Filter *.dll)) {
    $deps = & $dumpbinExe /nologo /dependents $dll.FullName 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($deps -match '\.dll')) {
        $deps | Write-Host
        Die "dumpbin /dependents did not report $($dll.Name)'s imports -- cannot verify."
    }
    if ($deps | Select-String -Pattern 'msys-2\.0\.dll' -Quiet) {
        $deps | Write-Host
        Die "$($dll.Name) links msys-2.0.dll -- built in the wrong (MSYS, not MINGW64) shell."
    }
    # Any mingw runtime dep (libwinpthread / libgcc_s / libstdc++ / libssp ...)
    # must have been bundled into lib/ by the ldd copy above.
    $mingwDeps = $deps | Select-String -Pattern '^\s+(lib\S+\.dll)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
    foreach ($dep in $mingwDeps) {
        if (-not $staged.ContainsKey($dep.ToLower())) {
            $deps | Write-Host
            Die "$($dll.Name) needs $dep, which was not bundled into lib/."
        }
    }
}

$dllCount = (Get-ChildItem (Join-Path $Here "lib") -Filter *.dll).Count
$hdrCount = (Get-ChildItem (Join-Path $Here "include") -Recurse -Filter *.h).Count
Write-Host ""
Write-Host "Done:"
Write-Host "  $(Join-Path $Here 'lib')\  ($dllCount DLLs + $($FfmpegLibs.Count) import libs)"
Write-Host "  $(Join-Path $Here 'include')\  ($hdrCount headers)"
