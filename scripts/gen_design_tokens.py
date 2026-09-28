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

"""Generate app/lib/theme_tokens.dart from app/design/tokens/.

Source of truth is app/design/tokens/themes.json plus one DTCG token file
per theme. This emits the AppThemeMode enum, per-theme metadata and one
const AppThemeData per theme. class T and the AppThemeData schema stay
hand-written -- the generator only ever emits data, so the 1,700-odd
T.* call sites never move.

Usage:
    gen_design_tokens.py              write app/lib/theme_tokens.dart
    gen_design_tokens.py --check      verify the committed file is current
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from _gen_common import REPO, GenError, app_language_version

TOKENS = REPO / "app/design/tokens"
SCHEMA = REPO / "app/lib/theme_data.dart"
PUBSPEC = REPO / "app/pubspec.yaml"
TARGET = REPO / "app/lib/theme_tokens.dart"

HEADER = """// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
"""

HEX = re.compile(r"^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")


# ---------------------------------------------------------------- loading

def schema_fields():
    """Field names, in order, from AppThemeData's constructor."""
    src = SCHEMA.read_text(encoding="utf-8")
    m = re.search(r"const AppThemeData\(\{(.*?)\}\);", src, re.S)
    if not m:
        raise GenError(f"no AppThemeData constructor in {SCHEMA}")
    return re.findall(r"required this\.(\w+),", m.group(1))


# Token $types that name a member of a Dart enum in theme_data.dart,
# keyed by $type with the enum's name as the value.
ENUM_TYPES = {
    "knobStyle": "KnobStyle",
    "chromeStyle": "ChromeStyle",
    "controlStyle": "ControlStyle",
    "cardStyle": "CardStyle",
}

SUPPORTED_TYPES = ("color", "fontFamily", "dimension", *ENUM_TYPES)


def enum_members(name):
    """Member names of a Dart enum declared in AppThemeData's file.

    An ENUM_TYPES token names one of these. Validated the same way font
    families are validated against pubspec: an unknown value would
    otherwise compile to a dangling identifier and only fail at build
    time, far from the token file that caused it.
    """
    src = SCHEMA.read_text(encoding="utf-8")
    m = re.search(r"enum\s+" + name + r"\s*\{(.*?)\}", src, re.S)
    if not m:
        raise GenError(f"no `enum {name}` in {SCHEMA}")
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return [w for w in re.findall(r"\b([a-z][A-Za-z0-9_]*)\b\s*(?:,|$)",
                                  body, re.M)]


def pubspec_families():
    """Font families declared in app/pubspec.yaml.

    Flutter does not report a fontFamily token naming something not
    declared here: it substitutes the system face and nothing errors.
    Parsed with a regex rather than a YAML library to keep this script
    dependency-free, matching the other scripts in this directory.
    """
    src = PUBSPEC.read_text(encoding="utf-8")
    body = re.search(r"^  fonts:\n(.*?)(?=^\S|^  \w+:|\Z)", src,
                     re.S | re.M)
    if not body:
        return set()
    return set(re.findall(r"^\s*-\s*family:\s*(.+?)\s*$",
                          body.group(1), re.M))


def flatten(doc, path=()):
    """DTCG tree -> {leafName: (value, description, dotted.path, type)}."""
    out = {}
    for key, node in doc.items():
        if key.startswith("$"):
            continue
        if isinstance(node, dict) and "$value" in node:
            kind = node.get("$type")
            if kind not in SUPPORTED_TYPES:
                raise GenError(
                    f"{'.'.join(path + (key,))}: unsupported $type "
                    f"{kind!r} (supported: {', '.join(SUPPORTED_TYPES)})")
            out[key] = (node["$value"], node.get("$description", ""),
                        ".".join(path + (key,)), kind)
        elif isinstance(node, dict):
            for k, v in flatten(node, path + (key,)).items():
                if k in out:
                    raise GenError(f"duplicate token name {k!r}")
                out[k] = v
    return out


def _no_duplicate_keys(pairs):
    """json object_pairs_hook: reject a key defined twice in one object.

    json.loads keeps the last value by default, so a token pasted twice
    would pass every other check with whichever value came last.
    """
    out = {}
    for k, v in pairs:
        if k in out:
            raise GenError(f"duplicate key {k!r} in one JSON object")
        out[k] = v
    return out


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"),
                      object_pairs_hook=_no_duplicate_keys)


