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

"""Generate the brand vector masters and the platform app icons.

The geometry below is the single source for every generated artifact:
the SVG masters and PNG exports under app/design/brand in both colour sets
(for a dark ground and for a light one), the seven macOS PNGs and the
Windows .ico. A logo change is an edit here plus a re-run, not a round
of manual exports -- which is the point of having this script rather
than committed one-off output.

The mark is the E and the S projected onto the two front walls of an
isometric cube. `app/lib/widgets/eclipsa_studio_mark.dart` carries the same
geometry for the on-screen mark, because a Dart painter cannot read
this file at build time; `app/test/eclipsa_studio_mark_asset_test.dart`
parses the generated master and fails if the two ever disagree.

The lockup masters carry the wordmark as SVG text in Inter, the face
the app bundles, so a viewer without Inter substitutes another face;
there is no PNG lockup here, because rasterising text needs a font
engine and this script deliberately needs nothing beyond Python 3
(scripts/render_lockup.py draws one with ImageMagick).

The macOS icon is delivered twice. AppIcon.icon is an Icon Composer
document, a package of icon.json plus one SVG per layer, which macOS
26 renders with the system's glass treatment on the dots and, for the
tinted and clear looks, from the layers' shapes. Xcode 26 and later
compile it through the same actool call as the catalog, and with it
in the project actool writes the bundle's AppIcon.icns from it, which
is what macOS before 26 shows. AppIcon.appiconset is the PNG set; it
is what the project falls back to without the document. Both carry
the dark set alone: the document's fills are plain `fill` values with
no `-specializations` list, so macOS 26 draws the same plate and
letters in Light mode and in Dark mode. A layer's fill recolours its
image, so each layer is one SVG drawn in black.

Rasterising is done here rather than by shelling out to rsvg-convert
or ImageMagick, so the icons regenerate identically on macOS, Windows
and CI with nothing installed beyond Python 3. Coverage antialiasing
is analytic: every shape is a rounded rectangle or an affine image of
a circle, so a signed distance (first order, for the ellipses) gives
exact-enough per-pixel coverage without supersampling.

Usage:
    gen_app_icon.py              write the masters and the icons
    gen_app_icon.py --check      verify the committed files are current
"""

import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BRAND = REPO / "app/design/brand"
MACOS_ICONSET = REPO / "app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
MACOS_ICON_PACKAGE = REPO / "app/macos/Runner/AppIcon.icon"
WINDOWS_ICO = REPO / "app/windows/runner/resources/app_icon.ico"

# ---------------------------------------------------------------- geometry
#
# The mark lives in a 100-unit box whose live area is the 58x58 square
# running 21..79. Its cell grid is the one of the earlier 5x5 dot-matrix
# monogram: centres at 26/38/50/62/74 across that square, radius 5,
# which leaves a 2-unit gap.

POSITIONS = [26, 38, 50, 62, 74]
CELL_RADIUS = 5
LIVE_START = 21
LIVE_SPAN = 58

# The unlit field on the top face: one fixed grey in both colour sets,
# Dark's text ink at 40% over its body. The app's painter
# (eclipsa_studio_mark.dart, kFieldColor) uses the same value.
FIELD_COLOUR = "#64636A"

# An isometric cube seen from a corner: top face, left wall, right
# wall. The E is drawn in the plane of the left wall in the ink, the S
# in the plane of the right wall in the accent, and the top face
# carries a 5x5 field of unlit cells, which is what shows the cube.
# The cube is LIVE_SPAN tall, so its edge is 29 units and it is 50.2
# wide. Each face carries the 5x5 grid scaled to fill the face to a 4%
# margin; the walls draw lit cells only.
#
# Face space is a 100-unit square per face. Each face's matrix maps it
# onto the face's parallelogram: x runs along the face's top edge and
# y down its vertical (on the top face, along its other edge). Written
# as SVG matrix(a b c d e f): x' = a*x + c*y + e, y' = b*x + d*y + f.

