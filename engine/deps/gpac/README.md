# Vendored libgpac (MP4 muxer)

The engine's "Export to MP4" path (`engine/iamf/iamf_muxer.cc`) muxes the
IAMF bitstream + the session video into a single IAMF-in-ISOBMFF `.mp4`
using **libgpac** (GPAC) in-process. This directory vendors that library.

## Why GPAC, linked dynamically

Chosen in ES-198 (Approach B), mirroring `google/eclipsa-audio-plugin`, the
reference IAMF authoring tool, which muxes exactly this way: a GPAC filter
session writes the IAMF audio track, then GPAC's ISO-media API clones the
source video track and stream-copies its samples in.

- **Dynamic link, not static.** GPAC is **LGPL-2.1-or-later**. Linking it
  dynamically keeps LGPL compliance simple (ship the library + a relink
  provision) and is the same posture the app already has via media_kit
  (libmpv/FFmpeg as dynamic frameworks). The engine's *static* link stays
  permissive-only — no copyleft is statically linked in.
- **FFmpeg-free.** `build_gpac.sh` configures with `--static-bin
  --use-curl=no`, which disables every external library that isn't
  statically linkable. The resulting library has **no FFmpeg / curl /
  OpenSSL dependency** — confirm with `otool -L lib/libgpac.dylib` (only
  Apple system frameworks + libSystem). This honours the project rule:
  FFmpeg is for demux/QC validation only, never the IAMF writer.

## Building / vendoring

The library and headers are **not checked in** (see `.gitignore`); they are
build outputs. Produce them with:

```sh
engine/deps/gpac/build_gpac.sh    # macOS
```
```powershell
engine\deps\gpac\build_gpac.ps1   # Windows (needs MSYS2 + MSVC)
```

Each clones GPAC at the pinned commit, builds it clean, and drops the
library + `include/gpac/*.h` here. macOS produces `lib/libgpac.dylib`;
Windows produces `lib/libgpac.dll` **and** `lib/gpac.lib` (the MSVC import
library the engine links against — a Unix `.dylib`/`.so` needs no separate
import lib). Bazel's `cc_import` in `BUILD.bazel` picks them up. Pinned to
GPAC commit `9edee648038ff542530b7a9f0392801ae88ea915` (26.08-DEV,
2026-09-17, master at the time; includes gpac/gpac#3669, which flushes
IAMF samples as SAP 1 so the muxed IAMF track no longer carries a
spec-forbidden empty `stss` box).

Both scripts apply the patches in `patches/` to the checkout before
configuring it; `patches/README.md` lists what each one changes and its
upstream status. The build scripts' freshness stamp covers the recipe and
the patches, so adding or editing a patch rebuilds the library on the next
`./build.sh` / `.\build.ps1`; run `build_gpac.sh` by hand to rebuild sooner. The shipped libgpac is therefore the pinned commit plus
those patches, which `third_party/gpac/NOTICE` states for the LGPL
section 6 source offer.

The Windows recipe mirrors the macOS one: it configures GPAC the same way
(`--static-bin --use-curl=no`) under MSYS2/mingw-w64, links the static
archive into a self-contained `libgpac.dll`, then uses MSVC `lib.exe` to
synthesize `gpac.lib` from the DLL's module-definition file (the engine is
MSVC-built and can't consume a MinGW import lib). See the header comment in
`build_gpac.ps1` for the toolchain prerequisites.

## Packaging status

- **macOS:** `./build.sh` embeds `lib/libgpac.dylib` beside
  `libeclipsa_studio_engine.dylib` in `Contents/Frameworks` (resolved via
  `@rpath`), and `./build.sh package` signs it (hardened runtime and
  timestamp) and notarizes it with the app (ES-134).
- **Windows:** `build_gpac.ps1` builds `libgpac.dll` and the MSVC import
  `gpac.lib`, `BUILD.bazel`'s `cc_import` carries the Windows
  `interface_library`, and `build.ps1`'s `Ensure-Gpac` vendors and stages
  the DLL beside the engine (ES-209). The Windows CI job builds it this way
  on a runner with MSYS2 and the VS C++ toolset.
- **Third-party notices:** `third_party/gpac/NOTICE` and
  `third_party/gpac/LICENSE.LGPL-2.1.txt` carry the LGPL attribution and
  the section-6 relink provision, pulled into
  `third_party/THIRD_PARTY_NOTICES.txt` and the in-app licenses page by
  `scripts/collect_third_party_notices.py` (part of ES-57).
- **Size:** the force-loaded dylib is about 8 MB; a native GPAC shared-lib
  build would be smaller. Revisit if bundle size matters.
