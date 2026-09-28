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

"""Generate app/lib/widgets/component_index.dart.

Metadata comes from app/design/components.json; the "used in" list is read
out of app/lib/ so it cannot drift from the code. The schema is
ComponentInfo in app/lib/widgets/component_info.dart, hand-written --
this script parses its constructor and requires an exact field match,
so neither side can change without the other.

Usage:
    gen_component_index.py              write the Dart file
    gen_component_index.py --check      verify the committed file is current
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

from _gen_common import REPO, GenError, app_language_version

REGISTRY = REPO / "app/design/components.json"
APP = REPO / "app"
LIB = APP / "lib"
SCHEMA = LIB / "widgets/component_info.dart"
TARGET = LIB / "widgets/component_index.dart"

# The gallery renders every component in the registry, so counting it as
# a usage would say "used in 1 file" for everything and mean nothing. A
# component whose only caller is the gallery therefore reports zero, and
# the gallery renders that as its own state rather than as a count --
# GainSlider currently has no caller at all, which is worth seeing.
#
# This script's own output is excluded too: it names every component in
# string literals, and while strip_dart() removes those, a generated
# file is not evidence of use in any case.
EXCLUDED = {
    "lib/widgets/theme_gallery.dart",
    "lib/widgets/component_index.dart",
}

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


# --------------------------------------------------------------- source

def strip_dart(src):
    """Blank out comments and string literals, preserving offsets.

    Without this, a doc comment like `/// See [AppButton].` or a
    string `'AppButton'` counts as a call site. Offsets are
    preserved by replacing each removed character with a space, so line
    numbers stay usable for error messages.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # Line comment.
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        # Block comment (Dart nests them).
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 0
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if src.startswith("*/", i):
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    if depth == 0:
                        break
                    continue
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        # String literal, single or triple quoted, optionally raw.
        if c in "'\"":
            quote = src[i : i + 3] if src[i : i + 3] in ("'''", '"""') else c
            j = i + len(quote)
            out[i : i + len(quote)] = " " * len(quote)
            while j < n:
                if src[j] == "\\":
                    if src[j] != "\n":
                        out[j] = " "
                    if j + 1 < n and src[j + 1] != "\n":
                        out[j + 1] = " "
                    j += 2
                    continue
                if src.startswith(quote, j):
                    out[j : j + len(quote)] = " " * len(quote)
                    j += len(quote)
                    break
                if src[j] != "\n":
                    out[j] = " "
                j += 1
            i = j
            continue
        i += 1
    return "".join(out)


def call_sites(name, text):
    """Count `Name(` and `Name<...>(` occurrences in stripped source.

    The lookbehind rejects `FooAppButton(` and `self.Name(`, so a
    longer identifier ending in the component's name is not a hit.
    """
    pat = re.compile(
        r"(?<![A-Za-z0-9_$.])" + re.escape(name) + r"\s*(?:<[^<>()]*>)?\s*\("
    )
    return len(pat.findall(text))


def schema_fields():
    """Field names, in order, from ComponentInfo's constructor."""
    src = SCHEMA.read_text(encoding="utf-8")
    m = re.search(r"const ComponentInfo\(\{(.*?)\}\);", src, re.S)
    if not m:
        raise GenError(f"no ComponentInfo constructor in {SCHEMA}")
    return re.findall(r"required this\.(\w+),", m.group(1))


# --------------------------------------------------------------- loading

def _no_duplicate_keys(pairs):
    """json object_pairs_hook: reject a key defined twice in one object.

    json.loads keeps the last value by default, so a field pasted twice
    would pass every other check with whichever value came last.
    """
    out = {}
    for k, v in pairs:
        if k in out:
            raise GenError(f"duplicate key {k!r} in one JSON object")
        out[k] = v
    return out


