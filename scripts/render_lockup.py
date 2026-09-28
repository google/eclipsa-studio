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

"""Render the lockup, the cube mark beside the wordmark, as PNGs.

Writes app/design/brand/png/eclipsa-studio-lockup.png (the dark set on its plate),
eclipsa-studio-lockup-light.png (the light set) and eclipsa-studio-lockup-stacked.png
(the two panels one above the other). The layout follows the lockup
masters gen_app_icon.py writes: "Eclipsa" in the ink and " Studio" in
the accent, Inter at weight 600, type 0.515x the mark's 58-unit box with
-2% letter spacing, a 21-unit pad and a 20-unit gap, all at 3 px per
unit; the colours and those numbers are gen_app_icon's own constants. Pad, gap and the vertical centring are measured from the cube's
visible silhouette and the word's cap-height band in the rendered
pixels, not from box or font metrics.

This is separate from gen_app_icon.py because rasterising text needs
a font engine: it needs rsvg-convert and ImageMagick 7 (`magick`) on
PATH and sets the type from the font file the app bundles, so the
output is Inter whatever fonts are installed. It is not a CI gate;
re-run it after `./build.sh gen-icon` changes the cube masters.
"""

import subprocess
import tempfile
from pathlib import Path

import gen_app_icon as brand

REPO = brand.REPO
BRAND = brand.BRAND
# Inter at LOCKUP_WEIGHT (600); the file the app bundles.
FONT = REPO / "app/assets/fonts/Inter-SemiBold.ttf"

SETS = {
    "dark": dict(brand.DARK, svg=BRAND / "eclipsa-studio-mark.svg",
                 out=BRAND / "png/eclipsa-studio-lockup.png"),
    "light": dict(brand.LIGHT, svg=BRAND / "eclipsa-studio-mark-light.svg",
                  out=BRAND / "png/eclipsa-studio-lockup-light.png"),
}
STACKED = BRAND / "png/eclipsa-studio-lockup-stacked.png"

SCALE = 3  # px per master unit
MARK = brand.LIVE_SPAN * SCALE  # the mark master's box
POINT = round(brand.LIVE_SPAN * brand.LOCKUP_TYPE_RATIO * SCALE)
PAD = brand.LOCKUP_PAD * SCALE
GAP = brand.LOCKUP_GAP * SCALE


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def _opaque(png, axis, crop=None):
    """The opaque rows (axis "y") or columns ("x") of a PNG's alpha."""
    args = ["magick", str(png)]
    if crop:
        args += ["-crop", crop, "+repage"]
    args += ["-alpha", "extract", "-scale", "1x!" if axis == "y" else "x1!",
             "-depth", "8", "txt:-"]
    hits = []
    for line in subprocess.check_output(args).decode().splitlines()[1:]:
        coords, value = line.split(":", 1)
        x, y = (int(v) for v in coords.split(","))
        if int(value.strip().lstrip("(").split(",")[0].split(")")[0]) > 0:
            hits.append(y if axis == "y" else x)
    return hits


def _extent(png, axis, crop=None):
    hits = _opaque(png, axis, crop)
    return min(hits), max(hits)


def _cap_band(text):
    """Rows of the cap-height band: the first glyph, "E", is flat top
    and bottom, so its rows are the band exactly."""
    cols = _opaque(text, "x")
    end = cols[0]
    while end + 1 in cols:
        end += 1
    h = int(subprocess.check_output(
        ["magick", str(text), "-format", "%h", "info:"]))
    return _extent(text, "y", f"{end - cols[0] + 1}x{h}+{cols[0]}+0")


def panel(name, c, tmp):
    mark = tmp / f"{name}-mark.png"
    run("rsvg-convert", "-w", MARK, "-h", MARK, c["svg"], "-o", mark)
    text = tmp / f"{name}-text.png"
    run("magick", "-background", "none", "-font", FONT, "-pointsize", POINT,
        "-kerning", -0.02 * POINT,
        "-fill", c["ink"], "label:Eclipsa",
        # A no-break space: ImageMagick strips a leading plain space
        # from a label.
        "-fill", c["accent"], "label: Studio",
        "+append", "-trim", "+repage", text)
    text_w = int(subprocess.check_output(
        ["magick", str(text), "-format", "%w", "info:"]))
    mark_left, mark_right = _extent(mark, "x")
    mark_top, mark_bottom = _extent(mark, "y")
    band_top, band_bottom = _cap_band(text)
    mark_centre = PAD + (mark_bottom - mark_top) / 2
    text_x = PAD + (mark_right - mark_left + 1) + GAP
    top = mark_centre - (band_top + band_bottom) / 2
    width = text_x + text_w + PAD
    height = PAD + (mark_bottom - mark_top + 1) + PAD
    run("magick", "-size", f"{width:.0f}x{height}", f"xc:{c['plate']}",
        mark, "-geometry", f"+{PAD - mark_left}+{PAD - mark_top}", "-composite",
        text, "-geometry", f"+{text_x}+{top:.0f}", "-composite",
        # No date chunks, so a re-run with the same inputs is the same
        # bytes and git sees no change.
        "-define", "png:exclude-chunks=date,time", c["out"])
    return c["out"]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        panels = [panel(name, c, Path(tmp)) for name, c in SETS.items()]
    run("magick", *panels, "-background", "none", "-append",
        "-define", "png:exclude-chunks=date,time", STACKED)
    for path in panels + [STACKED]:
        print(f"wrote {path.relative_to(REPO)}")


if __name__ == "__main__":
    main()
