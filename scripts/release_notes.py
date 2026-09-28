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

"""Parse RELEASES.md into structured release notes.

Subcommands:
  extract VERSION    Print the markdown body for a single version,
                     stripped of the version header and separators.
                     For piping into `gh release create --notes-file -`
                     or pasting into a website CMS.
  json               Print every release as one JSON document on
                     stdout. For consumption by the website (Astro)
                     and the in-app "What's new" dialog.
  text               Render the full release history as wrapped plain
                     text for a shipped RELEASE_NOTES.txt (markdown
                     stripped, newest first).

The single source of truth is RELEASES.md at the repo root. Edit
that file, never the generated outputs.
"""

import argparse
import json
import re
import sys
import textwrap
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RELEASES_MD = REPO_ROOT / "RELEASES.md"

# Width for the plain-text RELEASE_NOTES.txt renderer. 78 leaves a small
# margin in an 80-column terminal / Notepad window.
TEXT_WIDTH = 78

# macOS-only keyboard glyphs. The in-app dialog renders the notes with
# the bundled Inter font, which has no glyphs for these — and neither
# does Windows' Segoe UI fallback, so they show as tofu boxes there.
# The shortcuts they spell are also wrong on Windows (Ctrl, not Cmd).
# Name the command instead, or spell the keys out ("Shift+Cmd+4") in
# explicitly-macOS context. See ES-263.
MAC_KEY_GLYPHS = {
    "⌘": "⌘ (Command)",
    "⇧": "⇧ (Shift)",
    "⌥": "⌥ (Option)",
    "⌃": "⌃ (Control)",
    "⇪": "⇪ (Caps Lock)",
    "⎋": "⎋ (Escape)",
    "⌫": "⌫ (Delete)",
    "⏎": "⏎ (Return)",
}

VERSION_HEADER_RE = re.compile(
    r"^##\s+(?P<version>\d+\.\d+\.\d+)\s+[—-]\s+(?P<date>.+?)\s*$"
)
SECTION_HEADER_RE = re.compile(r"^###\s+(?P<name>.+?)\s*$")
BULLET_RE = re.compile(r"^-\s+(?P<text>.+?)\s*$")
CONTINUATION_RE = re.compile(r"^\s{2,}(?P<text>.+?)\s*$")


def parse_date(text: str) -> str:
    """Parse 'May 4, 2026' → '2026-05-04'."""
    return datetime.strptime(text, "%B %d, %Y").date().isoformat()


def parse_releases(text: str) -> list[dict]:
    """Split RELEASES.md into per-version blocks and parse each."""
    lines = text.splitlines()
    releases: list[dict] = []
    current: dict | None = None

    def flush() -> None:
        if current is not None:
            releases.append(parse_release_block(current))

    for line in lines:
        m = VERSION_HEADER_RE.match(line)
        if m:
            flush()
            current = {
                "version": m.group("version"),
                "date_str": m.group("date"),
                "lines": [],
            }
            continue
        if current is None:
            continue  # skip preamble before first version header
        if line.strip() == "---":
            continue
        current["lines"].append(line)

    flush()
    return releases


def parse_release_block(block: dict) -> dict:
    """Parse one release's accumulated lines into structured form."""
    try:
        date_iso = parse_date(block["date_str"])
    except ValueError:
        date_iso = None

    sections: dict[str, list[str]] = {}
    summary_parts: list[str] = []
    current_section: str | None = None
    current_bullet: list[str] | None = None

    def commit_bullet() -> None:
        nonlocal current_bullet
        if current_bullet is not None and current_section is not None:
            sections.setdefault(current_section, []).append(
                " ".join(current_bullet).strip()
            )
        current_bullet = None

    for line in block["lines"]:
        m_section = SECTION_HEADER_RE.match(line)
        if m_section:
            commit_bullet()
            current_section = m_section.group("name").strip().lower()
            sections.setdefault(current_section, [])
            continue

        m_bullet = BULLET_RE.match(line)
        if m_bullet:
            commit_bullet()
            if current_section is None:
                # Headerless change list (0.19.0+): bullets sit directly
                # under the version header, no "### What's new" section.
                current_section = "what's new"
                sections.setdefault(current_section, [])
            current_bullet = [m_bullet.group("text")]
            continue

        if current_section is None:
            if line.strip():
                summary_parts.append(line.strip())
            continue

        m_cont = CONTINUATION_RE.match(line)
        if m_cont and current_bullet is not None:
            current_bullet.append(m_cont.group("text"))
            continue

        if not line.strip():
            commit_bullet()

    commit_bullet()

    # Merged change list: every section's bullets in document order, minus
    # "Known issues". The Highlights / What's new split is gone — the app,
    # the website, and RELEASE_NOTES.txt render one flat list (ES-129).
    notes = [
        b
        for name, bullets in sections.items()
        if name != "known issues"
        for b in bullets
    ]

    return {
        "version": block["version"],
        "date": date_iso,
        "date_display": block["date_str"],
        "notes": notes,
        "known_issues": sections.get("known issues", []),
        "summary": " ".join(summary_parts).strip() or None,
    }