ROLES = ("dark", "light", "highContrast")
REGISTRY_KEYS = ("id", "label", "role", "enumName", "tokens")


def check_registry(reg):
    """Validate themes.json before anything is emitted from it.

    A bad entry would otherwise reach the Dart as a duplicate enum
    member or a dangling AppThemeRole and surface as an analyzer error
    far from the file that caused it.
    """
    entries = reg.get("themes") or []
    if not entries:
        raise GenError("themes.json lists no themes")
    seen_ids, seen_enum, seen_const, owner_of = set(), set(), set(), {}
    for entry in entries:
        missing = [k for k in REGISTRY_KEYS if k not in entry]
        if missing:
            raise GenError(f"themes.json entry {entry.get('id')!r} is "
                           f"missing {', '.join(missing)}")
        if entry["role"] not in ROLES:
            raise GenError(f"{entry['id']}: role {entry['role']!r} is not "
                           f"one of {', '.join(ROLES)}")
        for key, seen in (("id", seen_ids), ("enumName", seen_enum)):
            if entry[key] in seen:
                raise GenError(f"themes.json: duplicate {key} "
                               f"{entry[key]!r}")
            seen.add(entry[key])
        cname = const_name(entry)
        if cname in seen_const:
            raise GenError(f"themes.json: two ids generate the constant "
                           f"{cname}")
        seen_const.add(cname)
        # themeModeFromId accepts the id and the enum name, so each
        # must resolve to exactly one theme.
        for name in {entry["id"], entry["enumName"]}:
            owner = owner_of.setdefault(name, entry["id"])
            if owner != entry["id"]:
                raise GenError(f"themes.json: {name!r} resolves to both "
                               f"{owner!r} and {entry['id']!r}")


def load():
    reg = load_json(TOKENS / "themes.json")
    check_registry(reg)
    fields = schema_fields()
    themes = []
    for entry in reg["themes"]:
        doc = load_json(TOKENS / entry["tokens"])
        # Every top-level group, not just `color` — the schema
        # spans colours and typography, and leaf names are
        # unique across all of AppThemeData.
        toks = flatten(doc)

        missing = [f for f in fields if f not in toks]
        unknown = [t for t in toks if t not in fields]
        if missing:
            raise GenError(f"{entry['id']}: missing token(s) "
                           f"{', '.join(sorted(missing))}")
        if unknown:
            raise GenError(f"{entry['id']}: token(s) with no AppThemeData "
                           f"field: {', '.join(sorted(unknown))}")
        for name, (value, _, dotted, kind) in toks.items():
            if kind == "color" and not HEX.match(value):
                raise GenError(f"{entry['id']}.{dotted}: malformed hex "
                               f"{value!r} (want #RRGGBB or #RRGGBBAA)")
            if kind in ENUM_TYPES:
                enum = ENUM_TYPES[kind]
                members = enum_members(enum)
                if value not in members:
                    raise GenError(
                        f"{entry['id']}.{dotted}: {kind} {value!r} is not "
                        f"a {enum} member ({', '.join(members)})")
            if kind == "fontFamily":
                if not isinstance(value, str) or not value.strip():
                    raise GenError(f"{entry['id']}.{dotted}: fontFamily "
                                   f"must be a non-empty string")
                if value not in pubspec_families():
                    raise GenError(
                        f"{entry['id']}.{dotted}: font family {value!r} "
                        f"is not declared in app/pubspec.yaml — Flutter "
                        f"would silently fall back to the system face")
        themes.append({**entry, "tokens": toks, "desc":
                       doc.get("$description", "")})
    if not themes:
        raise GenError("themes.json lists no themes")
    return reg, themes, fields


# --------------------------------------------------------------- contrast

