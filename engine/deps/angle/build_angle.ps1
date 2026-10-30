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

# Build release ANGLE (libEGL.dll + libGLESv2.dll) and vendor it into this
# directory, replacing the DEBUG binaries the flutter_angle pub package ships
# (ES-372). flutter_angle 0.4.x bundles debug ANGLE plus the debug Microsoft
# CRT (ucrtbased.dll & friends) into every Windows build — the debug CRT is
# not redistributable under the Visual Studio license, so a package
# containing it cannot be shipped. `build.ps1 package` swaps the staged
# flutter_angle DLL set for the output of this script and gates on it.
#
# Follows ANGLE's official DevSetup (doc/DevSetup.md): depot_tools +
# `fetch angle` + gn + autoninja. The checkout is large (several GB) and the
# first build takes a while; both are kept under .\work for incremental
# re-runs. Re-run this script to rebuild after bumping $AngleCommit.
#
# Prerequisites:
#   * git and Python 3 on PATH
#   * Visual Studio 2022 with the C++ (VC) toolset and a Windows 10/11 SDK
#     (the same install Bazel uses for the engine)
#   * ~10 GB free disk for the checkout + build tree
#
# Outputs (git-ignored — produced here, not checked in):
#   bin\libEGL.dll          release ANGLE EGL front-end
#   bin\libGLESv2.dll       release ANGLE GLES implementation
#   bin\BUILD_CONFIG        the commit and gn args the two DLLs were built
#                           with. `build.ps1 package` compares it with
#                           `build_angle.ps1 -PrintConfig` and refuses DLLs
#                           built from another configuration, so a change to
#                           $AngleCommit or $gnArgs cannot ship stale DLLs.
#
# The DLLs export the standard EGL/GLES C entry points, so they satisfy the
# import tables of flutter_angle's plugin (which links the pub package's
# import libs by DLL name). They import only Windows system DLLs and the
# RELEASE VC++ runtime (msvcp140/vcruntime140), which build.ps1 package
# already stages beside the exe.
#
# NOTE: this recipe has not been run through CI. The gn arg set below and
# the depot_tools bootstrap are the most likely knobs to adjust on first
# run; ANGLE's doc/DevSetup.md is the reference.

param(
    # Print the configuration BUILD_CONFIG records and exit, without
    # fetching or building anything.
    [switch]$PrintConfig
)

$ErrorActionPreference = "Stop"

# Pin point — bump deliberately and re-verify the 3D renderer afterwards.
# ANGLE has no tagged releases; this is angle/angle main as of 2026-07-17.
$AngleCommit = "2ce714730798496bbde12addb2187058f2847379"

# gn args. Everything the DLLs link statically must be attributed in
# third_party/THIRD_PARTY_NOTICES.txt, so the backends and helpers the app
# does not use are switched off rather than attributed (ES-735). With the
# defaults, libGLESv2 also linked the Vulkan backend (VulkanMemoryAllocator,
# SPIRV-Tools, volk), the WebGPU backend (Dawn and Tint), Abseil and
# astc-encoder. With the args below it links only ANGLE's own code, xxHash,
# Chromium's zlib and the LLVM runtime (libc++, compiler-rt); `gn desc` or the
# link line in out\Release\obj\libGLESv2.ninja shows the inputs.
#
# is_debug=false          release codegen, release CRT (/MD).
# is_component_build=false  self-contained libEGL/libGLESv2 — no libc++,
#                         zlib, or chrome base DLLs alongside (zlib links
#                         statically), unlike the component-debug build
#                         flutter_angle ships.
# angle_build_all=false   the libraries only, not tests or samples.
# angle_enable_vulkan=false, angle_enable_wgpu=false
#                         Direct3D 11 is the backend the app renders
#                         through on Windows; the Vulkan and WebGPU
#                         backends are not used.
# angle_build_vulkan_system_info=false
#                         GPU identification through Vulkan, which links
#                         volk and a Vulkan loader shim even with the
#                         Vulkan backend off. Direct3D identifies the GPU.
# angle_enable_abseil=false, angle_has_astc_encoder=false
#                         ANGLE's optional use of Abseil containers and its
#                         ASTC texture encoder, neither needed by the app.
$gnArgs = "is_debug=false is_component_build=false angle_build_all=false " +
          "angle_enable_vulkan=false angle_enable_wgpu=false " +
          "angle_build_vulkan_system_info=false " +
          "angle_enable_abseil=false angle_has_astc_encoder=false"

$BuildConfig = "commit=$AngleCommit`ngn_args=$gnArgs"
if ($PrintConfig) {
    Write-Output $BuildConfig
    exit 0
}

$Here = $PSScriptRoot
$Bin  = Join-Path $Here "bin"