def strip_inline(text: str) -> str:
    """Drop `**bold**` markers, keeping the inner text. Plain text has no
    way to render emphasis, so the asterisks would just be noise."""
    return text.replace("**", "")


def fill(text: str, **kwargs) -> str:
    """textwrap.fill that never mangles paths/URLs: don't break on the
    hyphens in `cross-platform.md` or split a long `https://…` token."""
    return textwrap.fill(
        strip_inline(text),
        width=TEXT_WIDTH,
        break_on_hyphens=False,
        break_long_words=False,
        **kwargs,
    )


def wrap_bullet(text: str) -> str:
    """Wrap one logical bullet with a hanging indent under the marker."""
    return fill(text, initial_indent="  - ", subsequent_indent="    ")


def render_release(rel: dict) -> str:
    """Render one parsed release block as plain text. Header mirrors
    RELEASES.md (`version — date`); no "what's new" sub-heading — the
    file is RELEASE_NOTES.txt, the version header is enough."""
    header = rel["version"]
    if rel.get("date_display"):
        header = f"{rel['version']} — {rel['date_display']}"
    parts = [header, "-" * len(header), ""]

    # Maintenance / placeholder releases carry a prose summary instead of
    # a change list — mirror the in-app dialog's handling.
    if rel["summary"] and not rel["notes"]:
        parts.append(fill(rel["summary"]))
    else:
        parts.append("\n\n".join(wrap_bullet(b) for b in rel["notes"]))
    return "\n".join(parts)


def cmd_text(args: argparse.Namespace) -> int:
    releases = parse_releases(RELEASES_MD.read_text(encoding="utf-8"))
    if not releases:
        print("error: no releases found in RELEASES.md", file=sys.stderr)
        return 1
    # Full history, newest first, releases separated by a blank line.
    sys.stdout.write(
        "\n\n".join(render_release(r) for r in releases).rstrip() + "\n")
    return 0


def cmd_extract(args: argparse.Namespace) -> int:
    target = args.version.lstrip("v")
    text = RELEASES_MD.read_text(encoding="utf-8")
    out: list[str] = []
    capturing = False

    for line in text.splitlines():
        m = VERSION_HEADER_RE.match(line)
        if m:
            if capturing:
                break  # hit the next version header
            if m.group("version") == target:
                capturing = True
                continue  # skip header; release platforms show it
            continue
        if capturing:
            if line.strip() == "---":
                continue
            out.append(line)

    if not out:
        print(f"error: version {target} not found in RELEASES.md",
              file=sys.stderr)
        return 1

    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()

    print("\n".join(out))
    return 0


def cmd_json(args: argparse.Namespace) -> int:
    text = RELEASES_MD.read_text(encoding="utf-8")
    releases = parse_releases(text)
    json.dump({"releases": releases}, sys.stdout, indent=2,
              ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def check_windows_friendly(text: str) -> int:
    """Reject macOS-only keyboard glyphs (see MAC_KEY_GLYPHS). Returns
    the number of offending lines, printing one error per line."""
    count = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        # dict.fromkeys: dedupe repeats on one line, keep first-seen order.
        hits = list(
            dict.fromkeys(
                MAC_KEY_GLYPHS[ch] for ch in line if ch in MAC_KEY_GLYPHS
            )
        )
        if hits:
            count += 1
            print(
                f"error: RELEASES.md:{lineno}: macOS-only keyboard "
                f"glyph(s) {', '.join(hits)} — these render as tofu "
                "boxes on Windows and describe the wrong keys there. "
                "Name the command or spell the shortcut out.",
                file=sys.stderr,
            )
    return count


def main() -> int:
    # Force UTF-8 stdout/stderr. On Windows both default to the
    # console code page (cp1252), so em-dashes and other non-ASCII
    # chars from RELEASES.md can't round-trip through ensure_ascii=False
    # (and the gate's error messages name the offending glyphs).
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(
        description="Parse RELEASES.md into structured release notes."
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_extract = sub.add_parser(
        "extract", help="Print markdown for a single version"
    )
    p_extract.add_argument("version", help="e.g. 0.6.2 or v0.6.2")
    p_extract.set_defaults(func=cmd_extract)

    p_json = sub.add_parser("json", help="Print all releases as JSON")
    p_json.set_defaults(func=cmd_json)

    p_text = sub.add_parser(
        "text", help="Render the full release history as plain text"
    )
    p_text.set_defaults(func=cmd_text)

    args = parser.parse_args()

    # Gate every subcommand (after arg parsing, so --help still works
    # on a dirty file): the notes feed the in-app dialog on all
    # platforms, so un-renderable glyphs are an error at the source.
    if check_windows_friendly(RELEASES_MD.read_text(encoding="utf-8")):
        return 1

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
