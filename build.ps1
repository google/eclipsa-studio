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

<#
.SYNOPSIS
    Build, run, and clean Eclipsa Studio on Windows.

.DESCRIPTION
    Windows counterpart to the macOS-only build.sh. Always invoke this
    from the repo root; never bare ``flutter run``.

    Commands:
      .\build.ps1 run                     # build engine + run (release + opt engine)
      .\build.ps1 run debug               # ... debug mode (fastbuild engine, hot reload)
      .\build.ps1 run fresh               # ... + reset prefs and recents first
      .\build.ps1 run debug fresh         # ... debug + reset prefs and recents
      .\build.ps1 test-session [path]     # build + run with a .esp session auto-loaded
      .\build.ps1 build                   # build engine + flutter build (release, no run)
      .\build.ps1 build debug             # ... debug mode
      .\build.ps1 package                 # release build + portable zip in dist\
      .\build.ps1 clean                   # flutter clean + bazel clean + pub get
      .\build.ps1 clean --deep            # ... + bazel expunge + wipe pub cache
      .\build.ps1 reset-prefs             # delete saved preferences and recents
      .\build.ps1 engine                  # just rebuild the C++ engine DLL
      .\build.ps1 lint                    # dart format + clang-format/clang-tidy (in place)
      .\build.ps1 lint --check            # verify formatting only (CI gate; no writes)

    Release is the default for run/build (mirrors build.sh): the
    fastbuild engine decodes IAMF slower than real-time (constant ring
    underruns -- ES-87/ES-90), so plain runs get an optimized (-c opt)
    engine. Use ``run debug`` for hot reload / engine debugging.
    Release runs build the bundle and launch runner.exe directly
    (no ``flutter run``), so the terminal returns when the app exits.

    `lint` runs dart format over the app and, when LLVM is on PATH,
    clang-format / clang-tidy over the engine (clang tools are skipped
    with a hint if absent). Unlike build.sh it is standalone -- release
    builds here do NOT auto-lint.

    `package` is, for now, a portable zip only: the pristine release
    bundle + engine DLLs + VC++ runtime staged beside the exe, zipped
    to dist\. Code signing and a proper installer are tracked in
    GitHub issue ES-279.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest = @()
)

$ErrorActionPreference = "Stop"

# -- Layout ---------------------------------------------------------------

$RepoRoot   = $PSScriptRoot
$EngineSrc  = Join-Path $RepoRoot   "engine"
$EngineOut  = Join-Path $EngineSrc  "build"
$FlutterDir = Join-Path $RepoRoot   "app"
$DllName    = "eclipsa_studio_engine.dll"

# Vendored libgpac (the MP4 muxer's LGPL dependency, linked dynamically).
# Windows needs the DLL (loaded at runtime) plus an MSVC import lib (linked
# against); both plus the headers are git-ignored build outputs produced by
# engine/deps/gpac/build_gpac.ps1. Mirrors build.sh's GPAC_* vars.
$GpacDir    = Join-Path $EngineSrc  "deps\gpac"
$GpacDll    = "libgpac.dll"
$GpacLib    = "gpac.lib"

# Vendored LGPL FFmpeg + dav1d (the FFmpeg-in-engine video backend's decode
# dependency, issue ES-249; linked dynamically). Like GPAC these are git-ignored
# build outputs produced by engine/deps/ffmpeg/build_ffmpeg.ps1: the
# version-suffixed runtime DLLs (avcodec-62.dll, ..., libdav1d.dll) plus stable
# MSVC import libs the engine links against. Staged beside eclipsa_studio_engine.dll.
$FfmpegDir  = Join-Path $EngineSrc  "deps\ffmpeg"

# path_provider's getApplicationSupportDirectory() on Windows resolves
# to %APPDATA%\<CompanyName>\<ProductName> from Runner.rc -- same path
# for debug and release (no sandbox container the way macOS has).
# CompanyName is "Eclipsa Studio" since 835028c, hence the doubled
# segment.
$PrefsDir   = Join-Path $env:APPDATA "Eclipsa Studio\Eclipsa Studio"
$PrefsFiles = @("preferences.json", "recent_sessions.json", "recent_qc_files.json")

# -- Helpers --------------------------------------------------------------

$script:Step = 0
function Info($msg) {
    $script:Step++
    Write-Host ""
    Write-Host "[$($script:Step)] $msg"
}

function Warn($msg) {
    Write-Host "WARNING: $msg" -ForegroundColor Yellow
}

function Die($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Require-Cmd($name, $hint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        if ($hint) { Die "$name not found in PATH -- $hint" }
        else       { Die "$name not found in PATH" }
    }
}

