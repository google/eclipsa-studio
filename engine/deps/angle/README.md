# Vendored release ANGLE (Windows)

Release builds of `libEGL.dll` / `libGLESv2.dll` for the Windows package.

The 3D visualizer's `flutter_angle` pub package (a `three_js` dependency)
bundles **debug** ANGLE binaries plus the **debug Microsoft CRT**
(`ucrtbased.dll` & friends) into every Windows build — see issue ES-372. The
debug CRT is not redistributable under the Visual Studio license, and debug
ANGLE is markedly slower than release ANGLE. `build.ps1 package` therefore
replaces the staged flutter_angle DLL set with the release binaries vendored
here, and its `Assert-NoDebugCrt` gate fails the package if any staged
binary still ships or imports the debug CRT.

Produce the binaries with:

```powershell
.\build_angle.ps1
```

This follows ANGLE's official build procedure (depot_tools + gn + autoninja)
at the commit pinned in the script; see the script header for prerequisites.
Outputs land in `bin\` (git-ignored, like the `gpac/` and `ffmpeg/` vendored
builds), with `BUILD_CONFIG` recording the commit and gn args they were built
from. `build.ps1 package` refuses DLLs whose `BUILD_CONFIG` does not match
what the script pins (`.\build_angle.ps1 -PrintConfig`), so re-run the
script after changing either. The multi-GB checkout is kept under `work\`
for incremental rebuilds.

The gn args switch off the backends and libraries the app does not use, so
the DLLs statically link only ANGLE's own code, xxHash, Chromium's zlib and
the LLVM runtime (ES-735). Their license texts are in `third_party/angle/`;
a change to the gn args that links anything else needs its text added
there and in `scripts/collect_third_party_notices.py`.