# The checkout lives under .\work unless ANGLE_WORK_DIR names another
# directory. ANGLE's DEPS tree (libc++ tests, depot_tools' gsutil extract)
# reaches past MAX_PATH (260) from a deep root: under the CI runner's
# C:\actions-runner\_work\eclipsa-studio\eclipsa-studio\engine\deps\angle\work
# git needed core.longpaths and Python's zipfile then failed regardless, so
# the workflow sets ANGLE_WORK_DIR=C:\angle. A checkout already at the
# default location is moved rather than fetched again (a rename on the same
# volume; the repos hold no absolute paths).
$DefaultWork = Join-Path $Here "work"
$Work = if ($env:ANGLE_WORK_DIR) { $env:ANGLE_WORK_DIR } else { $DefaultWork }
if (($Work -ne $DefaultWork) -and (Test-Path $DefaultWork) -and -not (Test-Path $Work)) {
    Write-Host "Moving the existing checkout from $DefaultWork to $Work ..."
    Move-Item $DefaultWork $Work
}

function Die($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

foreach ($tool in "git", "python") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Die "$tool not found in PATH"
    }
}

# --- depot_tools ------------------------------------------------------------
# Bootstrapped into work\depot_tools. DEPOT_TOOLS_WIN_TOOLCHAIN=0 makes the
# Chromium build use the locally installed VS instead of Google's internal
# toolchain (required for non-Googlers, per DevSetup).
$DepotTools = Join-Path $Work "depot_tools"
if (-not (Test-Path (Join-Path $DepotTools "gclient.bat"))) {
    Write-Host "Bootstrapping depot_tools into $DepotTools ..."
    New-Item -ItemType Directory -Force $Work | Out-Null
    & git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $DepotTools
    if ($LASTEXITCODE -ne 0) { Die "depot_tools clone failed" }
}
$env:PATH = "$DepotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"

# Long paths. libc++'s test tree inside ANGLE's DEPS exceeds MAX_PATH (260)
# under the runner's work directory, and git fails the checkout with
# "Filename too long". core.longpaths makes git use the \\?\ prefix for its
# own file I/O. The environment variable scopes it to the git invocations
# this script starts (gclient's included) without touching the machine's
# global config; on a CI runner the global setting is set as well, for the
# git that depot_tools bootstraps for itself.
$env:GIT_CONFIG_PARAMETERS = "'core.longpaths=true'"
if ($env:GITHUB_ACTIONS -eq "true") {
    & git config --global core.longpaths true
}

# Install gsutil before the DEPS hooks run. gclient runs the hooks in
# parallel, and on a fresh runner every download_from_google_storage hook
# tried to install gsutil at once; one lost the 30 s lock on
# external_bin\gsutil (lockfile.LockError, error code 6) and failed the
# whole fetch. Not fatal if it fails here: the hooks retry on their own.
Write-Host "Warming up gsutil ..."
& python (Join-Path $DepotTools "gsutil.py") -- version 2>&1 | Out-Null

# --- Fetch / sync ANGLE ------------------------------------------------------
$Src = Join-Path $Work "angle"
New-Item -ItemType Directory -Force $Src | Out-Null
Set-Content -Path (Join-Path $Src ".gclient") -Encoding ascii -Value @"
solutions = [{
  "name": ".",
  "url": "https://chromium.googlesource.com/angle/angle.git@$AngleCommit",
  "deps_file": "DEPS",
  "managed": False,
  "custom_vars": {
    "checkout_angle_dawn_deps": False,
    "checkout_angle_cl_deps": False,
  },
  "custom_deps": {
    "third_party/SwiftShader": None,
    "third_party/VK-GL-CTS/src": None,
    "third_party/catapult": None,
  },
}]
"@