# Minimum Flutter version, taken from app\pubspec.yaml's `flutter:`
# environment constraint so the gate cannot drift from the constraint pub
# itself enforces. $null when no lower bound is declared.
function Get-RequiredFlutterVersion {
    $pubspec = Join-Path $FlutterDir "pubspec.yaml"
    if (-not (Test-Path $pubspec)) { return $null }
    $line = Get-Content $pubspec `
        | Select-String -Pattern '^\s*flutter:\s*["'']?[>^]=?\s*([0-9]+(\.[0-9]+)*)'
    if (-not $line) { return $null }
    return $line.Matches[0].Groups[1].Value
}

# Installed Flutter version, from `flutter --version --machine` (stable JSON)
# rather than the human banner. $null if it cannot be determined.
function Get-InstalledFlutterVersion {
    # Windows PowerShell 5.1 turns a native command's redirected stderr
    # into a terminating error under the script's "Stop" preference, so a
    # flutter notice on stderr would abort the build instead of taking the
    # warn path. Drop to Continue for the call, as the lint step does.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = (& flutter --version --machine 2>$null | Out-String)
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $brace = $raw.IndexOf('{')
    if ($brace -lt 0) { return $null }
    try { return ($raw.Substring($brace) | ConvertFrom-Json).frameworkVersion }
    catch { return $null }
}

# Fail before the engine build when the installed Flutter is older than the
# constraint. Without this, pub reports the mismatch only after Bazel has
# built the engine, which takes several minutes, and longer on a machine that
# has yet to vendor FFmpeg and GPAC. A pre-release (3.47.5-0.1.pre) counts as
# its release here, although pub orders it earlier; pub still rejects it.
#
# Only the lower bound is enforced: being ahead of the pinned version is the
# normal state right after `flutter upgrade`. An unreadable version warns
# rather than fails, leaving pub as the backstop; a build must not be blocked
# by an unexpected `--machine` payload.
function Require-FlutterVersion {
    Require-Cmd flutter "install from flutter.dev"
    $required = Get-RequiredFlutterVersion
    if (-not $required) { return }

    $installed = Get-InstalledFlutterVersion
    if (-not $installed) {
        Warn "could not read the Flutter version; skipping the version check"
        return
    }

    # A pre-release suffix (3.48.0-1.2.pre on beta) is dropped before
    # comparing: [version] cannot parse it.
    # [version] needs at least two fields: pad a bare major ("3" -> "3.0").
    $have = ($installed -split '-')[0]
    if ($have -notmatch '\.') { $have = "$have.0" }
    $need = $required
    if ($need -notmatch '\.') { $need = "$need.0" }
    if ([version]$have -lt [version]$need) {
        Die ("Flutter $installed is older than the $required required by " +
             "app\pubspec.yaml -- run 'flutter upgrade'")
    }
}

# Generate app/lib/generated/version.dart from the nearest v* tag, so
# the UI shows the correct version. On an exact clean tag -> "0.2.0";
# off-tag or dirty -> "0.2.0-dev". Falls back to pubspec.yaml's
# `version:` line when no v* tags exist (fresh clones / forks).
function Generate-VersionDart {
    Info "Generating lib/generated/version.dart..."
    Require-Cmd git

    # git describe via cmd /c so its stderr ("fatal: no names found" on
    # tag-less clones) never becomes a PS 5.1 NativeCommandError under
    # $ErrorActionPreference = Stop — the pubspec fallback below must
    # stay reachable.
    $ver = $null
    $describe = (cmd /c "git -C `"$RepoRoot`" describe --tags --match=v* --dirty 2>nul" | Out-String).Trim()

    if ($describe) {
        $nearest = (cmd /c "git -C `"$RepoRoot`" describe --tags --abbrev=0 --match=v* 2>nul" | Out-String).Trim()
        if ($describe -eq $nearest) {
            $ver = $nearest.TrimStart("v")
        } else {
            $ver = ($nearest.TrimStart("v")) + "-dev"
        }
    } else {
        $line = Get-Content (Join-Path $FlutterDir "pubspec.yaml") `
            | Select-String -Pattern '^version:' `
            | Select-Object -First 1
        $ver = ($line.ToString() -replace '^version:\s*', '' -replace '\+.*$', '').Trim()
    }

    $genDir = Join-Path $FlutterDir "lib\generated"
    if (-not (Test-Path $genDir)) {
        New-Item -ItemType Directory -Path $genDir | Out-Null
    }
    $body = @"
// Generated by build.ps1 - do not edit by hand.
const appVersion = '$ver';
"@
    Set-Content -Path (Join-Path $genDir "version.dart") -Value $body -Encoding utf8

    # Engine counterpart: engine\generated\engine_version.h so
    # eclipsa_studio_version() reports the same version as the app. Gitignored;
    # a bare `bazel build` without it falls back to "dev" (see the
    # __has_include block in engine\engine.cc).
    $engGenDir = Join-Path $EngineSrc "generated"
    if (-not (Test-Path $engGenDir)) {
        New-Item -ItemType Directory -Path $engGenDir | Out-Null
    }
    $hdr = @"
// Generated by build.ps1 - do not edit by hand.
#ifndef ECLIPSA_STUDIO_GENERATED_ENGINE_VERSION_H_
#define ECLIPSA_STUDIO_GENERATED_ENGINE_VERSION_H_
#define ECLIPSA_STUDIO_ENGINE_VERSION "$ver"
#endif  // ECLIPSA_STUDIO_GENERATED_ENGINE_VERSION_H_
"@
    Set-Content -Path (Join-Path $engGenDir "engine_version.h") -Value $hdr -Encoding ascii

    Write-Host "Version: v$ver"
}

# Generate app/assets/releases.json from RELEASES.md so the in-app
# What's New dialog (and any other release-aware UI) can render notes
# from a structured source. Pubspec lists assets/releases.json as a
# bundled asset, so this MUST exist before `flutter build` or it fails
# with "No file or variants found for asset: assets/releases.json".
function Generate-ReleasesJson {
    Info "Generating assets/releases.json..."
    Require-Cmd python "install Python 3 from python.org"
    $script = Join-Path $RepoRoot "scripts\release_notes.py"
    $outDir = Join-Path $FlutterDir "assets"
    $outFile = Join-Path $outDir "releases.json"
    if (-not (Test-Path $script)) {
        Write-Host "warning: $script not found; skipping releases.json"
        return
    }
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir | Out-Null
    }
    # NOTE: not Out-File -Encoding utf8 — in Windows PowerShell 5.1 that
    # writes a UTF-8 BOM, which Dart's jsonDecode rejects, so the
    # What's New dialog silently shows no notes. WriteAllText with an
    # explicit BOM-less UTF8Encoding matches build.sh's output.
    $json = & python $script json | Out-String
    if ($LASTEXITCODE -ne 0) {
        Die "release_notes.py json failed (exit=$LASTEXITCODE)"
    }
    [System.IO.File]::WriteAllText(
        $outFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Generated $outFile"
}

# DLL names in a PE file's import table. Pure PowerShell PE walk (no LLVM
# dependency on the machine): DOS header e_lfanew -> COFF/optional header ->
# data directory[1] -> import descriptors resolved through the section
# table. Returns @() for files with no import table.
function Get-PeImports($path) {
    $d = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($d, 0x3c)
    if ($d[$pe] -ne 0x50 -or $d[$pe + 1] -ne 0x45) { return @() }  # "PE"
    $nsec    = [BitConverter]::ToUInt16($d, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($d, $pe + 20)
    $opt     = $pe + 24
    $magic   = [BitConverter]::ToUInt16($d, $opt)   # 0x20b = PE32+
    $ddir    = $opt + $(if ($magic -eq 0x20b) { 0x70 } else { 0x60 })
    $impRva  = [BitConverter]::ToUInt32($d, $ddir + 8)
    if (-not $impRva) { return @() }
    $secs = @()
    $st = $opt + $optSize
    for ($i = 0; $i -lt $nsec; $i++) {
        $s     = $st + $i * 40
        $vsz   = [BitConverter]::ToUInt32($d, $s + 8)
        $va    = [BitConverter]::ToUInt32($d, $s + 12)
        $rawsz = [BitConverter]::ToUInt32($d, $s + 16)
        $raw   = [BitConverter]::ToUInt32($d, $s + 20)
        if (-not $vsz) { $vsz = $rawsz }
        $secs += , @($va, $vsz, $raw)
    }
    $rvaToOff = {
        param($rva)
        foreach ($s in $secs) {
            if ($rva -ge $s[0] -and $rva -lt ($s[0] + $s[1])) {
                return $s[2] + ($rva - $s[0])
            }
        }
        return $null
    }
    $names = @()
    for ($i = 0; ; $i++) {
        $e = (& $rvaToOff $impRva) + $i * 20
        $nameRva = [BitConverter]::ToUInt32($d, $e + 12)
        if (-not $nameRva) { break }
        $o = & $rvaToOff $nameRva
        $end = [Array]::IndexOf($d, [byte]0, $o)
        $names += [Text.Encoding]::ASCII.GetString($d, $o, $end - $o)
    }
    return $names
}

# Packaging gate (ES-372): the debug Microsoft CRT (ucrtbased.dll,
# msvcp140d.dll, vcruntime140d/140_1d.dll, vccorlib140d.dll) is NOT
# redistributable under the Visual Studio license — a package that ships
# it, or ships a binary that imports it, cannot be distributed. Scans
# every staged DLL/exe by file name AND import table so a debug binary
# sneaking in through any dependency fails the package loudly.
function Assert-NoDebugCrt($dir) {
    Info "Checking staged binaries for debug-CRT files and imports..."
    $debugRe = '(?i)^(ucrtbased|msvcp\d+d|vcruntime\d+(_\d+)?d|vccorlib\d+d)\.dll$'
    foreach ($bin in Get-ChildItem $dir -Recurse -Include "*.dll", "*.exe") {
        if ($bin.Name -match $debugRe) {
            Die "debug CRT DLL staged in the package: $($bin.Name) -- see ES-372"
        }
        $bad = @(Get-PeImports $bin.FullName | Where-Object { $_ -match $debugRe })
        if ($bad.Count) {
            Die ("$($bin.Name) imports the debug CRT ($($bad -join ', ')) -- " +
                 "a debug binary is staged; see ES-372")
        }
    }
    Write-Host "No debug-CRT files or imports in the staged package."
}

# Ensure the vendored libgpac (the MP4 muxer's LGPL dependency, linked
# dynamically) exists before Bazel tries to link against it. The DLL, its
# MSVC import lib and the headers are build outputs, not checked in (see
# engine/deps/gpac/README.md), and the engine's cc_import references
# them by path — so a clean checkout would fail the engine build without
# this. build_gpac.ps1 clones + compiles GPAC via MSYS2, which is slow, so
# skip it when the outputs are already present AND were produced by the
# current recipe. Mirrors build.sh's ensure_gpac.
#
# The freshness check stamps the outputs with a SHA-256 of build_gpac.ps1
# (lib\.build_id) and rebuilds when it's missing or stale. On a persistent
# runner (clean: false) this matters: without it, a copy vendored by an older
# recipe — e.g. before a header patch or link-flag fix landed — would be
# reused forever, silently shipping the stale library. Delete
# engine/deps/gpac/lib to force a rebuild by hand.
function Ensure-Gpac {
    $lib    = Join-Path $GpacDir "lib\$GpacDll"
    $imp    = Join-Path $GpacDir "lib\$GpacLib"
    $inc    = Join-Path $GpacDir "include\gpac"
    $stamp  = Join-Path $GpacDir "lib\.build_id"
    $recipe = Join-Path $GpacDir "build_gpac.ps1"
    # Recipe plus every patch it applies, so a patch-only change rebuilds:
    # one hash over the per-file hashes, in name order.
    $inputs = @($recipe) + @(Get-ChildItem (Join-Path $GpacDir "patches") `
        -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name |
        ForEach-Object { $_.FullName })
    $joined = ($inputs | ForEach-Object {
        (Get-FileHash -Algorithm SHA256 $_).Hash }) -join ""
    $wantId = (Get-FileHash -Algorithm SHA256 -InputStream (
        [System.IO.MemoryStream]::new(
            [System.Text.Encoding]::ASCII.GetBytes($joined)))).Hash
    $haveHdrs = (Test-Path $inc) -and
        ($null -ne (Get-ChildItem $inc -Filter *.h -ErrorAction SilentlyContinue |
            Select-Object -First 1))
    $haveId = (Test-Path $stamp) -and
        ((Get-Content $stamp -Raw -ErrorAction SilentlyContinue).Trim() -eq $wantId)
    if ((Test-Path $lib) -and (Test-Path $imp) -and $haveHdrs -and $haveId) { return }
    Info "Building vendored libgpac (for the MP4 muxer)..."
    & $recipe
    if ($LASTEXITCODE -ne 0) { Die "build_gpac.ps1 failed (exit=$LASTEXITCODE)" }
    Set-Content -Path $stamp -Value $wantId -Encoding ascii
}

# Ensure the vendored LGPL FFmpeg + dav1d (the FFmpeg-in-engine video backend's
# decode dependency) exists before Bazel links the Windows engine against it.
# Same posture as Ensure-Gpac: the DLLs, the MSVC import libs and the headers
# are git-ignored build outputs (engine/deps/ffmpeg/README.md), produced
# by build_ffmpeg.ps1 via MSYS2 — slow, so skip when the outputs are already
# present AND were produced by the current recipe (SHA-256 of build_ffmpeg.ps1
# stamped into lib\.build_id, same freshness rationale as GPAC). Delete
# engine/deps/ffmpeg/lib to force a rebuild by hand.
#
# The freshness check keys on the five av* import libs (the engine link
# inputs), at least one header, AND at least one runtime DLL — the DLLs land
# in the same step, but can vanish independently (partial clean, antivirus
# quarantine), and Build-Engine's staging would otherwise silently ship an
# engine whose imports can't resolve at run time.
function Ensure-Ffmpeg {
    $libDir  = Join-Path $FfmpegDir "lib"
    $inc     = Join-Path $FfmpegDir "include\libavcodec"
    $stamp   = Join-Path $libDir ".build_id"
    $recipe  = Join-Path $FfmpegDir "build_ffmpeg.ps1"
    $impLibs = @("avutil.lib", "avcodec.lib", "avformat.lib",
                 "swscale.lib", "swresample.lib")
    $wantId  = (Get-FileHash -Algorithm SHA256 $recipe).Hash
    $haveLibs = $impLibs | ForEach-Object { Test-Path (Join-Path $libDir $_) }
    $haveHdrs = (Test-Path $inc) -and
        ($null -ne (Get-ChildItem $inc -Filter *.h -ErrorAction SilentlyContinue |
            Select-Object -First 1))
    $haveId = (Test-Path $stamp) -and
        ((Get-Content $stamp -Raw -ErrorAction SilentlyContinue).Trim() -eq $wantId)
    $haveDlls = $null -ne (Get-ChildItem $libDir -Filter *.dll `
        -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (($haveLibs -notcontains $false) -and $haveHdrs -and $haveDlls -and
        $haveId) { return }
    Info "Building vendored FFmpeg + dav1d (for the video backend)..."
    & $recipe
    if ($LASTEXITCODE -ne 0) { Die "build_ffmpeg.ps1 failed (exit=$LASTEXITCODE)" }
    Set-Content -Path $stamp -Value $wantId -Encoding ascii
}

# Bazel needs a real bash for genrule actions (protobuf's upb_generator
# is one). On Windows it resolves a bare `bash.exe`, which on a machine
# with the WSL stub installed but no distro is
# C:\WINDOWS\system32\bash.exe -- it exits with
# WSL_E_DEFAULT_DISTRO_NOT_FOUND and the genrule fails. The runner and
# the documented dev setup both have MSYS2 (build_gpac.ps1 needs it), so
# point Bazel at that bash by the same probe build_gpac.ps1 uses.
# Returns the path, or $null when no MSYS2 bash is installed -- not fatal
# on its own, since a build whose actions need no shell still succeeds.
function Find-Bash {
    $roots = @()
    if ($env:MSYS2_ROOT) { $roots += $env:MSYS2_ROOT }
    $roots += @("C:\msys64", "C:\tools\msys64", "$env:SystemDrive\msys64")
    foreach ($r in $roots) {
        $candidate = Join-Path $r "usr\bin\bash.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# Build the C++ audio engine via Bazel and copy the DLL to engine/build/.
# ffi_bridge.dart's _resolveDylibPath walks up from runner.exe and picks
# the DLL out of engine/build/ at the repo root, so no extra copy next
# to runner.exe is needed for in-tree dev builds. libgpac.dll (which the
# engine dynamically imports) is staged beside it so the loader — which
# does NOT search engine/build/ for the engine's own imports — can resolve
# it; ffi_bridge preloads it from there by full path.
#
# -Opt builds optimized (-c opt: release runs — DSP code is ~5x faster
# than fastbuild, see issue ES-87). Default is Bazel's fastbuild (-O0) to
# keep debug iteration quick. Mirrors build.sh's build_engine.
function Build-Engine {
    param([switch] $Opt)
    if ($Opt) { Info "Building C++ audio engine (optimized)..." }
    else      { Info "Building C++ audio engine..." }
    Require-Cmd bazel "install via Bazelisk (choco install bazelisk) or download from bazel.build"
    Ensure-Gpac
    Ensure-Ffmpeg
    Push-Location $EngineSrc
    try {
        $bazelArgs = @("build")
        if ($Opt) {
            $bazelArgs += @("-c", "opt")
            # MSVC expands __FILE__ in headers to the absolute resolved
            # path, so third-party asserts (e.g. libopus celt/pitch.h)
            # embed the builder's username and Bazel output root in the
            # shipped DLL (ES-374). /d1trimfile strips the execroot prefix,
            # leaving the relative external\... path — matching what
            # clang already emits on macOS. The execroot is
            # machine-specific, so this can't live in .bazelrc.
            # The prefix must stay in Bazel's forward-slash form: Bazel
            # doubles backslashes when writing cl's .params file, so a
            # backslash prefix never matches anything. /d1trimfile
            # compares case- and separator-insensitively, so the
            # forward-slash prefix still trims MSVC's backslash
            # __FILE__ paths.
            $execRoot = & bazel info execution_root
            if ($LASTEXITCODE -eq 0 -and $execRoot) {
                $bazelArgs += "--copt=/d1trimfile:$execRoot/"
            }
        }
        # --shell_executable rather than $env:BAZEL_SH: the env var is
        # read when the Bazel server starts, so a server already running
        # without it would keep the stub.
        $bash = Find-Bash
        if ($bash) { $bazelArgs += "--shell_executable=$bash" }
        else {
            Write-Host ("  warning: MSYS2 bash not found -- Bazel will use " +
                        "whatever bash.exe is on PATH. If a genrule fails " +
                        "with WSL_E_DEFAULT_DISTRO_NOT_FOUND, install MSYS2 " +
                        "(https://www.msys2.org) or set MSYS2_ROOT.") -ForegroundColor Yellow
        }
        $bazelArgs += "//:eclipsa_studio_engine"
        & bazel @bazelArgs
        if ($LASTEXITCODE -ne 0) { Die "bazel build //:eclipsa_studio_engine failed (exit=$LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path $EngineOut)) {
        New-Item -ItemType Directory -Path $EngineOut | Out-Null
    }
    $src = Join-Path $EngineSrc "bazel-bin\$DllName"
    $dst = Join-Path $EngineOut $DllName
    if (-not (Test-Path $src)) { Die "build product not found: $src" }
    Copy-Item -Path $src -Destination $dst -Force
    Write-Host "Engine: $dst"

    # Stage libgpac.dll beside the engine DLL so it resolves when the engine
    # (loaded by absolute path from engine/build) imports it. Mirrors
    # build.sh's embed_engine_libs. Ensure-Gpac guarantees it exists.
    $gpacSrc = Join-Path $GpacDir "lib\$GpacDll"
    $gpacDst = Join-Path $EngineOut $GpacDll
    if (Test-Path $gpacSrc) {
        Copy-Item -Path $gpacSrc -Destination $gpacDst -Force
        Write-Host "libgpac: $gpacDst"
    }

    # Stage the FFmpeg + dav1d runtime DLLs beside the engine DLL for the same
    # reason as libgpac: eclipsa_studio_engine.dll statically imports avcodec-62.dll
    # etc., and the loader does NOT search engine/build/ for a by-absolute-path
    # DLL's own imports, so ffi_bridge preloads them from here by full path
    # before loading the engine. Mirrors build.sh's embed_engine_libs. Only the
    # DLLs are staged (the .lib import libs are link-time only). Ensure-Ffmpeg
    # guarantees they exist.
    $ffmpegDlls = Get-ChildItem (Join-Path $FfmpegDir "lib") -Filter *.dll `
        -ErrorAction SilentlyContinue
    if (-not $ffmpegDlls) {
        # Staging nothing here means the app dies at run time when
        # ffi_bridge preloads avcodec-*.dll — fail the build instead.
        Die ("no FFmpeg runtime DLLs in engine\deps\ffmpeg\lib " +
             "(import libs present but DLLs missing?) - delete that " +
             "directory to force a rebuild")
    }
    foreach ($dll in $ffmpegDlls) {
        Copy-Item -Path $dll.FullName -Destination (Join-Path $EngineOut $dll.Name) -Force
    }
    Write-Host "FFmpeg: $($ffmpegDlls.Count) DLLs -> $EngineOut"
}

# -- Lint -----------------------------------------------------------------
#
# Windows counterpart to build.sh's `lint`: `dart format` over the Flutter
# app plus clang-format / clang-tidy over the C++ engine. dart format is
# always available (bundled with the Flutter SDK); the clang tools are
# optional -- if they aren't on PATH (or under the standard LLVM install)
# they're skipped with a hint, so `lint` still formats Dart on a machine
# without LLVM. Unlike build.sh, lint is NOT auto-run on release builds
# here -- it's a standalone command only.

# Locate the standalone `dart` (preferred) or the one shipped next to
# `flutter`. Returns $null if neither is found.
function Find-Dart {
    $cmd = Get-Command dart -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutter) {
        $dartBat = Join-Path (Split-Path $flutter.Source) "dart.bat"
        if (Test-Path $dartBat) { return $dartBat }
    }
    return $null
}

# Locate a clang tool ($name = "clang-format" | "clang-tidy") on PATH, or
# under the default LLVM install (choco / the llvm.org installer both drop
# it in %ProgramFiles%\LLVM\bin). Returns $null if not found.
function Find-ClangTool($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $llvm = Join-Path $env:ProgramFiles "LLVM\bin\$name.exe"
    if (Test-Path $llvm) { return $llvm }
    return $null
}

# Format Dart source. -Check verifies without writing (CI gate). Returns
# $true when clean / formatted, $false when -Check found differences.
function Format-Dart {
    param([switch] $Check)
    Info "Formatting Dart source..."
    $dart = Find-Dart
    if (-not $dart) {
        if ($Check) {
            # Don't green-light the gate on a runner that can't verify:
            # a skipped check that "passes" hides real formatting drift.
            Write-Host "  dart not found -- cannot verify formatting (install the Flutter/Dart SDK)." -ForegroundColor Yellow
            return $false
        }
        Write-Host "  dart not found -- skipping (install the Flutter/Dart SDK)."
        return $true
    }
    $targets = @(Join-Path $FlutterDir "lib")
    $testDir = Join-Path $FlutterDir "test"
    if (Test-Path $testDir) { $targets += $testDir }
    if ($Check) {
        Write-Host "  dart format --set-exit-if-changed: lib/ test/..."
        # Capture the "Changed <path>" lines so the final verdict can list
        # the offending files (ES-337), then replay the output.
        $dartOut = & $dart format --output=none --set-exit-if-changed @targets
        $dartOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            $script:LintCheckDartFiles = @($dartOut | ForEach-Object {
                if ("$_" -match '^Changed (.+)$') {
                    $Matches[1] -replace [regex]::Escape("$RepoRoot\"), ''
                }
            } | Where-Object { $_ } | Sort-Object -Unique)
        }
    } else {
        Write-Host "  dart format: lib/ test/..."
        & $dart format @targets
    }
    return ($LASTEXITCODE -eq 0)
}

# Collect project .cc/.h under $root, pruning DURING traversal. We hand-walk
# instead of `Get-ChildItem -Recurse` because its -notmatch filters prune the
# result set, not the walk: on Windows PowerShell 5.1 (what CI uses) -Recurse
# follows the bazel-bin/bazel-out/... junctions, so after any engine build it
# would descend into the whole Bazel external/ + bazel-out tree (abseil,
# protobuf, eigen, ...) and, under $ErrorActionPreference = "Stop", die on the
# first PathTooLong (bazel-out paths routinely exceed 260 chars) or access
# error before formatting anything. build.sh's `find` doesn't follow symlinks,
# so this keeps parity. We skip reparse points (the junctions) plus the
# deps/build source dirs.
function Get-EngineSourceFiles($root) {
    $results = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($entry in Get-ChildItem -LiteralPath $dir -Force) {
            if ($entry.PSIsContainer) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    continue  # bazel-bin / bazel-out / ... junctions
                }
                # third_party is skipped alongside deps: engine/third_party
                # was renamed to engine/deps, but its git-ignored build
                # outputs survive on any machine that built before the
                # rename, and checkout will not remove them.
                if ($entry.Name -eq 'deps' -or
                    $entry.Name -eq 'third_party' -or
                    $entry.Name -eq 'build' -or
                    $entry.Name -like 'bazel-*') {
                    continue
                }
                $stack.Push($entry.FullName)
            } elseif ($entry.Extension -eq '.cc' -or $entry.Extension -eq '.h') {
                $results.Add($entry.FullName)
            }
        }
    }
    return $results
}

