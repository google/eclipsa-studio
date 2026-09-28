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

# Build a clean, dynamically-linkable libgpac.dll for the engine's MP4 muxer
# (engine/iamf/iamf_muxer.cc) and vendor it into this directory. Windows
# counterpart of build_gpac.sh; run from anywhere.
#
# Same "clean" posture as macOS: GPAC is configured with
# `--static-bin --use-curl=no`, which disables every external library that
# isn't statically linkable -- so the resulting library carries NO FFmpeg /
# curl / OpenSSL dependency (verified below with `dumpbin /dependents`).
# That keeps our "no FFmpeg for IAMF" rule intact and matches how
# google/eclipsa-audio-plugin vendors GPAC.
#
# Toolchains used:
#   * MSYS2 / mingw-w64 (bash + gcc + make) -- clones and compiles GPAC the
#     same way the macOS recipe does, then links the static archive into a
#     self-contained libgpac.dll (all symbols force-exported) and emits a
#     module-definition (.def) file.
#   * MSVC lib.exe -- synthesizes the import library (gpac.lib) the engine
#     links against, because the engine itself is built with MSVC and cannot
#     consume a MinGW-format import lib. lib.exe/dumpbin are located via
#     vswhere; the same VS install that Bazel uses for the engine.
#
# Outputs (git-ignored -- produced here, not checked in):
#   lib/libgpac.dll          the dynamic library the engine loads at runtime
#   lib/gpac.lib             the MSVC import library the engine links against
#   include/gpac/*.h         the public GPAC headers
#
# NOTE: this recipe has not been run through CI yet (ES-209/ES-259). The set of
# Windows system libraries the DLL link needs (see $SysLibs below) and the
# MSYS2 package list are the most likely knobs to adjust on first run.

$ErrorActionPreference = "Stop"

# Pin point -- the commit this muxer was developed and verified against.
# Keep in lockstep with build_gpac.sh and third_party/gpac/NOTICE.
# Includes gpac/gpac#3669 (IAMF samples flushed as SAP 1), which stops
# the muxer emitting an empty stss box in the IAMF track -- forbidden by
# IAMF-in-ISOBMFF 6.2.5 and flagged by ComplianceWarden.
$GpacCommit = "9edee648038ff542530b7a9f0392801ae88ea915"  # GPAC 26.08-DEV, 2026-09-17

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
         "mingw-w64-x86_64-toolchain mingw-w64-x86_64-zlib`n" +
         "Set MSYS2_ROOT if it isn't under C:\msys64.")
}
Write-Host "Using MSYS2 bash: $bash"

# --- Locate MSVC lib.exe / dumpbin.exe via vswhere ------------------------
# Find the tools directly (vswhere -find) and invoke them by full path rather
# than sourcing VsDevCmd.bat: lib/dumpbin need no INCLUDE/LIB env for
# /def and /dependents, their sibling DLLs load from their own dir, and
# VsDevCmd.bat spuriously prints "'vswhere.exe' is not recognized" when the
# Installer dir isn't on PATH.
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

# --- Build GPAC + link the DLL under MSYS2 --------------------------------
# Everything unix-y happens in one bash invocation; PowerShell handles only
# the MSVC import-lib + verification afterwards. The heredoc is single-quoted
# (no PowerShell interpolation); __GPAC_DIR__ and __GPAC_COMMIT__ are
# substituted below.
$bashScript = @'
set -euo pipefail

GPAC_COMMIT="__GPAC_COMMIT__"
HERE="__GPAC_DIR__"

# System libraries GPAC's ISOBMFF/filter core needs on Windows. Mirrors the
# framework list in build_gpac.sh. zlib is force-statically linked (there is
# no system zlib on Windows, so linking it dynamically would drag a separate
# zlib1.dll along at runtime); everything else is a Windows system DLL.
# Adjust here if the link reports unresolved externals on first run.
SYS_LIBS="-Wl,-Bstatic -lz -Wl,-Bdynamic -lws2_32 -lwinmm -liphlpapi -lole32 -loleaut32 -luser32 -lgdi32 -ladvapi32 -lshell32 -lopengl32"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Cloning gpac @ ${GPAC_COMMIT} ..."
# LF checkout: MSYS2 git defaults to core.autocrlf=true, which writes CRLF
# and stops the LF patches in patches/ from applying.
git clone -c core.autocrlf=false https://github.com/gpac/gpac.git "$work/gpac"
git -C "$work/gpac" checkout --quiet "$GPAC_COMMIT"