CUBE_EDGE = LIVE_SPAN / 2
_COS30 = math.sqrt(3) / 2
_K = CUBE_EDGE / 100
_HALF_W = CUBE_EDGE * _COS30
_MID_Y = LIVE_START + CUBE_EDGE  # top of the cube's front vertical edge
CUBE_FACES = {
    "top": (_COS30 * _K, 0.5 * _K, _COS30 * _K, -0.5 * _K, 50 - _HALF_W,
            _MID_Y - 0.5 * CUBE_EDGE),
    "left": (_COS30 * _K, 0.5 * _K, 0, _K, 50 - _HALF_W,
             _MID_Y - 0.5 * CUBE_EDGE),
    "right": (_COS30 * _K, -0.5 * _K, 0, _K, 50, _MID_Y),
}

# The letters on a 5x5 grid, row by row.
E_ROWS = ["11111", "10000", "11110", "10000", "11111"]
S_ROWS = ["11111", "10000", "11111", "00001", "11111"]

# The grid fills the face to this margin on every side. At 2% the E
# and the S touch along the cube's front edge.
FIELD_MARGIN = 0.04
_FIELD_SCALE = 100 * (1 - 2 * FIELD_MARGIN) / LIVE_SPAN
FIELD_POSITIONS = [
    100 * FIELD_MARGIN + (p - LIVE_START) * _FIELD_SCALE for p in POSITIONS
]
FIELD_RADIUS = CELL_RADIUS * _FIELD_SCALE

# What each face draws: the kind names the colour (the ink for the E
# and the field, the accent for the S) and the field's opacity.
CUBE_LAYERS = (
    ("top", "field", "the unlit field"),
    ("left", "e", "the E"),
    ("right", "s", "the S"),
)

# ------------------------------------------------------------------ colour
#
# Two colour sets, one per ground. The dark set is the default
# theme's: Dark's bgBase for the plate, its textPrimary for the E
# and its pink for the S, read from app/design/tokens/dark.tokens.json so the
# Dock icon, the brand lockup and the landing screen agree. The light
# set is for a light ground (a page, a slide) and is fixed here.


def _theme_colour(tokens, name):
    """The `$value` of the token called `name` anywhere in a DTCG file."""
    if isinstance(tokens, dict):
        if name in tokens and isinstance(tokens[name], dict):
            return tokens[name]["$value"]
        for value in tokens.values():
            found = _theme_colour(value, name)
            if found:
                return found
    return None


_THEME_D = json.loads(
    (REPO / "app/design/tokens/dark.tokens.json").read_text(encoding="utf-8")
)
DARK = {
    "name": "dark",
    "plate": _theme_colour(_THEME_D, "bgBase"),
    "ink": _theme_colour(_THEME_D, "textPrimary"),  # the E
    "accent": _theme_colour(_THEME_D, "pink"),  # the S
}
LIGHT = {
    "name": "light",
    "plate": "#F5F3EE",  # warm off-white
    "ink": "#18181B",  # the E: 15.98:1 on the plate
    "accent": "#BE185D",  # the S: 5.44:1 on the plate
}
COLOUR_SETS = (DARK, LIGHT)

# --------------------------------------------------------------- icon board
#
# macOS Big Sur grid: a 1024 art board with the visible plate 824 wide
# and centred, corner radius 22.5% of the plate. The cube's silhouette
# (the extent of its dots, not its 58-unit box: the dots stop short of
# the box on every side) is MARK_SPAN of the plate tall and centred.

BOARD = 1024
PLATE_SIZE = 824
PLATE_CORNER = 0.225
MARK_SPAN = 0.72

# The sizes Contents.json names, 1x and 2x collapsed to the distinct
# pixel sizes it actually references.
MACOS_SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Windows shells pick the nearest of these. 256 is the one Explorer
# uses for large icons; 16 and 32 carry the title bar and taskbar.
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

