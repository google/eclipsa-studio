# GPAC (libgpac) — license and notice texts

Attribution files for the MP4 muxer behind "Export to MP4"
(`engine/iamf/iamf_muxer.cc`). No upstream source is checked in here: the
library is built from the commit pinned in
`engine/deps/gpac/build_gpac.sh` and `build_gpac.ps1`, and staged beside
the engine at build time.

| File | What it is |
|------|------------|
| `NOTICE` | Project-authored. Records the pinned commit, the dynamic-linking arrangement, and the LGPL-2.1 section 6 relink provision. |
| `LICENSE.LGPL-2.1.txt` | Upstream GNU LGPL 2.1 text. |

libgpac is linked **dynamically** and ships as a separate shared library
(`libgpac.dylib` on macOS, `libgpac.dll` beside
`eclipsa_studio_engine.dll` on Windows), which is what the section 6
relink provision in `NOTICE` covers.

Keep the commit in `NOTICE` in lockstep with the pin in
`engine/deps/gpac/build_gpac.{sh,ps1}`.
`scripts/collect_third_party_notices.py` reads both files into
`third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json`; verify with
`python3 scripts/collect_third_party_notices.py --check`.