# Local fixes on top of the pin, one .patch per fix (see patches/README.md).
# `git apply` fails the build if a patch no longer fits the pinned source.
# The existence test skips the unmatched glob when patches/ is empty. The
# CR strip covers a checkout of this repo that converted a patch to CRLF;
# .gitattributes keeps the patches as stored, but a clone made before that
# rule was added keeps its CRLF copy.
for patch in "$HERE"/patches/*.patch; do
  [ -e "$patch" ] || continue
  echo "Applying $(basename "$patch") ..."
  sed 's/\r$//' "$patch" | git -C "$work/gpac" apply --verbose
done

echo "Configuring (static-bin, no curl/ffmpeg) ..."
( cd "$work/gpac" && ./configure --static-bin --use-curl=no --prefix="$work/install" )

echo "Building ..."
make -C "$work/gpac" -j"$(nproc)"
make -C "$work/gpac" install-lib   # installs the public headers

mkdir -p "$HERE/lib" "$HERE/include"

# --static-bin emits only libgpac_static.a; wrap it into a self-contained
# DLL with every gpac symbol force-exported (mirrors the macOS -force_load
# dylib link), and emit a .def so MSVC can build a matching import lib.
static_lib="$(find "$work/gpac/bin" -name 'libgpac_static.a' | head -n1)"
if [ -z "$static_lib" ]; then
  echo "ERROR: libgpac_static.a not found under $work/gpac/bin" >&2
  exit 1
fi
echo "Linking libgpac.dll from $static_lib ..."
gcc -shared -static-libgcc \
  -o "$HERE/lib/libgpac.dll" \
  -Wl,--whole-archive "$static_lib" -Wl,--no-whole-archive \
  -Wl,--export-all-symbols \
  -Wl,--output-def,"$HERE/lib/libgpac.def" \
  -Wl,--out-implib,"$HERE/lib/libgpac.dll.a" \
  $SYS_LIBS

rm -rf "$HERE/include/gpac"
cp -R "$work/install/include/gpac" "$HERE/include/gpac"

# GPAC's setup.h unconditionally does `#define snprintf _snprintf` on its
# Windows desktop path. That legacy hack is unnecessary on modern MSVC
# (VS2015+ ships a conformant snprintf) and actively breaks C++ consumers
# that call std::snprintf (the token gets rewritten to std::_snprintf). The
# engine is MSVC-built and includes these headers, so guard the redefinition
# to pre-1900 MSVC. Patch the vendored copy (a build output we own), not the
# consuming sources, so every GPAC consumer is fixed at once.
sed -i 's/^#define snprintf _snprintf$/#if !defined(_MSC_VER) || _MSC_VER < 1900\n#define snprintf _snprintf\n#endif/' "$HERE/include/gpac/setup.h"

echo "MinGW link done."
'@

$bashScript = $bashScript.Replace('__GPAC_COMMIT__', $GpacCommit).Replace('__GPAC_DIR__', $HereMsys)

# Hand the script to MSYS2's MINGW64 login shell (sets up /mingw64 on PATH).
$env:MSYSTEM = "MINGW64"
$env:CHERE_INVOKING = "1"
$tmpSh = Join-Path $env:TEMP "build_gpac_win.sh"
# Write LF-only so bash doesn't choke on CRLF.
[System.IO.File]::WriteAllText($tmpSh, ($bashScript -replace "`r`n", "`n"))
$tmpShMsys = "/" + $tmpSh.Substring(0, 1).ToLower() + ($tmpSh.Substring(2) -replace '\\', '/')
try {
    & $bash -l $tmpShMsys
    if ($LASTEXITCODE -ne 0) { Die "MSYS2 GPAC build failed (exit=$LASTEXITCODE)" }
} finally {
    Remove-Item $tmpSh -ErrorAction SilentlyContinue
}

# --- Synthesize the MSVC import library from the .def ---------------------
$def = Join-Path $Here "lib\libgpac.def"
$imp = Join-Path $Here "lib\gpac.lib"
$dll = Join-Path $Here "lib\libgpac.dll"
if (-not (Test-Path $def)) { Die "module-definition file not produced: $def" }
Write-Host "Building MSVC import library gpac.lib ..."
& $libExe /nologo /def:"$def" /machine:x64 /name:libgpac.dll /out:"$imp"
if ($LASTEXITCODE -ne 0) { Die "lib.exe failed (exit=$LASTEXITCODE)" }
if (-not (Test-Path $imp)) { Die "import library not produced: $imp" }

# --- Verify the DLL is FFmpeg / curl / OpenSSL free -----------------------
# Also fail closed if dumpbin produced nothing (the check must actually run,
# not vacuously pass). zlib is statically linked in, so the only expected
# imports are Windows system DLLs.
Write-Host "Verifying the library is FFmpeg/curl-free ..."
$deps = & $dumpbinExe /nologo /dependents "$dll" 2>&1
if ($LASTEXITCODE -ne 0 -or -not ($deps -match '\.dll')) {
    $deps | Write-Host
    Die "dumpbin /dependents did not report the DLL's imports -- cannot verify."
}
$forbidden = $deps | Select-String -Pattern 'ffmpeg|avcodec|avformat|avutil|libcurl|libssl|libcrypto|zlib1' -Quiet
if ($forbidden) {
    $deps | Write-Host
    Die "libgpac.dll pulled in a forbidden dependency (FFmpeg/curl/OpenSSL/zlib1)."
}

$dllSize = "{0:N1} MB" -f ((Get-Item $dll).Length / 1MB)
$hdrCount = (Get-ChildItem (Join-Path $Here "include\gpac") -Filter *.h).Count
Write-Host ""
Write-Host "Done:"
Write-Host "  $dll  ($dllSize)"
Write-Host "  $imp"
Write-Host "  $(Join-Path $Here 'include\gpac')\  ($hdrCount headers)"