# The Windows icon fills its square. Windows draws no plate of its own
# and shows the icon at 16 to 32 px in the taskbar and the notification
# area, where the macOS grid's margin and 72% cube left a cube 9 px tall
# at 16 px. Here the plate is the whole board with 18% corners and the
# cube spans 84% of it. The plate stays: without it the E, in the dark
# set's textPrimary, disappears on a light taskbar.
WINDOWS_PLATE_SIZE = BOARD
WINDOWS_PLATE_CORNER = 0.18
WINDOWS_MARK_SPAN = 0.84

# The brand PNG exports of the icon board, per colour set.
BRAND_PNG_SIZES = [256, 1024]

# ------------------------------------------------------------------ lockup
#
# The cube beside the wordmark on its plate, in a 100-unit-tall box:
# the cube's silhouette LOCKUP_PAD in from the left and centred
# vertically, the type LOCKUP_GAP to its right, "Eclipsa" in the E's
# ink and " Studio" in the S's, at weight 600 in Inter. The type is
# 0.515x the cube's 58-unit box (the matrix-mark lockup used 1.24x,
# the first cube lockup 0.8x and the next 0.56x, which drew the mark
# light beside the wordmark, ES-755; the cube's silhouette is lighter
# than its box, and the app's lockup uses the same ratio) with -2%
# letter spacing, and its cap-height band is centred on the cube. The
# type size is rounded to whole units, 30 of the box's 58. The box
# width is sized for Inter, whose "Eclipsa Studio" at that tracking is
# 6.47 em wide; another face lands the text a little short or long of
# the right margin.

LOCKUP_FONT = "Inter, system-ui, sans-serif"
LOCKUP_WEIGHT = 600
LOCKUP_HEIGHT = 100
LOCKUP_PAD = 21
LOCKUP_GAP = 20
LOCKUP_TYPE_RATIO = 0.515
LOCKUP_TEXT_EM = 6.47
INTER_CAP_HEIGHT = 1490 / 2048  # Inter 4's capHeight


def cube_cells(face):
    """Yield (fx, fy) in face space for the cells one face draws."""
    rows = {"top": None, "left": E_ROWS, "right": S_ROWS}[face]
    for row in range(5):
        for col in range(5):
            if rows is None or rows[row][col] == "1":
                yield FIELD_POSITIONS[col], FIELD_POSITIONS[row]


def _face_point(face, fx, fy):
    a, b, c, d, e, f = CUBE_FACES[face]
    return a * fx + c * fy + e, b * fx + d * fy + f


def _cube_bbox():
    """The cube's silhouette in the 100-unit box: (x0, y0, x1, y1)."""
    xs, ys = [], []
    for face, _, _ in CUBE_LAYERS:
        a, b, c, d, _, _ = CUBE_FACES[face]
        hx = FIELD_RADIUS * math.hypot(a, c)
        hy = FIELD_RADIUS * math.hypot(b, d)
        for fx, fy in cube_cells(face):
            cx, cy = _face_point(face, fx, fy)
            xs += [cx - hx, cx + hx]
            ys += [cy - hy, cy + hy]
    return min(xs), min(ys), max(xs), max(ys)


CUBE_BBOX = _cube_bbox()
CUBE_WIDTH = CUBE_BBOX[2] - CUBE_BBOX[0]
CUBE_HEIGHT = CUBE_BBOX[3] - CUBE_BBOX[1]


def _cube_fill(colours, kind):
    if kind == "s":
        return colours["accent"]
    if kind == "field":
        return FIELD_COLOUR
    return colours["ink"]


def _cube_placement(span, cx, cy):
    """(scale, tx, ty) putting the silhouette `span` tall, centred on
    (cx, cy), as a transform on the 100-unit box."""
    scale = span / CUBE_HEIGHT
    tx = cx - scale * (CUBE_BBOX[0] + CUBE_BBOX[2]) / 2
    ty = cy - scale * (CUBE_BBOX[1] + CUBE_BBOX[3]) / 2
    return scale, tx, ty


# ------------------------------------------------------------------- vector


def _svg_open(width, height, viewbox):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="{viewbox}" role="img" '
        f'aria-label="Eclipsa Studio">'
    )


def _matrix(face):
    return "matrix(" + " ".join(f"{v:.4f}" for v in CUBE_FACES[face]) + ")"


