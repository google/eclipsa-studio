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

"""Generate app/lib/widgets/eclipsa_audio_wordmark_data.dart.

The Eclipsa Audio wordmark is "Eclipsa Audio" set in Google Sans at
weight 400. The app draws it as vector outlines rather than as text,
so it does not bundle the 5 MB variable font for twelve glyphs. This
script reads those twelve glyphs out of the font, instanced at
wght=400, opsz=18, GRAD=0 (the font's default instance), and writes
them as a Dart constant: one outline per glyph in font units, y up,
plus the pen position each glyph sits at in the lockup.

The pen positions are not the font's advances. They place each glyph
in the lockup, in font units from the left edge of the symbol's box,
and set the lockup's spacing; GLYPHS below holds them.

Google Sans is licensed under the SIL Open Font License 1.1 with no
Reserved Font Name; third_party/fonts/google_sans/ carries the licence
text and the provenance.

Usage (needs fontTools; the font is not checked in):
    python3 scripts/gen_eclipsa_audio_wordmark.py --font <path to
        'GoogleSans[GRAD,opsz,wght].ttf' from google/fonts ofl/googlesans>
    python3 scripts/gen_eclipsa_audio_wordmark.py --font ... --check
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from fontTools.pens.basePen import BasePen
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
except ImportError:  # pragma: no cover
    sys.exit("fontTools is required: pip install fonttools")

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "app/lib/widgets/eclipsa_audio_wordmark_data.dart"

# The font file this was last generated from, for the record in the
# output header.
UPSTREAM = "google/fonts ofl/googlesans, commit 5412d702"
INSTANCE = {"wght": 400, "opsz": 18, "GRAD": 0}

# (character, pen x in font units from the symbol box's left edge).
# The space between "Eclipsa" and "Audio" is in the positions.
GLYPHS = [
    ("E", 1817),
    ("c", 2313),
    ("l", 2810),
    ("i", 2998),
    ("p", 3183),
    ("s", 3740),
    ("a", 4171),
    ("A", 4903),
    ("u", 5534),
    ("d", 6055),
    ("i", 6616),
    ("o", 6801),
]

# The output is a Modified Version of the Font Software in the sense of
# the SIL Open Font License (twelve outlines transcribed into Dart), so
# it carries the OFL, not the Apache header the rest of the repository
# uses; the release gate's header check exempts it.
HEADER = """// Copyright 2025 The Google Sans Project Authors
// (https://github.com/googlefonts/googlesans)
// Copyright 2026 Google LLC (the Dart transcription)
//
// SPDX-License-Identifier: OFL-1.1
//
// This Font Software is licensed under the SIL Open Font License,
// Version 1.1. The license text is in third_party/fonts/google_sans/
// LICENSE and, with a FAQ, at https://openfontlicense.org. This file is
// a Modified Version of the Font Software under that license: the
// outlines of twelve Google Sans glyphs transcribed into Dart. It is not
// under the Apache License 2.0 that covers the rest of this repository.

// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Regenerate with scripts/gen_eclipsa_audio_wordmark.py, which reads
// the glyphs out of Google Sans ({upstream}), instanced at
// {instance}. The pen positions are set in the script, not taken
// from the font's advances.

/// One glyph of the Eclipsa Audio wordmark.
class EclipsaAudioGlyph {{
  const EclipsaAudioGlyph(this.char, this.penX, this.outline);

  /// The character, for reading the table.
  final String char;

  /// Where the glyph's origin sits, in font units from the left edge
  /// of the symbol's box.
  final int penX;

  /// The outline in font units with y up, as a flat list of records:
  /// `0, x, y` moves, `1, x, y` draws a line, `2, cx, cy, x, y` draws
  /// a quadratic curve through control point (cx, cy), and `3` closes
  /// the contour. Fill with the non-zero rule.
  final List<int> outline;
}}


/// Cap height in font units. The lockup sets it at 190/324 of the
/// symbol's height.
const int kEclipsaAudioCapHeight = {cap};

/// The right edge of the last glyph's ink, in font units from the
/// symbol box's left edge.
const int kEclipsaAudioWordmarkRight = {right};

const List<EclipsaAudioGlyph> kEclipsaAudioGlyphs = [
"""


class _RecordPen(BasePen):
    """Flattens a glyph into the move/line/quad/close records above."""

    def __init__(self, glyph_set):
        super().__init__(glyph_set)
        self.records = []

    def _moveTo(self, pt):
        self.records += [0, round(pt[0]), round(pt[1])]

    def _lineTo(self, pt):
        self.records += [1, round(pt[0]), round(pt[1])]

    def _qCurveToOne(self, c, pt):
        self.records += [2, round(c[0]), round(c[1]), round(pt[0]), round(pt[1])]

    def _curveToOne(self, c1, c2, pt):
        raise ValueError("cubic segment in a TrueType glyph")

    def _closePath(self):
        self.records.append(3)


def generate(font_path):
    font = TTFont(font_path)
    font = instancer.instantiateVariableFont(font, INSTANCE, inplace=False)
    glyph_set = font.getGlyphSet()
    cmap = font.getBestCmap()
    hmtx = font["hmtx"]
    cap = font["OS/2"].sCapHeight

    entries = []
    right = 0
    for char, pen_x in GLYPHS:
        name = cmap[ord(char)]
        pen = _RecordPen(glyph_set)
        glyph_set[name].draw(pen)
        xs = []
        i = 0
        r = pen.records
        while i < len(r):
            if r[i] == 3:
                i += 1
            elif r[i] == 2:
                xs += [r[i + 1], r[i + 3]]
                i += 5
            else:
                xs.append(r[i + 1])
                i += 3
        right = max(right, pen_x + max(xs))
        entries.append((char, pen_x, hmtx[name][0], r))

    out = HEADER.format(
        upstream=UPSTREAM,
        instance=", ".join(f"{k}={v}" for k, v in INSTANCE.items()),
        cap=cap,
        right=right,
    )
    for char, pen_x, advance, records in entries:
        out += f"  // '{char}', advance {advance}\n"
        out += f"  EclipsaAudioGlyph('{char}', {pen_x}, [\n"
        line = "   "
        for v in records:
            piece = f" {v},"
            if len(line) + len(piece) > 80:
                out += line + "\n"
                line = "   "
            line += piece
        out += line + "\n  ]),\n"
    out += "];\n"
    return dart_format(out)


def dart_format(text):
    """Run the emitted source through dart format, as the other
    generators do: without it the drift gate and `lint --check` fight,
    since the formatter rewrites what the generator wrote."""
    dart = shutil.which("dart")
    if not dart:
        sys.exit("`dart` is not on PATH; this script needs `dart format`")
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / TARGET.name
        p.write_text(text, encoding="utf-8")
        r = subprocess.run([dart, "format", str(p)], capture_output=True)
        if r.returncode != 0:
            sys.exit(f"dart format failed: {r.stderr.decode().strip()}")
        return p.read_text(encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--font", required=True, help="path to the Google Sans variable TTF")
    ap.add_argument("--check", action="store_true", help="verify the committed file is current")
    args = ap.parse_args()

    out = generate(args.font)
    if args.check:
        current = TARGET.read_text() if TARGET.exists() else ""
        if current != out:
            sys.exit(f"{TARGET.relative_to(REPO)} is stale; regenerate it.")
        print(f"{TARGET.relative_to(REPO)} is current.")
        return
    TARGET.write_text(out)
    print(f"wrote {TARGET.relative_to(REPO)}")


if __name__ == "__main__":
    main()