Push-Location $Src
try {
    # --nohooks: the sync below runs the hooks, after the bundled gsutil
    # has been installed once (see there).
    # --force --reset: a sync interrupted by a failed hook or a runner
    # timeout leaves dependency checkouts with local changes (third_party\dawn
    # after the first 0.26.0 bootstrap), which a plain sync refuses with
    # "You have uncommitted changes". Nothing under work\ is ever edited, so
    # resetting the dependencies to their pinned revisions loses nothing.
    & cmd /c "gclient sync --no-history --nohooks -D --force --reset"
    if ($LASTEXITCODE -ne 0) { Die "gclient sync failed (exit=$LASTEXITCODE)" }
    # The DEPS hooks run download_from_google_storage from ANGLE's own
    # third_party\depot_tools, not the one bootstrapped above, so its gsutil
    # is the one the parallel hooks would race to install. Install it first.
    $bundledGsutil = Join-Path $Src "third_party\depot_tools\gsutil.py"
    if (Test-Path $bundledGsutil) {
        Write-Host "Warming up the bundled gsutil ..."
        & python $bundledGsutil -- version 2>&1 | Out-Null
    }
    & cmd /c "gclient runhooks"
    if ($LASTEXITCODE -ne 0) { Die "gclient runhooks failed (exit=$LASTEXITCODE)" }

    # --- Configure + build ---------------------------------------------------
    # $gnArgs is set at the top of the script, with the reason for each.
    Write-Host "gn gen out/Release ($gnArgs) ..."
    & cmd /c "gn gen out/Release --args=`"$gnArgs`""
    if ($LASTEXITCODE -ne 0) { Die "gn gen failed (exit=$LASTEXITCODE)" }

    Write-Host "Building libEGL + libGLESv2 (autoninja) ..."
    & cmd /c "autoninja -C out/Release libEGL libGLESv2"
    if ($LASTEXITCODE -ne 0) { Die "autoninja failed (exit=$LASTEXITCODE)" }
} finally { Pop-Location }

# --- Vendor + verify ---------------------------------------------------------
New-Item -ItemType Directory -Force $Bin | Out-Null
# The stamp is written only after every check below passes, so a run that
# fails verification leaves no BUILD_CONFIG beside the DLLs it copied and
# build.ps1 package refuses them.
Remove-Item (Join-Path $Bin "BUILD_CONFIG") -ErrorAction SilentlyContinue
# NB: the loop variable must not be named $src -- PowerShell variables are
# case-insensitive, so it would clobber the $Src checkout path above.
foreach ($dll in "libEGL.dll", "libGLESv2.dll") {
    $built = Join-Path $Src "out\Release\$dll"
    if (-not (Test-Path $built)) { Die "build product not found: $built" }
    Copy-Item $built (Join-Path $Bin $dll) -Force
}

# Locate dumpbin via vswhere (same approach as build_gpac.ps1).
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Die "vswhere.exe not found -- is Visual Studio installed?" }
$dumpbinExe = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -find "VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe" | Select-Object -First 1
if (-not $dumpbinExe) { Die "dumpbin.exe not found -- is the VS C++ toolset installed?" }

# Fail closed: the build must import only release runtimes. A debug-CRT
# import here means the gn args regressed and the package gate would
# reject the result anyway.
foreach ($dll in "libEGL.dll", "libGLESv2.dll") {
    $path = Join-Path $Bin $dll
    $deps = & $dumpbinExe /nologo /dependents "$path" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($deps -match '\.dll')) {
        $deps | Write-Host
        Die "dumpbin /dependents did not report $dll's imports -- cannot verify."
    }
    if ($deps | Select-String -Pattern 'ucrtbased\.dll|140d\.dll' -Quiet) {
        $deps | Write-Host
        Die "$dll imports the DEBUG CRT -- the build is not a release build."
    }
    # The staged package carries no libc++/zlib once the debug set is
    # removed, so the release DLLs must not want them either.
    if ($deps | Select-String -Pattern 'libc\+\+\.dll|zlib\.dll' -Quiet) {
        $deps | Write-Host
        Die "$dll imports libc++/zlib -- expected a non-component build (statically linked)."
    }
}

# The backends switched off in $gnArgs must not be in the DLL: the
# third-party notices do not carry the licences of their dependencies.
# Vulkan code loads vulkan-1.dll at run time rather than importing it, so
# the check reads the DLL's strings, not its import table. At the pinned
# commit, a default-args libGLESv2.dll contains all four strings as plain
# ASCII (function names in log and assert text) and a build with the gn
# args above contains none of them.
$glesText = [System.Text.Encoding]::ASCII.GetString(
    [System.IO.File]::ReadAllBytes((Join-Path $Bin "libGLESv2.dll")))
foreach ($marker in "vulkan-1.dll", "rx::vk::", "wgpu::", "absl::") {
    if ($glesText.Contains($marker)) {
        Die ("libGLESv2.dll contains '$marker' -- a backend or " +
             "library the gn args disable was linked.")
    }
}

# The flutter_angle plugin resolves standard EGL/GLES entry points from
# these DLLs by name; spot-check two anchor exports.
$eglExports = & $dumpbinExe /nologo /exports (Join-Path $Bin "libEGL.dll") 2>&1
if (-not ($eglExports | Select-String -Pattern '\begl(GetDisplay|Initialize)\b' -Quiet)) {
    Die "libEGL.dll does not export core EGL entry points."
}
$glesExports = & $dumpbinExe /nologo /exports (Join-Path $Bin "libGLESv2.dll") 2>&1
if (-not ($glesExports | Select-String -Pattern '\bglGetString\b' -Quiet)) {
    Die "libGLESv2.dll does not export core GLES entry points."
}

Set-Content -Path (Join-Path $Bin "BUILD_CONFIG") -Value $BuildConfig -Encoding ascii

Write-Host ""
Write-Host "Done:"
foreach ($dll in "libEGL.dll", "libGLESv2.dll") {
    $item = Get-Item (Join-Path $Bin $dll)
    $size = "{0:N1} MB" -f ($item.Length / 1MB)
    Write-Host "  $($item.FullName)  ($size)"
}
Write-Host "Next: .\build.ps1 package stages these over flutter_angle's debug set."