def cube_svg_lines(colours, transform=None, layers=CUBE_LAYERS, fill=None):
    """The cube's cells, one group per face, in the 100-unit box.

    `transform` wraps the whole cube; `fill` overrides every colour
    (the Icon Composer layers are drawn in black and coloured by the
    document).
    """
    pad = "  " if transform else ""
    lines = []
    if transform:
        lines.append(f'  <g transform="{transform}">')
    for face, kind, label in layers:
        lines.append(f"{pad}  <!-- {label} -->")
        lines.append(
            f'{pad}  <g fill="{fill or _cube_fill(colours, kind)}" '
            f'transform="{_matrix(face)}">'
        )
        for fx, fy in cube_cells(face):
            lines.append(
                f'{pad}    <circle cx="{fx:.3f}" cy="{fy:.3f}" '
                f'r="{FIELD_RADIUS:.3f}"/>'
            )
        lines.append(f"{pad}  </g>")
    if transform:
        lines.append("  </g>")
    return lines


def mark_svg(colours):
    """The mark alone, on a transparent ground, in its 58-unit box."""
    parts = [
        _svg_open(LIVE_SPAN, LIVE_SPAN, f"{LIVE_START} {LIVE_START} {LIVE_SPAN} {LIVE_SPAN}"),
        "  <title>Eclipsa Studio</title>",
        f"  <desc>Cube mark for a {colours['name']} ground: the E on the "
        "left wall in the ink, the S on the right wall in the accent, "
        f"a 5x5 field of unlit cells in {FIELD_COLOUR} on the top "
        "face.</desc>",
        *cube_svg_lines(colours),
        "</svg>",
    ]
    return "\n".join(parts) + "\n"


def icon_svg(colours):
    """The app icon board: the plate, and the cube centred on it."""
    off = (BOARD - PLATE_SIZE) / 2
    radius = PLATE_SIZE * PLATE_CORNER
    scale, tx, ty = _cube_placement(PLATE_SIZE * MARK_SPAN, BOARD / 2, BOARD / 2)
    parts = [
        _svg_open(BOARD, BOARD, f"0 0 {BOARD} {BOARD}"),
        "  <title>Eclipsa Studio</title>",
        f"  <desc>App icon, {colours['name']} plate: the cube mark on a "
        "rounded plate.</desc>",
        f'  <rect x="{off:g}" y="{off:g}" width="{PLATE_SIZE}" '
        f'height="{PLATE_SIZE}" rx="{radius:g}" fill="{colours["plate"]}"/>',
        *cube_svg_lines(
            colours, transform=f"translate({tx:.2f} {ty:.2f}) scale({scale:.4f})"
        ),
        "</svg>",
    ]
    return "\n".join(parts) + "\n"


def lockup_svg(colours):
    """The cube beside the wordmark, on the plate."""
    scale, tx, ty = _cube_placement(
        CUBE_HEIGHT, LOCKUP_PAD + CUBE_WIDTH / 2, LOCKUP_HEIGHT / 2
    )
    font_size = round(LIVE_SPAN * LOCKUP_TYPE_RATIO)
    text_x = LOCKUP_PAD + CUBE_WIDTH + LOCKUP_GAP
    baseline = LOCKUP_HEIGHT / 2 + font_size * INTER_CAP_HEIGHT / 2
    width = round(text_x + font_size * LOCKUP_TEXT_EM + LOCKUP_PAD)
    parts = [
        _svg_open(width, LOCKUP_HEIGHT, f"0 0 {width} {LOCKUP_HEIGHT}"),
        "  <title>Eclipsa Studio</title>",
        f"  <desc>Lockup, {colours['name']} plate: the cube mark beside "
        "the wordmark.</desc>",
        f'  <rect width="{width}" height="{LOCKUP_HEIGHT}" '
        f'fill="{colours["plate"]}"/>',
        *cube_svg_lines(
            colours, transform=f"translate({tx:.2f} {ty:.2f}) scale({scale:.4f})"
        ),
        f'  <text x="{text_x:.2f}" y="{baseline:.1f}" font-family="{LOCKUP_FONT}" '
        f'font-size="{font_size}" font-weight="{LOCKUP_WEIGHT}" '
        f'letter-spacing="{-font_size * 0.02:.2f}" xml:space="preserve">'
        f'<tspan fill="{colours["ink"]}">Eclipsa</tspan>'
        f'<tspan fill="{colours["accent"]}"> Studio</tspan></text>',
        "</svg>",
    ]
    return "\n".join(parts) + "\n"


