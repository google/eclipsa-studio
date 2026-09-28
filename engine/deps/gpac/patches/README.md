# Local GPAC patches

`build_gpac.sh` and `build_gpac.ps1` apply every `*.patch` here, in name
order, to the pinned GPAC checkout before configuring it (`git apply`, so
a patch that no longer fits the pin fails the build). Each patch is a
`git diff` against the pinned commit and changes one thing. Drop a patch
when a pin bump picks up the upstream fix.

| Patch | What it changes | Upstream |
|---|---|---|
| `0001-stts-box-size-check-uses-entry-count-from-file.patch` | `stts_box_read` in `src/isomedia/box_code_base.c`: the box-size check at the end of the reader uses the entry count read from the file. GPAC rewrites a zero-duration `stts` entry on read and, since gpac/gpac#3422 (merged 2026-01-08), may split an earlier entry to do so, which increments the in-memory entry count; the unpatched check then demands 8 bytes more than the box holds and rejects the file as an invalid ISO media file. VLC 4.0's stream output writes such a table (two samples at duration 0 at the end), so its MP4s could not be exported (#742). | Reported as gpac/gpac#3924 with the fix. Drop the patch when a pin bump includes it. |

The engine test `engine/test/iamf_muxer_test.cc` covers patch 0001 with
`engine/test/fixtures/stts_zero_tail_h264.mp4`; it fails against a
libgpac built without the patch.