def _rel_luminance(hex6):
    def chan(v):
        v = int(v, 16) / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = chan(hex6[0:2]), chan(hex6[2:4]), chan(hex6[4:6])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    """WCAG 2.x contrast ratio. Alpha is ignored -- these tokens are
    composited over unknown ground at paint time, so the opaque value
    is the only thing we can check."""
    la, lb = _rel_luminance(a.lstrip("#")[:6]), _rel_luminance(
        b.lstrip("#")[:6])
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def check_contrast(themes):
    """Ratchet gate: every pair must meet its floor, or -- where a
    known-failing pair is baselined -- must not regress below the
    value recorded when the gate was introduced.

    Each baseline is a WCAG failure that has not been fixed. They exist
    so the gate could be turned on without a palette change, and the
    list must only shrink.
    """
    cfg = load_json(TOKENS / "contrast.json")
    problems, notes = [], []
    for theme in themes:
        toks = theme["tokens"]
        base = cfg.get("baseline", {}).get(theme["id"], {})
        for rule in cfg["rules"]:
            fg, bg = rule["fg"], rule["bg"]
            if fg not in toks or bg not in toks:
                raise GenError(f"contrast rule names unknown token: "
                               f"{fg} on {bg}")
            if toks[fg][3] != "color" or toks[bg][3] != "color":
                raise GenError(f"contrast rule needs two colours: "
                               f"{fg} on {bg}")
            floor = rule.get("min", 4.5)
            if theme.get("role") == "highContrast":
                floor = max(floor, cfg.get("highContrastMin", floor))
            got = contrast(toks[fg][0], toks[bg][0])
            key = f"{fg} on {bg}"
            if got + 1e-9 >= floor:
                continue
            if key in base:
                if got + 0.005 < base[key]:
                    problems.append(
                        f"{theme['id']}: {key} regressed to {got:.2f} "
                        f"(baseline {base[key]:.2f}, target {floor})")
                else:
                    notes.append(f"{theme['id']}: {key} = {got:.2f} "
                                 f"(below {floor}, baselined)")
            else:
                problems.append(
                    f"{theme['id']}: {key} = {got:.2f}, below the "
                    f"required {floor} and not baselined")
    return problems, notes


# ----------------------------------------------------------------- emit

def dart_literal(value, kind):
    """One token's DTCG value as a Dart expression."""
    if kind == "color":
        v = value.lstrip("#").upper()
        rgb, alpha = (v, "FF") if len(v) == 6 else (v[:6], v[6:])
        return f"Color(0x{alpha}{rgb})"
    if kind in ENUM_TYPES:
        # Emitted as the enum reference, not a string: the Dart field is
        # typed with the enum, so a typo fails the analyzer at the
        # generated line rather than surviving as a valid string.
        return f"{ENUM_TYPES[kind]}.{value}"
    if kind == "fontFamily":
        return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
    if kind == "dimension":
        # Written unitless in the token files: these are logical pixels,
        # the only unit Flutter has, so a "4px" string would be a unit
        # we then have to strip and could get wrong.
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise GenError(f"dimension token must be a number, got {value!r}")
        if value < 0:
            raise GenError(f"dimension token must not be negative: {value}")
        return repr(float(value))
    raise GenError(f"no Dart mapping for $type {kind!r}")