# ----------------------------------------------------------- icon package


def _icon_colour(hex_colour):
    """A colour in icon.json's `extended-srgb:r,g,b,a` form."""
    r, g, b = _rgb(hex_colour)
    return f"extended-srgb:{r / 255:.5f},{g / 255:.5f},{b / 255:.5f},1.00000"


def _solid(hex_colour):
    """A solid fill, the same in every appearance."""
    return {"solid": _icon_colour(hex_colour)}



def icon_layer_svg(kind):
    """One layer's cells on the 1024 icon canvas, in black.

    The colour is the layer's fill in icon.json, per appearance; the
    SVG only gives the shape. The cube spans MARK_SPAN of the canvas,
    as it spans MARK_SPAN of the plate in the PNG icon, because the
    package's fill is the whole icon shape and the system draws the
    corner.
    """
    scale, tx, ty = _cube_placement(BOARD * MARK_SPAN, BOARD / 2, BOARD / 2)
    layers = [layer for layer in CUBE_LAYERS if layer[1] == kind]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{BOARD}" '
        f'height="{BOARD}" viewBox="0 0 {BOARD} {BOARD}">',
        *cube_svg_lines(
            None,
            transform=f"translate({tx:.2f} {ty:.2f}) scale({scale:.4f})",
            layers=layers,
            fill="#000000",
        ),
        "</svg>",
    ]
    return "\n".join(parts) + "\n"


def icon_package_json():
    """icon.json: the plate and the three layers, in the dark set.

    The fills are plain `fill` values, so the document has one
    appearance and the system draws it unchanged in Light mode and in
    Dark mode. The layers are glass with the group's neutral shadow
    and half translucency, Icon Composer's defaults for an imported
    layer, so the icon takes the same treatment as the system's own.
    The field layer's fill is FIELD_COLOUR, the same fixed grey the
    app's painter draws.
    """
    doc = {
        "fill": _solid(DARK["plate"]),
        "groups": [
            {
                "layers": [
                    {
                        "name": "S",
                        "image-name": "s.svg",
                        "glass": True,
                        "fill": _solid(DARK["accent"]),
                    },
                    {
                        "name": "E",
                        "image-name": "e.svg",
                        "glass": True,
                        "fill": _solid(DARK["ink"]),
                    },
                    {
                        "name": "Field",
                        "image-name": "field.svg",
                        "glass": True,
                        "fill": _solid(FIELD_COLOUR),
                    },
                ],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.5},
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    return json.dumps(doc, indent=2) + "\n"


# ---------------------------------------------------------------- raster


def _rgb(value):
    v = value.lstrip("#")
    return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16))


def _coverage(distance):
    """Coverage of a pixel whose centre is `distance` outside an edge.

    A linear ramp across one pixel. For flat shapes this is within a
    level or two of a supersampled render and costs one expression
    per pixel.
    """
    return min(1.0, max(0.0, 0.5 - distance))


def _blend(dst, offset, rgb, alpha):
    """Source-over one colour into a PREMULTIPLIED RGBA bytearray.

    Compositing is done premultiplied because that is what makes
    source-over a plain lerp. The buffer is converted back to straight
    alpha by [_unpremultiply] before it is encoded -- PNG colour type 6
    is defined as non-premultiplied, so storing it premultiplied
    darkens every partially covered pixel by its own coverage.
    """
    if alpha <= 0:
        return
    inv = 1.0 - alpha
    for channel in range(3):
        dst[offset + channel] = round(
            rgb[channel] * alpha + dst[offset + channel] * inv
        )
    dst[offset + 3] = round(255 * alpha + dst[offset + 3] * inv)


