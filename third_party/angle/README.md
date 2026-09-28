# ANGLE — license and notice texts

Attribution files for the ANGLE GL translation layer (`libEGL`,
`libGLESv2`) that the 3D renderer draws through. No upstream source is
checked in here.

| File | What it is |
|------|------------|
| `NOTICE` | Project-authored. Records what ships on each platform, the dynamic-linking arrangement and the Windows build's pinned commit. |
| `LICENSE` | Upstream ANGLE license text, BSD 3-Clause, verbatim from the pinned commit. |
| `LICENSE.xxhash` | Upstream xxHash license text, BSD 2-Clause, verbatim from `src/common/third_party/xxhash/LICENSE` at the pinned ANGLE commit. |
| `LICENSE.zlib` | Upstream zlib license text, verbatim from `third_party/zlib/LICENSE` in the pinned ANGLE checkout (Chromium's zlib at `8b3aa8a1cd7585c0c4c67351481227b046a662a0`). |
| `LICENSE.chromium` | The Chromium Authors' BSD 3-Clause text, verbatim from `buildtools/LICENSE` in the pinned ANGLE checkout. It covers the Chromium-authored files in Chromium's zlib, which point to "the Chromium source repository LICENSE file". |

Where the binaries come from:

- **macOS**: the `flutter_angle` pub package (a `three_js` dependency)
  bundles `libEGL.framework` and `libGLESv2.framework` into the app.
- **Windows**: `build.ps1 package` replaces the package's debug
  binaries with release builds produced by
  `engine/deps/angle/build_angle.ps1` at the commit `METADATA` records
  (issue ES-372 explains why).

The Windows DLLs statically link xxHash (both) and Chromium's zlib
(`libGLESv2.dll`), so their texts ship with ANGLE's. The gn args in
`build_angle.ps1` turn off the Vulkan and WebGPU backends, Vulkan GPU
identification, Abseil and astc-encoder, which would otherwise add
VulkanMemoryAllocator, volk, SPIRV-Tools, Dawn, Tint, Abseil and
astc-encoder to `libGLESv2.dll` (ES-735). To see what a configuration
links, read the `solink` line for `libGLESv2.dll` in
`out\Release\obj\libGLESv2.ninja` after `gn gen`.

BSD 3-Clause requires a binary redistribution to reproduce the copyright
notice, the conditions and the disclaimer in the material shipped with
it, so the text is embedded in `third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json` rather than linked.
`scripts/collect_third_party_notices.py` reads both files; verify with
`python3 scripts/collect_third_party_notices.py --check`.

Keep the commit in `NOTICE` and `METADATA` in lockstep with `$AngleCommit`
in `engine/deps/angle/build_angle.ps1`.
