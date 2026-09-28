# FFmpeg + dav1d — license and notice texts

Attribution files for the FFmpeg-in-engine video backend
(`engine/video/`, ES-249). No upstream source is checked in here: the
libraries are built from the pins in `engine/deps/ffmpeg/build_ffmpeg.sh`
and `build_ffmpeg.ps1`, and staged beside the engine at build time.

| File | What it is |
|------|------------|
| `NOTICE` | Project-authored. Records the pinned versions, the dynamic-linking arrangement, and the LGPL-2.1 section 6 relink provision. |
| `LICENSE.LGPL-2.1.txt` | Upstream GNU LGPL 2.1 text (FFmpeg). |
| `LICENSE.dav1d.txt` | Upstream BSD 2-Clause text (dav1d). |

Both libraries are linked **dynamically** and ship as separate shared
libraries — `libav*.dylib` in `Eclipsa Studio.app/Contents/Frameworks`
on macOS, `avcodec-*.dll` and siblings beside
`eclipsa_studio_engine.dll` on Windows. Nothing from FFmpeg or dav1d is
statically linked into the engine. The FFmpeg build is configured
without `--enable-gpl` and without `--enable-nonfree`.

Keep the versions in `NOTICE` in lockstep with the pins in
`engine/deps/ffmpeg/build_ffmpeg.{sh,ps1}`.
`scripts/collect_third_party_notices.py` reads all three files into
`third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json`; verify with
`python3 scripts/collect_third_party_notices.py --check`.