def _unpremultiply(buf):
    """Convert a premultiplied RGBA buffer to straight alpha, in place.

    Only the antialiased edge is affected: where alpha is 0 there is no
    colour to recover, and where it is 255 the two representations are
    identical. That edge is the plate's rounded corners, which is the
    whole of what the icon's outline is made of.
    """
    for i in range(0, len(buf), 4):
        a = buf[i + 3]
        if 0 < a < 255:
            for channel in range(3):
                buf[i + channel] = min(255, round(buf[i + channel] * 255 / a))


def _draw_ellipse(buf, size, matrix, centre, radius, rgb, opacity):
    """Draw the affine image of a circle: `radius` in face space, the
    face-to-pixel matrix (a, b, c, d) and the circle's pixel centre.

    Coverage comes from a first-order signed distance: f(p) is the
    face-space distance of the pixel from the circle, divided by the
    gradient's magnitude to bring it back to pixels. Exact on the
    ellipse's axes and within a small fraction of a pixel elsewhere.
    """
    a, b, c, d = matrix
    det = a * d - b * c
    px, py = centre
    hx, hy = radius * math.hypot(a, c), radius * math.hypot(b, d)
    x0, x1 = int(px - hx - 1), int(math.ceil(px + hx + 1))
    y0, y1 = int(py - hy - 1), int(math.ceil(py + hy + 1))
    for y in range(max(0, y0), min(size, y1)):
        dy = y + 0.5 - py
        for x in range(max(0, x0), min(size, x1)):
            dx = x + 0.5 - px
            # The pixel in face space, relative to the circle's centre.
            qx = (d * dx - c * dy) / det
            qy = (a * dy - b * dx) / det
            q = math.hypot(qx, qy)
            if q == 0:
                alpha = 1.0
            else:
                ux, uy = qx / q, qy / q
                gx = (d * ux - b * uy) / det
                gy = (a * uy - c * ux) / det
                alpha = _coverage((q - radius) / math.hypot(gx, gy))
            if alpha:
                _blend(buf, (y * size + x) * 4, rgb, alpha * opacity)


def render_icon(
    size,
    colours,
    plate_size=PLATE_SIZE,
    plate_corner=PLATE_CORNER,
    mark_span=MARK_SPAN,
):
    """Rasterise the icon board at `size` in `colours`, as RGBA bytes.

    The plate is `plate_size` of the 1024 board with corners
    `plate_corner` of it, and the cube spans `mark_span` of the plate;
    the defaults are the macOS grid."""
    buf = bytearray(size * size * 4)
    k = size / BOARD

    # Plate: a rounded rectangle, drawn through its signed distance.
    half = plate_size * k / 2
    cx = cy = size / 2
    corner = plate_size * plate_corner * k
    inner = half - corner
    plate_rgb = _rgb(colours["plate"])
    lo = max(0, int((size - plate_size * k) / 2) - 1)
    hi = min(size, size - lo + 1)
    for y in range(lo, hi):
        dy = abs(y + 0.5 - cy) - inner
        for x in range(lo, hi):
            dx = abs(x + 0.5 - cx) - inner
            if dx <= 0 and dy <= 0:
                distance = -corner
            else:
                ex, ey = max(dx, 0.0), max(dy, 0.0)
                distance = math.hypot(ex, ey) - corner
            alpha = _coverage(distance)
            if alpha:
                _blend(buf, (y * size + x) * 4, plate_rgb, alpha)

    # The cube: the field first, then the letters.
    scale, tx, ty = _cube_placement(plate_size * mark_span * k, cx, cy)
    for face, kind, _ in CUBE_LAYERS:
        a, b, c, d, e, f = CUBE_FACES[face]
        matrix = (a * scale, b * scale, c * scale, d * scale)
        rgb = _rgb(_cube_fill(colours, kind))
        for fx, fy in cube_cells(face):
            bx, by = _face_point(face, fx, fy)
            centre = (bx * scale + tx, by * scale + ty)
            _draw_ellipse(buf, size, matrix, centre, FIELD_RADIUS, rgb, 1.0)

    _unpremultiply(buf)
    return bytes(buf)