# Lint C++ engine source: clang-format (in-place, or --dry-run -Werror in
# check mode) plus clang-tidy (warnings only, non-blocking, skipped in
# check mode). Mirrors build.sh's lint_engine. Returns $true unless a
# check-mode clang-format run found unformatted files (or, in check mode, a
# required tool is missing -- see the clang-format else-branch).
function Lint-Engine {
    param([switch] $Check)
    Info "Linting C++ engine source..."

    $files = @(Get-EngineSourceFiles $EngineSrc | Sort-Object)
    if ($files.Count -eq 0) {
        Write-Host "  No C++ source files found."
        return $true
    }

    $ok = $true

    # clang-format: default fixes in place (-i); check mode verifies only.
    $clangFormat = Find-ClangTool "clang-format"
    if ($clangFormat) {
        if ($Check) {
            Write-Host "  clang-format: checking $($files.Count) files..."
            # Capture the diagnostics (clang-format prints them to stderr)
            # so the final verdict can list the offending files (ES-337),
            # then replay them. The EAP guard keeps Windows PowerShell 5.1
            # from promoting the redirected stderr lines to terminating
            # errors under the script's global "Stop" preference.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $fmtOut = & $clangFormat --dry-run -Werror @files 2>&1
            $ErrorActionPreference = $prevEap
            if ($LASTEXITCODE -ne 0) {
                $ok = $false
                $fmtOut | ForEach-Object { Write-Host "$_" }
                $script:LintCheckCcFiles = @($fmtOut | ForEach-Object {
                    if ("$_" -match '^(.+):\d+:\d+: error: ') {
                        $Matches[1] -replace [regex]::Escape("$RepoRoot\"), ''
                    }
                } | Where-Object { $_ } | Sort-Object -Unique)
                Write-Host "  clang-format: needs formatting -- run .\build.ps1 lint." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  clang-format: formatting $($files.Count) files..."
            & $clangFormat -i @files
        }
    } else {
        if ($Check) {
            # Same rationale as Format-Dart: fail the gate rather than pass
            # green while verifying nothing (e.g. Windows CI without LLVM).
            $ok = $false
            Write-Host "  clang-format not found -- cannot verify formatting (install LLVM: choco install llvm)." -ForegroundColor Yellow
        } else {
            Write-Host "  clang-format not found -- skipping (install LLVM: choco install llvm)."
        }
    }

    # clang-tidy: warnings only, non-blocking. Skipped in check mode (never
    # gates; recompiling every TU without Bazel's include paths just adds
    # noise). Skip test/ -- those pull gtest headers Bazel manages.
    if (-not $Check) {
        $clangTidy = Find-ClangTool "clang-tidy"
        if ($clangTidy) {
            $ccFiles = @($files | Where-Object {
                $_ -like '*.cc' -and $_ -notmatch '[\\/]test[\\/]'
            })
            if ($ccFiles.Count -gt 0) {
                Write-Host "  clang-tidy: checking $($ccFiles.Count) translation units..."
                $hadWarnings = $false
                # 2>$null mirrors build.sh's `2>/dev/null`: without Bazel's
                # include paths (absl/protobuf/eigen/iamf-tools) most TUs emit
                # fatal file-not-found diagnostics that would otherwise flood
                # the console. In Windows PowerShell 5.1 redirecting a native
                # exe's stderr under $ErrorActionPreference = "Stop" turns it
                # into a terminating NativeCommandError, so drop to Continue
                # for the loop (LASTEXITCODE still reflects each run).
                $prevEAP = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    foreach ($f in $ccFiles) {
                        & $clangTidy --quiet $f -- -std=c++20 `
                            "-I$EngineSrc" `
                            "-I$EngineSrc\deps\dr_wav" 2>$null
                        if ($LASTEXITCODE -ne 0) { $hadWarnings = $true }
                    }
                } finally {
                    $ErrorActionPreference = $prevEAP
                }
                if ($hadWarnings) { Write-Host "  clang-tidy: warnings found (see above)." }
                else              { Write-Host "  clang-tidy: clean" }
            }
        } else {
            Write-Host "  clang-tidy not found -- skipping (install LLVM: choco install llvm)."
        }
    }

    return $ok
}

# Delete the prefs/recents JSON files. Equivalent to build.sh's
# reset-prefs. Used by `run fresh` and the standalone `reset-prefs`
# command. Does not delete the JSONL log file (truncated on each launch
# anyway).
function Reset-Prefs {
    $found = $false
    foreach ($name in $PrefsFiles) {
        $p = Join-Path $PrefsDir $name
        if (Test-Path $p) {
            Remove-Item -Force $p
            Write-Host "Deleted $p"
            $found = $true
        }
    }
    if (-not $found) {
        Write-Host "No preferences or recents files found"
    }
}

function Show-Help {
    Write-Host "Usage: .\build.ps1 <command> [flags]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  engine                       Just rebuild the C++ engine DLL"
    Write-Host "  clean                        Clean build and re-fetch dependencies"
    Write-Host "  clean --deep                 ... + bazel expunge + wipe pub cache"
    Write-Host "  build                        Build engine + flutter build (release, no run)"
    Write-Host "  build debug                  ... debug mode"
    Write-Host "  package                      Release build + portable zip in dist\"
    Write-Host "  run                          Build engine + run (release + opt engine)"
    Write-Host "  run debug                    ... debug mode (fastbuild engine, hot reload)"
    Write-Host "  run fresh                    ... + reset prefs and recents first"
    Write-Host "  run debug fresh              ... debug + reset prefs and recents"
    Write-Host "  test-session [path]          Build + run with test session"
    Write-Host "  reset-prefs                  Delete saved preferences and recent files"
    Write-Host "  lint                         dart format + clang-format/clang-tidy (in place)"
    Write-Host "  lint --check                 Verify formatting only (CI gate; no writes)"
    Write-Host "  gen-tokens                   Regenerate theme_tokens.dart from app\design\tokens"
    Write-Host "  gen-tokens --check           Verify theme_tokens.dart is current (CI gate)"
    Write-Host "  gen-components               Regenerate component_index.dart from app\design\components.json"
    Write-Host "  gen-components --check       Verify component_index.dart is current (CI gate)"
    Write-Host ""
    Write-Host "Note: lint needs the Flutter SDK (dart format) and, for the C++ engine,"
    Write-Host "      LLVM on PATH (clang-format/clang-tidy) -- clang tools are skipped if"
    Write-Host "      absent. package produces a portable zip only for now -- signing and"
    Write-Host "      an installer are tracked in GitHub ES-279. docs is still macOS-only."
}

# -- Commands -------------------------------------------------------------

switch ($Command) {

    "help" { Show-Help; return }

    "engine" {
        Generate-VersionDart
        Build-Engine
    }

    "gen-tokens" {
        # Regenerate app/lib/theme_tokens.dart from app/design/tokens/.
        # Mirrors build.sh gen-tokens. Unlike the version stamp this
        # output IS committed, so `--check` is a drift gate rather than
        # a build step: it verifies the committed file matches the
        # tokens without writing.
        $check = $false
        foreach ($arg in $Rest) {
            switch ($arg) {
                "--check" { $check = $true }
                default   { Die "Unknown argument to 'gen-tokens': $arg" }
            }
        }
        # `python`, not `python3`: on Windows `python3` is often the
        # Microsoft Store alias, which exits non-zero even when Python
        # is installed. Matches Generate-ReleasesJson.
        Require-Cmd python "install Python 3 from python.org"
        $gen = Join-Path $RepoRoot "scripts\gen_design_tokens.py"
        if ($check) { & python $gen --check }
        else        { & python $gen }
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    "gen-components" {
        # Regenerate app/lib/widgets/component_index.dart. Mirrors
        # build.sh gen-components. Metadata comes from
        # app\design\components.json; the "used in" map is read out of
        # app\lib, so the gallery's usage list cannot drift from the
        # code. Committed, so `--check` is a drift gate.
        $check = $false
        foreach ($arg in $Rest) {
            switch ($arg) {
                "--check" { $check = $true }
                default   { Die "Unknown argument to 'gen-components': $arg" }
            }
        }
        # See gen-tokens for why `python` rather than `python3`.
        Require-Cmd python "install Python 3 from python.org"
        $gen = Join-Path $RepoRoot "scripts\gen_component_index.py"
        if ($check) { & python $gen --check }
        else        { & python $gen }
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    "clean" {
        $deep = $false
        foreach ($arg in $Rest) {
            switch ($arg) {
                "--deep" { $deep = $true }
                default  { Die "Unknown argument to 'clean': $arg" }
            }
        }

        Info "Running flutter clean..."
        Push-Location $FlutterDir
        try { & flutter clean } finally { Pop-Location }

        if (Test-Path $EngineSrc) {
            Push-Location $EngineSrc
            try {
                # Non-deep: plain bazel clean leaves the action cache
                # and daemon alive for faster rebuilds. Deep: expunge
                # wipes the output tree AND the execroot disk cache.
                # No 2>$null here: in Windows PowerShell 5.1, redirecting
                # a native exe's stderr wraps bazel's INFO lines in
                # ErrorRecords, which $ErrorActionPreference=Stop then
                # treats as terminating.
                if ($deep) { & bazel clean --expunge }
                else       { & bazel clean }
            } finally { Pop-Location }
            if (Test-Path $EngineOut) {
                Remove-Item -Recurse -Force $EngineOut
            }
        }

        if ($deep) {
            # Pub cache — holds every version of every package every
            # Flutter project on this machine has ever resolved.
            # System-wide, like build.sh's ~/.pub-cache wipe.
            $pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE }
                        else { Join-Path $env:LOCALAPPDATA "Pub\Cache" }
            if (Test-Path $pubCache) {
                Info "Deep clean: removing pub cache ($pubCache) -- affects ALL Flutter projects..."
                Remove-Item -Recurse -Force $pubCache
            }
        }

        Info "Fetching dependencies..."
        Push-Location $FlutterDir
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { Die "flutter pub get failed" }
        } finally { Pop-Location }
    }

    "build" {
        # Same mode vocabulary as `run`: release (+ optimized engine)
        # by default, `build debug` for a debug build.
        $debug = $false
        foreach ($arg in $Rest) {
            switch ($arg) {
                "debug"   { $debug = $true }
                "release" { }  # alias of the default
                default   { Die "Unknown argument to 'build': $arg" }
            }
        }
        Require-FlutterVersion
        Generate-VersionDart
        Generate-ReleasesJson
        Build-Engine -Opt:(-not $debug)
        Push-Location $FlutterDir
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { Die "flutter pub get failed" }
            $args = @("build", "windows")
            if ($debug) { $args += "--debug" } else { $args += "--release" }
            & flutter @args
            if ($LASTEXITCODE -ne 0) { Die "flutter build windows failed" }
        } finally { Pop-Location }
    }

    "package" {
        # Portable-zip packaging (interim -- signing + installer are
        # ES-279): release build, then stage the Flutter bundle with the
        # engine DLLs and the VC++ runtime beside the exe and zip it
        # to dist\. The layout works because ffi_bridge.dart resolves
        # eclipsa_studio_engine.dll next to the exe first and preloads
        # libgpac/FFmpeg from the same directory.
        if ($Rest.Count -gt 0) { Die "Unknown argument to 'package': $($Rest[0])" }
        Require-FlutterVersion

        # Optional pre-package hook for a clean tagged release: runs
        # .claude\release\gate.py when the checkout has it, and stops the
        # package when it fails. Runs before the engine build so a failure
        # is reported at once. Off-tag or dirty builds (tracked changes, as
        # build.sh's `describe --dirty`) and checkouts without the file skip
        # it, and say so.
        $gate = Join-Path $RepoRoot ".claude\release\gate.py"
        $describe = (cmd /c "git -C `"$RepoRoot`" describe --tags --dirty --match=v* 2>nul" | Out-String).Trim()
        $exact = (cmd /c "git -C `"$RepoRoot`" describe --tags --exact-match --match=v* 2>nul" | Out-String).Trim()
        if (-not (Test-Path $gate)) {
            Info "No pre-package gate in this checkout; skipping it."
        } elseif (-not $exact -or $describe -like "*-dirty") {
            Info "Pre-release build ($describe); skipping the pre-package gate."
        } else {
            Require-Cmd python "install Python 3 from python.org"
            $gateVersion = $exact.TrimStart("v")
            Info "Running the pre-package gate for $gateVersion..."
            & python $gate gate $gateVersion
            if ($LASTEXITCODE -ne 0) {
                Die "Pre-package gate failed for $gateVersion (see its output above)"
            }
        }

        Generate-VersionDart
        Generate-ReleasesJson
        Build-Engine -Opt

        # Stamp the exe's VERSIONINFO from the git tag (ES-373). Versioning
        # flows from tags (Generate-VersionDart), never pubspec.yaml — but
        # the Windows runner stamps Runner.rc's FILEVERSION/PRODUCTVERSION
        # from pubspec's dev default (0.1.0+1) unless overridden here.
        # Mirrors build.sh package's flutter build macos stamping:
        # --build-name is the nearest v* tag (a valid x.y.z even off-tag),
        # --build-number the total commit count.
        $nearest = (cmd /c "git -C `"$RepoRoot`" describe --tags --abbrev=0 --match=v* 2>nul" | Out-String).Trim()
        if (-not $nearest) { Die "No v* tags found -- package stamps the version from the nearest tag" }
        $buildName   = $nearest.TrimStart("v")

        $buildNumber = (cmd /c "git -C `"$RepoRoot`" rev-list --count HEAD 2>nul" | Out-String).Trim()
        if (-not $buildNumber) { Die "could not resolve build number (git rev-list --count HEAD)" }

        $releaseDir = Join-Path $FlutterDir "build\windows\x64\runner\Release"
        Push-Location $FlutterDir
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { Die "flutter pub get failed" }
            # Wipe the Release dir first: flutter build never deletes
            # outputs of since-removed plugins, so an incremental dir
            # ships stale DLLs (the retired media_kit/fvp backends
            # haunted the first packaged build this way).
            if (Test-Path $releaseDir) { Remove-Item -Recurse -Force $releaseDir }
            Info "Building Flutter release (v$buildName build $buildNumber)..."
            & flutter build windows --release `
                --build-name=$buildName --build-number=$buildNumber
            if ($LASTEXITCODE -ne 0) { Die "flutter build windows failed" }
        } finally { Pop-Location }

        # Version for the zip name, from the file Generate-VersionDart
        # just wrote (single source of truth for the version string).
        $verLine = Get-Content (Join-Path $FlutterDir "lib\generated\version.dart") `
            | Select-String -Pattern "appVersion = '([^']+)'"
        if (-not $verLine) { Die "could not parse lib\generated\version.dart" }
        $ver = $verLine.Matches[0].Groups[1].Value

        Info "Staging portable bundle..."
        $dist  = Join-Path $RepoRoot "dist"
        $stage = Join-Path $dist "EclipsaStudio-$ver-win-x64"
        $zip   = "$stage.zip"
        if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
        New-Item -ItemType Directory -Force $stage | Out-Null

        # Flutter bundle (exe, flutter_windows.dll, plugin DLLs, data\).
        Copy-Item -Recurse (Join-Path $releaseDir "*") $stage

        # Swap flutter_angle's DLL set for our release ANGLE build (ES-372).
        # The pub package bundles DEBUG ANGLE binaries plus the debug
        # Microsoft CRT (not redistributable) into every Windows build;
        # engine\deps\angle\build_angle.ps1 produces release
        # libEGL/libGLESv2 that import only Windows system DLLs and the
        # release VC++ runtime staged below. libc++.dll and zlib.dll are
        # dropped outright: they exist only to serve the debug ANGLE pair
        # (the release build links zlib statically; nothing imports libc++).
        $angleBin = Join-Path $EngineSrc "deps\angle\bin"
        foreach ($dll in "libEGL.dll", "libGLESv2.dll") {
            if (-not (Test-Path (Join-Path $angleBin $dll))) {
                Die ("release ANGLE not vendored ($angleBin\$dll missing) -- " +
                     "run engine\deps\angle\build_angle.ps1 first (ES-372)")
            }
        }
        # The DLLs must come from the commit and gn args build_angle.ps1
        # pins now: the third-party notices list what that configuration
        # links, and a DLL built before a change to either carries code
        # they do not attribute (ES-735).
        $angleScript = Join-Path $EngineSrc "deps\angle\build_angle.ps1"
        $wantConfig = (& powershell -NoProfile -ExecutionPolicy Bypass `
            -File $angleScript -PrintConfig) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $wantConfig.Trim()) {
            Die "build_angle.ps1 -PrintConfig failed -- cannot check the ANGLE build."
        }
        $stamp = Join-Path $angleBin "BUILD_CONFIG"
        $haveConfig = if (Test-Path $stamp) {
            (Get-Content $stamp) -join "`n"
        } else { "" }
        if ($haveConfig.Trim() -ne $wantConfig.Trim()) {
            Die ("release ANGLE in $angleBin was built from another " +
                 "configuration than build_angle.ps1 pins -- re-run " +
                 "engine\deps\angle\build_angle.ps1.`n" +
                 "  expected: $($wantConfig -replace "`n", '; ')`n" +
                 "  found:    $(if ($haveConfig) { $haveConfig -replace "`n", '; ' } else { 'no BUILD_CONFIG' })")
        }
        Info "Swapping in release ANGLE..."
        foreach ($name in "libEGL.dll", "libGLESv2.dll", "libc++.dll",
                          "zlib.dll", "msvcp140d.dll", "ucrtbased.dll",
                          "vccorlib140d.dll", "vcruntime140_1d.dll",
                          "vcruntime140d.dll") {
            Remove-Item (Join-Path $stage $name) -ErrorAction SilentlyContinue
        }
        Copy-Item (Join-Path $angleBin "*.dll") $stage

        # Engine + its runtime deps (libgpac, FFmpeg/dav1d) beside the
        # exe -- Build-Engine staged them all in engine\build.
        Copy-Item (Join-Path $EngineOut "*.dll") $stage

        # Release VC++ runtime: flutter build doesn't bundle it, and a
        # machine without the redist won't start the app otherwise
        # (Flutter's own distribution guidance says to copy these).
        foreach ($crt in "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll") {
            $src = Join-Path $env:SystemRoot "System32\$crt"
            if (-not (Test-Path $src)) { Die "VC++ runtime DLL not found: $src" }
            Copy-Item $src $stage
        }

        # Third-party notices beside the exe. The Windows zip has no
        # installer and no About box, so this file is the bundled
        # document carrying the attributions the shipped licenses
        # require -- including the Steinberg ASIO copyrights notice
        # (ES-554, section 3b). build.sh stages the same file in the DMG.
        # Gated both ends: a missing source is a packaging bug, and the
        # staged copy is asserted so the run log proves the obligation
        # was met rather than leaving it to a silent Copy-Item.
        $noticesSrc = Join-Path $RepoRoot "third_party\THIRD_PARTY_NOTICES.txt"
        if (-not (Test-Path $noticesSrc)) {
            Die ("third-party notices not found: $noticesSrc -- the zip " +
                 "must ship them (ES-554)")
        }
        Copy-Item $noticesSrc $stage
        $noticesDst = Join-Path $stage (Split-Path $noticesSrc -Leaf)
        if (-not (Test-Path $noticesDst)) {
            Die "third-party notices not staged: $noticesDst"
        }
        Info ("Staged THIRD_PARTY_NOTICES.txt " +
              "($((Get-Item $noticesDst).Length) bytes)")

        # Path-hygiene gate (ES-374): no staged native binary may embed the
        # builder's Bazel output root (which carries the local username).
        # Scans DLLs + exe only — data\app.so is excluded: Flutter's AOT
        # tooling embeds the dart_plugin_registrant.dart file URI (repo
        # path) and offers no trim flag short of --obfuscate; accepted.
        Info "Checking staged binaries for local build paths..."
        $leakRe = '_bazel_|execroot[\\/]'
        foreach ($bin in Get-ChildItem $stage -Recurse -Include "*.dll", "*.exe") {
            $ascii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($bin.FullName))
            if ($ascii -match $leakRe) {
                Die "local build path leaked into $($bin.Name) (matches '$leakRe') -- see ES-374"
            }
        }

        # Debug-CRT gate (ES-372) -- runs after all staging so it covers the
        # Flutter bundle, the ANGLE swap, the engine DLLs and the CRT copy.
        Assert-NoDebugCrt $stage

        Info "Zipping..."
        if (Test-Path $zip) { Remove-Item -Force $zip }
        Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
        Remove-Item -Recurse -Force $stage
        $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
        Write-Host "Package: $zip ($sizeMb MB)"
    }

    "run" {
        # Default is release (mirrors build.sh): the fastbuild engine
        # decodes IAMF slower than real-time (constant ring underruns —
        # ES-87/ES-90), so plain `run` builds the engine optimized.
        # `run debug` opts into debug mode (Flutter debug + fastbuild
        # engine) for hot reload and engine debugging. `release` is
        # accepted as a no-op alias of the default.
        $debug = $false
        $fresh = $false
        foreach ($arg in $Rest) {
            switch ($arg) {
                "debug"   { $debug = $true }
                "release" { }  # alias of the default
                "fresh"   { $fresh = $true }
                default   { Die "Unknown argument to 'run': $arg" }
            }
        }
        Require-FlutterVersion
        if ($fresh) { Reset-Prefs }

        Generate-VersionDart
        Generate-ReleasesJson
        Build-Engine -Opt:(-not $debug)

        Push-Location $FlutterDir
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { Die "flutter pub get failed" }

            if (-not $debug) {
                # Release: don't go through `flutter run --release`.
                # Mirrors build.sh: without a VM-service connection the
                # flutter tool never notices the app quitting, so the
                # terminal hangs until Ctrl-C after the window closes.
                # Release runs gain nothing from the tool anyway (no hot
                # reload), so build the bundle and launch runner.exe
                # directly -- it attaches to this console (see
                # runner/main.cpp), so stdout/stderr including the
                # engine's rt log land here. No DLL embed step, unlike
                # build.sh's Frameworks copy: nothing bundles a stale
                # eclipsa_studio_engine.dll beside the exe on Windows, so
                # ffi_bridge's walk-up always finds the fresh
                # engine\build\ copy.
                & flutter build windows --release
                if ($LASTEXITCODE -ne 0) { Die "flutter build windows failed" }
                $exe = Join-Path $FlutterDir "build\windows\x64\runner\Release\eclipsa_studio.exe"
                if (-not (Test-Path $exe)) { Die "Build output not found: $exe" }
                Info "Launching Eclipsa Studio (release)..."
                # Start-Process -Wait: the runner is a GUI-subsystem
                # exe, so a bare invocation would return immediately
                # instead of blocking until the app exits.
                $proc = Start-Process -FilePath $exe -Wait -NoNewWindow -PassThru
                exit $proc.ExitCode
            }

            # Debug: `flutter run` for hot reload.
            & flutter run -d windows
        } finally { Pop-Location }
    }

    "test-session" {
        # Build + run with a test session auto-loaded. Session path
        # comes from (in priority order):
        #   1. .\build.ps1 test-session C:\path\to\session.esp
        #   2. $env:ECLIPSA_STUDIO_TEST_SESSION (set in the PowerShell profile)
        # Test media lives outside the repo — see .gitignore and README.
        # Mirrors build.sh: debug run + fastbuild engine.
        $sessionPath = if ($Rest.Count -gt 0) { $Rest[0] }
                       else { $env:ECLIPSA_STUDIO_TEST_SESSION }
        if (-not $sessionPath) {
            Die "No session path given -- pass one as an argument or set ECLIPSA_STUDIO_TEST_SESSION"
        }
        if (-not (Test-Path $sessionPath)) {
            Die "Session file not found: $sessionPath"
        }
        Require-FlutterVersion

        Generate-VersionDart
        Generate-ReleasesJson
        Build-Engine

        Push-Location $FlutterDir
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { Die "flutter pub get failed" }
            & flutter run -d windows --dart-entrypoint-args "--session $sessionPath"
        } finally { Pop-Location }
    }

    "lint" {
        # dart format + clang-format/clang-tidy over the engine. `--check`
        # is the CI-gate variant: verify formatting without writing and
        # exit non-zero on any diff (mirrors build.sh lint --check).
        $check = $false
        foreach ($arg in $Rest) {
            switch ($arg) {
                "--check" { $check = $true }
                default   { Die "Unknown argument to 'lint': $arg" }
            }
        }
        $script:LintCheckCcFiles = @()
        $script:LintCheckDartFiles = @()
        $dartOk   = Format-Dart -Check:$check
        $engineOk = Lint-Engine -Check:$check
        # The verdict prints LAST (ES-337): per-file diagnostics scroll away
        # and pipes mask the exit code, so the outcome must be the final
        # line either way. Mirrors build.sh's lint --check.
        if ($check) {
            Write-Host ""
            if ($dartOk -and $engineOk) {
                Write-Host "LINT CHECK PASSED"
            } else {
                if ($script:LintCheckCcFiles.Count -gt 0) {
                    Write-Host "Unformatted C++ (clang-format):" -ForegroundColor Yellow
                    $script:LintCheckCcFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
                }
                if ($script:LintCheckDartFiles.Count -gt 0) {
                    Write-Host "Unformatted Dart (dart format):" -ForegroundColor Yellow
                    $script:LintCheckDartFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
                }
                Die "LINT CHECK FAILED -- run .\build.ps1 lint"
            }
        }
    }

    "reset-prefs" { Reset-Prefs }

    default {
        Show-Help
        exit 1
    }
}
