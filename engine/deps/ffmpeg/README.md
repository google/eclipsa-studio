# Vendored FFmpeg (+ dav1d) — the FFmpeg-in-engine video backend

The `//video` decoder (issue ES-249) decodes reference video with FFmpeg and
exposes "frame at time T" over a C FFI. This directory vendors a **pinned,
minimal, LGPL** FFmpeg build plus **dav1d** (fast AV1), linked dynamically and
shipped inside the app bundle — mirroring how [`../gpac`](../gpac) is vendored.

Built for macOS/arm64 (`build_ffmpeg.sh`) and Windows/x64
(`build_ffmpeg.ps1`, staged via `build.ps1`'s `Ensure-Ffmpeg`); the
engine's `select()` on `//video:video_ffi` in `engine/BUILD.bazel`
covers both OSes (OS scoping on the app side lives in
`app/lib/video/video_backend_kind.dart`).

## Recipe

`build_ffmpeg.sh` builds both from source at pinned release tags and stages
them here (git-ignored — produced, not checked in):

```
lib/libavutil.dylib  libavcodec.dylib  libavformat.dylib
lib/libswscale.dylib libswresample.dylib  libdav1d.dylib
include/             the public libav*/ , libsw*/ headers
```

`build.sh`'s `ensure_ffmpeg` runs the script once (skipping when the outputs
are present); delete `lib/` to force a rebuild. It needs `nasm`, `meson`,
`ninja`, and `pkg-config` (the script `brew install`s any that are missing).

## Licensing posture

FFmpeg is configured **without** `--enable-gpl` / `--enable-nonfree`, so the
build carries only LGPL-2.1 code, and it is decode-only (no encoders, muxers,
avdevice, avfilter, postproc, or networking) with `--disable-autodetect` so it
pulls in **no** external library other than dav1d (BSD-2) and system
frameworks. Every dylib has an `@rpath` install name and is copied into
`Eclipsa Studio.app/Contents/Frameworks` (build.sh `embed_engine_libs`), so
the LGPL libraries ship as separate, user-replaceable shared libraries — see
`third_party/ffmpeg/NOTICE` (relink provision),
`third_party/ffmpeg/LICENSE.LGPL-2.1.txt` and
`third_party/ffmpeg/LICENSE.dav1d.txt`.

`build_ffmpeg.sh` verifies each staged dylib depends only on `@rpath` siblings
and system libraries (no `/opt/homebrew`, no GPL codecs), and the notices gate
(`scripts/collect_third_party_notices.py --check`) covers the attribution.

## Bazel

`BUILD.bazel` `cc_import`s each dylib and wraps them with the headers as
`//deps/ffmpeg:ffmpeg`, which `//video:video_decoder` depends on. All
targets are `manual`: they are pulled in only by the engine's per-OS
`select()` on `//video:video_ffi` (macOS and Windows), never built
standalone by a `//...` wildcard on a checkout where the vendored
libraries may be absent.
