#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Writes engine/test/fixtures/stts_zero_tail_h264.mp4.

The fixture reproduces the sample table VLC 4.0's stream output writes
(ES-742): the `stts` box ends with an entry of two samples at duration 0.
The ISOBMFF spec allows a zero duration on the last sample only, and
GPAC rewrites such an entry on read. GPAC at the pinned commit then
checks the box size against the rewritten entry count and rejects the
file; engine/deps/gpac/patches/0001-*.patch fixes that, and
engine/test/iamf_muxer_test.cc keeps the fix covered with this file.

Steps: encode 12 frames of ffmpeg's testsrc at 64x64 as H.264 in an MP4
with the `moov` box after `mdat` (ffmpeg's default, so growing `moov`
moves no chunk offsets), then rewrite the single stts entry (12 samples
at 512 ticks) as two entries, 10 at 512 and 2 at 0, and add 8 bytes to
the size of stts and of each box that contains it. The video decodes
with the last two frames at the previous frame's time.

Requires ffmpeg on PATH. Run from anywhere:

    python3 engine/tools/generate_stts_fixture.py
"""

import os
import struct
import subprocess
import sys
import tempfile

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "test", "fixtures", "stts_zero_tail_h264.mp4",
)
FRAMES = 12
CONTAINERS = (b"moov", b"trak", b"mdia", b"minf", b"stbl")


def find_boxes(data, start, end):
    """Yields (type, offset, size) for the boxes between start and end."""
    off = start
    while off + 8 <= end:
        size, typ = struct.unpack(">I4s", data[off:off + 8])
        if size == 1:
            size = struct.unpack(">Q", data[off + 8:off + 16])[0]
        elif size == 0:
            size = end - off
        yield typ, off, size
        off += size


def path_to_stts(data):
    """Returns the offsets of moov, trak, mdia, minf, stbl and stts."""
    chain = []
    start, end = 0, len(data)
    for want in CONTAINERS + (b"stts",):
        found = None
        for typ, off, size in find_boxes(data, start, end):
            if typ == want:
                found = (off, size)
                break
        if found is None:
            sys.exit(f"box {want.decode()} not found")
        chain.append(found)
        start, end = found[0] + 8, found[0] + found[1]
    return chain


def main():
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src.mp4")
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-v", "error", "-y",
                "-f", "lavfi", "-i", "testsrc=size=64x64:rate=24:duration=0.5",
                "-frames:v", str(FRAMES), "-c:v", "libx264", "-preset",
                "ultrafast", "-g", "6", "-pix_fmt", "yuv420p",
                "-video_track_timescale", "12288", src,
            ],
            check=True,
        )
        with open(src, "rb") as f:
            data = bytearray(f.read())

    # Growing moov by 8 bytes is only safe when it follows mdat; a moov
    # written first (`-movflags +faststart`) would shift every chunk
    # offset in stco.
    top = {typ: off for typ, off, _ in find_boxes(data, 0, len(data))}
    if b"moov" not in top or b"mdat" not in top or top[b"moov"] < top[b"mdat"]:
        sys.exit("expected moov after mdat; refusing to grow it")

    chain = path_to_stts(data)
    stts_off, stts_size = chain[-1]
    version_flags = data[stts_off + 8:stts_off + 12]
    entry_count = struct.unpack(">I", data[stts_off + 12:stts_off + 16])[0]
    if entry_count != 1:
        sys.exit(f"expected one stts entry from ffmpeg, got {entry_count}")
    count, delta = struct.unpack(">II", data[stts_off + 16:stts_off + 24])
    if count != FRAMES:
        sys.exit(f"expected {FRAMES} samples, got {count}")

    new_stts = (
        struct.pack(">I4s", stts_size + 8, b"stts")
        + version_flags
        + struct.pack(">I", 2)
        + struct.pack(">II", count - 2, delta)
        + struct.pack(">II", 2, 0)
    )
    data[stts_off:stts_off + stts_size] = new_stts
    for off, size in chain[:-1]:
        if struct.unpack(">I", data[off:off + 4])[0] != size:
            sys.exit("container box uses a size form this script cannot grow")
        data[off:off + 4] = struct.pack(">I", size + 8)

    with open(OUT, "wb") as f:
        f.write(data)
    print(f"wrote {os.path.relpath(OUT)} ({len(data)} bytes, "
          f"stts {count - 2}x{delta} + 2x0)")


if __name__ == "__main__":
    main()