def emit(reg, themes, fields):
    L = [HEADER, "",
         "// GENERATED FILE — DO NOT EDIT BY HAND.",
         "//",
         "// Regenerate with `./build.sh gen-tokens` (macOS) or",
         "// `.\\build.ps1 gen-tokens` (Windows). The source of truth is",
         "// app/design/tokens/themes.json and the DTCG token files beside it.",
         "// Editing this file directly will be overwritten, and CI fails",
         "// the build if it drifts from the tokens.",
         "",
         "import 'package:flutter/material.dart';", "",
         "import 'theme_data.dart';", "",
         "/// Visual role of a theme. Drives Material [Brightness].",
         "/// Decoupled from [AppThemeMode] so several themes can share",
         "/// one role.",
         "enum AppThemeRole { dark, light, highContrast }", "",
         "/// The themes the app ships. Persisted by `.name`, so these",
         "/// names are a storage format and must not change once",
         "/// shipped. Reordering is safe.",
         "enum AppThemeMode {"]
    L += [f"  {t['enumName']}," for t in themes]
    L += ["}", "",
          "/// Descriptive metadata for one theme.",
          "class AppThemeMeta {",
          "  const AppThemeMeta({",
          "    required this.id,",
          "    required this.label,",
          "    required this.role,",
          "  });", "",
          "  /// Stable identifier. Never changes once shipped.",
          "  final String id;", "",
          "  /// Human-readable name shown in Settings. Safe to rename.",
          "  final String label;", "",
          "  /// Drives Brightness.",
          "  final AppThemeRole role;",
          "}", ""]

    L.append("const Map<AppThemeMode, AppThemeMeta> kThemeMeta = {")
    for t in themes:
        L += [f"  AppThemeMode.{t['enumName']}: AppThemeMeta(",
              f"    id: '{t['id']}',",
              f"    label: '{t['label']}',",
              f"    role: AppThemeRole.{t['role']},",
              "  ),"]
    L += ["};", ""]

    for t in themes:
        if t["desc"]:
            L.append(f"/// {t['desc']}")
        L.append(f"const AppThemeData {t['constName']} = AppThemeData(")
        for f in fields:
            value, desc, _, kind = t["tokens"][f]
            line = f"  {f}: {dart_literal(value, kind)},"
            if desc and len(line) + len(desc) + 4 <= 80:
                line += f" // {desc}"
            L.append(line)
        L += [");", ""]

    L += ["/// The [AppThemeData] for [mode].",
          "AppThemeData themeDataFor(AppThemeMode mode) => switch (mode) {"]
    L += [f"  AppThemeMode.{t['enumName']} => {t['constName']},"
          for t in themes]
    L += ["};", "",
          "/// Resolve a persisted theme name (the token id or the enum",
          "/// name) to a mode. Returns null if unrecognised, so callers",
          "/// choose their own fallback.",
          "AppThemeMode? themeModeFromId(String id) {",
          "  for (final entry in kThemeMeta.entries) {",
          "    if (entry.value.id == id || entry.key.name == id) {",
          "      return entry.key;",
          "    }",
          "  }",
          "  return null;",
          "}", ""]
    return "\n".join(L)


def dart_format(text):
    """Run the emitted source through `dart format`.

    Without this the drift gate and the formatting gate fight each
    other: the generator would keep writing a file that `build.sh lint
    --check` then reformats, so one of the two always fails. Formatting
    here makes the committed file a fixed point of both.

    A missing `dart` is an error rather than a warning: unformatted
    output can never match the committed file, so `--check` would
    report drift that regenerating does not fix.
    """
    dart = shutil.which("dart")
    if not dart:
        raise GenError("`dart` is not on PATH; this script needs `dart "
                       "format` from the Flutter SDK")
    argv = [dart, "format", "--output=show", "--summary=none",
            f"--language-version={app_language_version()}"]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "theme_tokens.dart"
        tmp.write_text(text, encoding="utf-8")
        r = subprocess.run(argv + [str(tmp)], capture_output=True,
                           text=True, encoding="utf-8")
        if r.returncode != 0:
            raise GenError(f"`dart format` rejected the generated "
                           f"source:\n{r.stderr.strip()}")
        return r.stdout


def const_name(entry):
    parts = re.split(r"[-_]", entry["id"])
    return "kTheme" + "".join(p[:1].upper() + p[1:] for p in parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed file matches the tokens")
    args = ap.parse_args()

    try:
        reg, themes, fields = load()
        for t in themes:
            t["constName"] = const_name(t)
        problems, notes = check_contrast(themes)
        for n in notes:
            print(f"  note: contrast {n}", file=sys.stderr)
        if problems:
            raise GenError("contrast gate:\n  " + "\n  ".join(problems))
        out = dart_format(emit(reg, themes, fields))
    except GenError as e:
        print(f"gen_design_tokens: {e}", file=sys.stderr)
        return 1

    rel = TARGET.relative_to(REPO)
    if args.check:
        current = (TARGET.read_text(encoding="utf-8") if TARGET.exists()
                   else "")
        if current != out:
            print(f"gen_design_tokens: {rel} is out of date.\n"
                  f"  Run `./build.sh gen-tokens` and commit the result.",
                  file=sys.stderr)
            return 1
        print(f"gen_design_tokens: {rel} is up to date "
              f"({len(themes)} themes x {len(fields)} tokens)")
        return 0

    # Explicit UTF-8 and LF so the committed file is byte-identical
    # whichever platform regenerated it.
    with TARGET.open("w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print(f"gen_design_tokens: wrote {rel} "
          f"({len(themes)} themes x {len(fields)} tokens)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