def png_bytes(size, rgba):
    """Encode RGBA bytes as a PNG."""

    def chunk(tag, payload):
        body = tag + payload
        return (
            struct.pack(">I", len(payload))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    raw = b"".join(
        b"\x00" + rgba[y * size * 4 : (y + 1) * size * 4] for y in range(size)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def ico_bytes(images):
    """Pack {size: png} into an .ico. Entries carry PNG payloads."""
    entries, blobs = [], []
    offset = 6 + 16 * len(images)
    for size, png in sorted(images.items()):
        entries.append(
            struct.pack(
                "<BBBBHHII",
                size if size < 256 else 0,
                size if size < 256 else 0,
                0,
                0,
                1,
                32,
                len(png),
                offset,
            )
        )
        blobs.append(png)
        offset += len(png)
    return (
        struct.pack("<HHH", 0, 1, len(images))
        + b"".join(entries)
        + b"".join(blobs)
    )


# ------------------------------------------------------------------ driver

SVG_MASTERS = 3  # per colour set: mark, app icon, lockup


def artifacts():
    """Every generated file, as {path: bytes}."""
    out = {}
    rendered = {}
    for colours in COLOUR_SETS:
        suffix = "" if colours is DARK else f"-{colours['name']}"
        out[BRAND / f"eclipsa-studio-mark{suffix}.svg"] = mark_svg(colours).encode()
        out[BRAND / f"eclipsa-studio-app-icon{suffix}.svg"] = icon_svg(colours).encode()
        out[BRAND / f"eclipsa-studio-lockup{suffix}.svg"] = lockup_svg(colours).encode()
        sizes = set(BRAND_PNG_SIZES)
        if colours is DARK:
            sizes |= set(MACOS_SIZES)
        rendered[colours["name"]] = {
            size: png_bytes(size, render_icon(size, colours))
            for size in sorted(sizes)
        }
        for size in BRAND_PNG_SIZES:
            out[BRAND / "png" / f"eclipsa-studio-app-icon{suffix}-{size}.png"] = (
                rendered[colours["name"]][size]
            )
    dark = rendered["dark"]
    for size in MACOS_SIZES:
        out[MACOS_ICONSET / f"app_icon_{size}.png"] = dark[size]
    out[WINDOWS_ICO] = ico_bytes(
        {
            s: png_bytes(
                s,
                render_icon(
                    s,
                    DARK,
                    WINDOWS_PLATE_SIZE,
                    WINDOWS_PLATE_CORNER,
                    WINDOWS_MARK_SPAN,
                ),
            )
            for s in ICO_SIZES
        }
    )
    out[MACOS_ICON_PACKAGE / "icon.json"] = icon_package_json().encode()
    for kind in ("e", "s", "field"):
        out[MACOS_ICON_PACKAGE / "Assets" / f"{kind}.svg"] = (
            icon_layer_svg(kind).encode()
        )
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check",
        action="store_true",
        help="verify the committed files match, and write nothing",
    )
    args = ap.parse_args()

    out = artifacts()
    if args.check:
        stale = [
            path
            for path, data in out.items()
            if not path.exists() or path.read_bytes() != data
        ]
        if stale:
            print(
                "gen_app_icon: out of date:\n  "
                + "\n  ".join(str(p.relative_to(REPO)) for p in stale),
                file=sys.stderr,
            )
            print("Run ./build.sh gen-icon", file=sys.stderr)
            return 1
        print(f"gen_app_icon: {len(out)} files are up to date")
        return 0

    for path, data in out.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print(
        f"gen_app_icon: wrote {len(out)} files "
        f"({len(MACOS_SIZES)} macOS PNGs, 1 .ico, "
        f"{SVG_MASTERS * len(COLOUR_SETS)} SVG masters, "
        f"{len(BRAND_PNG_SIZES) * len(COLOUR_SETS)} brand PNGs, "
        "1 Icon Composer package)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