def load():
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"),
                     object_pairs_hook=_no_duplicate_keys)
    entries = reg.get("components")
    if not entries:
        raise GenError("components.json lists no components")

    fields = set(schema_fields())
    expected = {"name", "declaredIn", "summary", "usedIn", "useCount"}
    if fields != expected:
        raise GenError(
            f"ComponentInfo fields {sorted(fields)} do not match what this "
            f"generator emits {sorted(expected)} -- update both together")

    # as_posix(): the registry and EXCLUDED use forward slashes, and
    # relative_to() alone would yield backslashes on Windows.
    sources = {
        p.relative_to(APP).as_posix(): strip_dart(
            p.read_text(encoding="utf-8", errors="replace"))
        for p in sorted(LIB.rglob("*.dart"))
    }

    seen = set()
    out = []
    for e in entries:
        name = e.get("name")
        if not name:
            raise GenError("a component entry has no name")
        if name in seen:
            raise GenError(f"duplicate component {name!r}")
        seen.add(name)

        declared = e.get("declaredIn")
        if declared not in sources:
            raise GenError(f"{name}: declaredIn {declared!r} is not a file "
                           f"under app/lib/")
        # The class must actually be declared where the registry says.
        decl = re.compile(r"\bclass\s+" + re.escape(name) + r"\b")
        if not decl.search(sources[declared]):
            raise GenError(f"{name}: no `class {name}` in {declared} -- the "
                           f"registry is stale or the class was renamed")

        if not e.get("summary"):
            raise GenError(f"{name}: summary is required")

        uses = Counter()
        for path, text in sources.items():
            if path in EXCLUDED or path == declared:
                continue
            n = call_sites(name, text)
            if n:
                uses[path] = n

        out.append({**e, "uses": uses})
    return out


# ---------------------------------------------------------------- emit

def dart_str(s):
    return "'" + s.replace("\\", "\\\\").replace("'", r"\'").replace(
        "$", r"\$").replace("\n", " ") + "'"


def emit(components):
    L = [HEADER, ""]
    L.append("// GENERATED FILE — DO NOT EDIT BY HAND.")
    L.append("//")
    L.append("// Regenerate with `./build.sh gen-components` (macOS) or")
    L.append("// `.\\build.ps1 gen-components` (Windows). Metadata comes from")
    L.append("// app/design/components.json; the usedIn map is read out of")
    L.append("// app/lib/ by scripts/gen_component_index.py. CI fails the")
    L.append("// build if this file drifts from either.")
    L.append("")
    L.append("import 'component_info.dart';")
    L.append("")
    L.append("/// Every component the Theme Gallery documents, by class name.")
    L.append("const Map<String, ComponentInfo> kComponentIndex = {")
    for c in components:
        uses = c["uses"]
        total = sum(uses.values())
        L.append(f"  {dart_str(c['name'])}: ComponentInfo(")
        L.append(f"    name: {dart_str(c['name'])},")
        L.append(f"    declaredIn: {dart_str(c['declaredIn'])},")
        L.append(f"    summary: {dart_str(c['summary'])},")
        if not uses:
            L.append("    usedIn: {},")
        else:
            L.append("    usedIn: {")
            for path, n in sorted(uses.items(), key=lambda kv: (-kv[1], kv[0])):
                L.append(f"      {dart_str(path)}: {n},")
            L.append("    },")
        L.append(f"    useCount: {total},")
        L.append("  ),")
    L.append("};")
    L.append("")
    return "\n".join(L)


def dart_format(text):
    """Run the emitted source through dart format.

    Without this the drift gate and `lint --check` fight forever: the
    generator writes a file the formatter then rewrites, so one always
    fails. Same reason gen_design_tokens.py does it, and a missing
    `dart` is an error for the same reason: unformatted output can never
    match the committed file.
    """
    dart = shutil.which("dart")
    if not dart:
        raise GenError("`dart` is not on PATH; this script needs `dart "
                       "format` from the Flutter SDK")
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "component_index.dart"
        p.write_text(text, encoding="utf-8")
        r = subprocess.run(
            [dart, "format",
             f"--language-version={app_language_version()}", str(p)],
            capture_output=True)
        if r.returncode != 0:
            raise GenError(f"dart format failed: {r.stderr.decode().strip()}")
        return p.read_text(encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed file is current; write nothing")
    args = ap.parse_args()

    try:
        components = load()
        text = dart_format(emit(components))
    except GenError as e:
        print(f"gen_component_index: {e}", file=sys.stderr)
        return 1

    total = sum(sum(c["uses"].values()) for c in components)
    if args.check:
        current = (TARGET.read_text(encoding="utf-8") if TARGET.exists()
                   else "")
        if current != text:
            print("gen_component_index: app/lib/widgets/component_index.dart "
                  "is out of date; run ./build.sh gen-components",
                  file=sys.stderr)
            return 1
        print(f"gen_component_index: {TARGET.relative_to(REPO)} is up to date "
              f"({len(components)} components, {total} call sites)")
        return 0

    # Explicit UTF-8 and LF so the committed file is byte-identical
    # whichever platform regenerated it.
    with TARGET.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"gen_component_index: wrote {TARGET.relative_to(REPO)} "
          f"({len(components)} components, {total} call sites)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
