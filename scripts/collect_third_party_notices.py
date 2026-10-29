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

"""Generate third-party license notices for Eclipsa Studio (ES-57).

Outputs (committed to the repo):
  app/assets/third_party_notices.json
      Structured entries registered into Flutter's LicenseRegistry at
      startup, shown in the app's Third-Party Licenses window
      (widgets/licenses_dialog.dart). Dart/Flutter package licenses are
      NOT here -- Flutter embeds those itself (NOTICES) and the same
      window shows them.
  third_party/THIRD_PARTY_NOTICES.txt
      Plain-text aggregate, staged next to the app by `./build.sh
      package` (DMG) and `build.ps1 package` (Windows zip).

The C++ engine dependency texts are read from the engine's Bazel
external repos, so the output always matches the pinned versions in
engine/MODULE.bazel. Run any bazel build first so the repos are
fetched. Run from the repo root:

    python3 scripts/collect_third_party_notices.py            # generate
    python3 scripts/collect_third_party_notices.py --check    # drift gate
    python3 scripts/collect_third_party_notices.py \
        --verify-bundle <path to .app>                        # framework gate

--check regenerates to memory and fails if the committed files differ
(package-time gate: commit the regenerated files). --verify-bundle
fails if the app bundle ships a framework that is not attributed below
(catches new plugin frameworks appearing silently); a framework is
attributed either by the VENDORED_DEPS entry that names it and carries
its full text, or, for Flutter's own, by Flutter's NOTICES.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
JSON_OUT = REPO / "app/assets/third_party_notices.json"
TXT_OUT = REPO / "third_party/THIRD_PARTY_NOTICES.txt"

# ── C++ engine dependencies (statically linked into libeclipsa_studio_engine) ──
# Display names of the codec libraries, keyed by codec: --no-<codec>
# leaves that entry out of the notices. ENGINE_DEPS takes the names of
# those entries from here, so renaming one keeps its flag working.
CODEC_DEP_NAMES = {
    "aac": "Fraunhofer FDK AAC codec library",
    "flac": "FLAC (libFLAC)",
    "opus": "Opus (libopus)",
}

# (display name, license label, bazel external dir, license files)
ENGINE_DEPS = [
    ("iamf-tools", "BSD 3-Clause", "iamf_tools+", ["LICENSE"]),
    # Our NOTICE (source commit, what is linked) precedes upstream's
    # license text, which section 2 of that license requires in full.
    (CODEC_DEP_NAMES["aac"], "FDK AAC license (see NOTICE)",
     "iamf_tools++_repo_rules+fdk_aac", ["NOTICE"],
     ["third_party/fdk_aac/NOTICE"]),
    (CODEC_DEP_NAMES["flac"], "BSD 3-Clause (Xiph)",
     "flac+", ["COPYING.Xiph"]),
    (CODEC_DEP_NAMES["opus"], "BSD 3-Clause",
     "opus+", ["COPYING"]),
    ("loudness_ebur128", "Apache License 2.0",
     "loudness_ebur128+", ["LICENSE"]),
    ("Abseil (abseil-cpp)", "Apache License 2.0",
     "abseil-cpp+", ["LICENSE"]),
    ("Protocol Buffers", "BSD 3-Clause", "protobuf+", ["LICENSE"]),
    # Reaches the engine link (libz.a) through protobuf's io:gzip_stream,
    # which the iamf-tools proto libraries depend on; no engine code calls
    # the gzip streams. Not a dependency of engine/MODULE.bazel itself.
    ("zlib", "zlib License", "zlib+", ["LICENSE"]),
    ("Eigen", "MPL 2.0 (with BSD-licensed parts)",
     "eigen+", ["COPYING.README", "COPYING.MPL2", "COPYING.BSD"]),
    # OAR and the nested OBR renderer are both under the BSD 3-Clause Clear
    # License; the patent grant is the separate AOM Patent License 1.0 in the
    # PATENTS file (the Clear BSD grants no patent rights, and the source
    # headers defer to PATENTS). AOM Patent License §1.2.1.b requires
    # reproducing it in the legal notices of any binary distribution, so both
    # files are included. (Was previously mislabelled "Apache License 2.0".)
    ("Open Audio Renderer (OAR / OBR)",
     "BSD 3-Clause Clear License + AOM Patent License 1.0",
     "oar+", ["LICENSE", "PATENTS"]),
    ("libsamplerate", "BSD 2-Clause",
     "+_repo_rules+libsamplerate", ["COPYING"]),
    # dr_wav was removed in the WAV-library consolidation (engine/wav
    # replaced it); its entry left with it.
]

# PFFFT ships its license as the leading comment of its sources. The repo
# is declared by obr's module extension since oar moved to its upstream
# Bazel module (it was the oar fork's non_module_deps shim before).
PFFFT_DIR = "obr++pffft_ext+pffft"

# ── Vendored dynamically-linked libraries ────────────────────────────────
# libgpac powers Export to MP4 (engine/iamf/iamf_muxer.cc). It is LGPL-2.1,
# linked dynamically and shipped as a separate .dylib that we build and
# vendor ourselves — so we carry its full license text plus the LGPL
# section-6 relink provision here. Read from checked-in files under
# third_party/gpac (not a Bazel external repo).
# (display name, license label, repo-relative files concatenated as text,
#  names of the .framework bundles in Contents/Frameworks this entry
#  attributes -- empty when the component ships as no framework)
VENDORED_DEPS = [
    ("GPAC (libgpac)", "LGPL-2.1-or-later",
     ["third_party/gpac/NOTICE",
      "third_party/gpac/LICENSE.LGPL-2.1.txt"],
     set()),
    # FFmpeg (+ dav1d) power the FFmpeg-in-engine video backend
    # (engine/video, ES-249). Like libgpac they are LGPL/BSD, built and vendored
    # by us (engine/deps/ffmpeg/build_ffmpeg.sh) and shipped as separate
    # .dylibs, so we carry the full FFmpeg LGPL text + section-6 relink
    # provision and the dav1d BSD text here.
    ("FFmpeg (libav*, video backend)",
     "LGPL-2.1-or-later (FFmpeg) + BSD-2-Clause (dav1d)",
     ["third_party/ffmpeg/NOTICE",
      "third_party/ffmpeg/LICENSE.LGPL-2.1.txt",
      "third_party/ffmpeg/LICENSE.dav1d.txt"],
     set()),
    # The ASIO SDK host subset is compiled into the Windows engine DLL
    # only (ES-101). The SDK is fetched from Steinberg at build time and
    # linked statically; the license and the Steinberg trademark
    # attribution are read from third_party/asio/, and the SDK is used
    # under the executed Steinberg agreement (third_party/asio/README.md).
    ("Steinberg ASIO SDK (Windows host interface)",
     "Steinberg ASIO License (proprietary)",
     ["third_party/asio/NOTICE",
      "third_party/asio/LICENSE",
      "third_party/asio/LICENSE.host"],
     set()),
    # Inter and JetBrains Mono, the two bundled typefaces, ship as app
    # assets rather than vendored source: the .ttf files live under
    # app/assets/fonts/ because pubspec asset paths cannot escape the
    # package root. Their OFL texts have no such constraint and sit under
    # third_party/fonts/<family>/LICENSE with every other third-party
    # license (see app/assets/fonts/README.md).
    # ANGLE ships beside the app as dynamically linked libraries (.framework
    # on macOS, .dll on Windows). BSD 3-Clause requires a binary
    # redistribution to reproduce the notice, conditions and disclaimer in
    # the material shipped with it, so the text is embedded rather than
    # linked (ES-708). Which binaries ship on which platform is in the NOTICE,
    # with the components the Windows DLLs link statically: xxHash and
    # Chromium's zlib, whose texts follow ANGLE's (ES-735).
    ("ANGLE (libEGL, libGLESv2)",
     "BSD 3-Clause (ANGLE) + BSD-2-Clause (xxHash) + Zlib + "
     "BSD 3-Clause (Chromium)",
     ["third_party/angle/NOTICE",
      "third_party/angle/LICENSE",
      "third_party/angle/LICENSE.xxhash",
      "third_party/angle/LICENSE.zlib",
      "third_party/angle/LICENSE.chromium"],
     {"libEGL", "libGLESv2"}),
    ("Inter (UI typeface)", "SIL Open Font License 1.1",
     ["third_party/fonts/inter/LICENSE"], set()),
    ("JetBrains Mono (monospace typeface)", "SIL Open Font License 1.1",
     ["third_party/fonts/jetbrains_mono/LICENSE"], set()),
    # No font file ships. The Eclipsa Audio wordmark is drawn from
    # twelve glyph outlines read out of the font into
    # app/lib/widgets/eclipsa_audio_wordmark_data.dart
    # (third_party/fonts/google_sans/README.md).
    ("Google Sans (Eclipsa Audio wordmark glyph outlines)",
     "SIL Open Font License 1.1",
     ["third_party/fonts/google_sans/LICENSE"], set()),
]

# ── Dynamically linked frameworks in the app bundle ──────────────────────
# The .framework bundles whose full license text a VENDORED_DEPS entry
# carries, read from the entries so the two cannot drift. The package
# step verifies the shipped framework set against this set and
# FLUTTER_FRAMEWORKS (--verify-bundle) so new frameworks can't ship
# unattributed.
VENDORED_FRAMEWORKS = {fw for _, _, _, fws in VENDORED_DEPS for fw in fws}

# Frameworks that are Flutter itself or pub-package plugin code: their
# licenses are embedded by Flutter's NOTICES mechanism and shown on the
# same in-app licenses page, so they need no entry above.
FLUTTER_FRAMEWORKS = {
    "App", "FlutterMacOS", "desktop_multi_window", "flutter_angle",
    "macos_secure_bookmarks", "objective_c",
}

# User-facing: THIRD_PARTY_NOTICES.txt ships beside the app in the DMG
# and the Windows zip. Keep internal names, build-file paths and menu
# labels out of the header -- the menu label has already changed once.
HEADER = """\
Eclipsa Studio — Third-Party Notices

Eclipsa Studio includes third-party software. The entries below carry
the attributions and license texts those licenses require.

Dart and Flutter package licenses are not listed here. Flutter embeds
them in the application, which displays them alongside these entries.

This file is generated. Do not edit it by hand.
"""


def bazel_output_base() -> Path:
    out = subprocess.run(
        ["bazel", "info", "output_base"],
        cwd=REPO / "engine", capture_output=True, text=True, check=True)
    return Path(out.stdout.strip())


def read_license(base: Path, repo_dir: str, rel: str) -> str:
    path = base / "external" / repo_dir / rel
    if not path.is_file():
        sys.exit(f"error: license file missing: {path}\n"
                 "Run a bazel build first so external repos are fetched.")
    return path.read_text(encoding="utf-8", errors="replace").strip()


def read_repo_file(rel: str) -> str:
    path = REPO / rel
    if not path.is_file():
        sys.exit(f"error: notice file missing: {path}")
    return path.read_text(encoding="utf-8", errors="replace").strip()


def pffft_license(base: Path) -> str:
    """PFFFT's license is the leading block comment of pffft.h."""
    src = (base / "external" / PFFFT_DIR / "pffft.h").read_text(
        encoding="utf-8", errors="replace")
    m = re.match(r"\s*/\*(.*?)\*/", src, re.DOTALL)
    if not m:
        sys.exit("error: could not extract PFFFT license header")
    return "\n".join(
        line.lstrip().lstrip("*").strip() for line in m.group(1).splitlines()
    ).strip()


def join_texts(files: list[str], texts: list[str]) -> str:
    """One entry's text from its files.

    A single file is reproduced as is. When an entry carries several
    (Eigen's three COPYING files, OAR's LICENSE and PATENTS, a NOTICE of
    ours before an upstream licence), each is headed by its file name,
    so a reader can tell where one text ends and the next begins and
    match a "see COPYING.MPL2" in one file to the text it means (ES-737).
    """
    if len(files) == 1:
        return texts[0]
    names = [Path(f).name for f in files]
    # Two files of the same name (our NOTICE before upstream's NOTICE)
    # are headed by their full paths instead.
    if len(set(names)) < len(names):
        names = files
    return "\n\n".join(
        f"---- {n} ----\n\n{t}" for n, t in zip(names, texts)
    )


def collect(excluded: set[str] = frozenset()) -> list[dict]:
    base = bazel_output_base()
    components = []
    for name, label, repo_dir, files, *rest in ENGINE_DEPS:
        if name in excluded:
            continue
        # An optional fifth element lists notice files of ours, under
        # third_party/, placed before the upstream license files.
        ours = rest[0] if rest else []
        text = join_texts(
            ours + files,
            [read_repo_file(f) for f in ours]
            + [read_license(base, repo_dir, f) for f in files])
        components.append({
            "name": name, "license": label, "kind": "engine", "text": text,
        })
    components.append({
        "name": "PFFFT",
        "license": "BSD-like (FFTPACK license)",
        "kind": "engine",
        "text": pffft_license(base),
    })

    for name, label, files, fws in VENDORED_DEPS:
        text = join_texts(files, [read_repo_file(f) for f in files])
        # `kind` is what the in-app licenses window groups by: an entry
        # that ships .framework bundles is listed under Bundled
        # Frameworks, everything else under the engine's libraries.
        components.append({
            "name": name, "license": label,
            "kind": "framework" if fws else "engine", "text": text,
        })
    return components


def render_txt(components: list[dict]) -> str:
    parts = [HEADER]
    for c in components:
        bar = "=" * 72
        parts.append(f"{bar}\n{c['name']}  ({c['license']})\n{bar}\n\n{c['text']}\n")
    return "\n".join(parts)


def render_json(components: list[dict]) -> str:
    return json.dumps({"components": components}, indent=2,
                      ensure_ascii=False) + "\n"


def verify_bundle(app_path: Path) -> None:
    fw_dir = app_path / "Contents" / "Frameworks"
    if not fw_dir.is_dir():
        sys.exit(f"error: no Frameworks dir at {fw_dir}")
    shipped = {p.name.removesuffix(".framework")
               for p in fw_dir.iterdir()
               if p.name.endswith(".framework")}
    known = VENDORED_FRAMEWORKS | FLUTTER_FRAMEWORKS
    unattributed = shipped - known
    if unattributed:
        sys.exit("error: shipped frameworks without attribution entries "
                 "(name each in the frameworks set of the VENDORED_DEPS "
                 "entry that carries its license text, or in "
                 f"FLUTTER_FRAMEWORKS if Flutter's NOTICES carry it, in "
                 f"{Path(__file__).name}): "
                 + ", ".join(sorted(unattributed)))
    print(f"Framework attribution check OK ({len(shipped)} frameworks).")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="fail if committed outputs differ from regenerated")
    ap.add_argument("--verify-bundle", metavar="APP",
                    help="verify every shipped framework is attributed")
    ap.add_argument("--no-aac", action="store_true",
                    help="omit Fraunhofer FDK AAC notice (when built with "
                         "IAMF_TOOLS_DISABLE_AAC_{DECODER,ENCODER})")
    ap.add_argument("--no-flac", action="store_true",
                    help="omit FLAC notice (when built with "
                         "IAMF_TOOLS_DISABLE_FLAC_{DECODER,ENCODER})")
    ap.add_argument("--no-opus", action="store_true",
                    help="omit Opus notice (when built with "
                         "IAMF_TOOLS_DISABLE_OPUS_{DECODER,ENCODER})")
    args = ap.parse_args()

    if args.verify_bundle:
        verify_bundle(Path(args.verify_bundle))
        return

    excluded = {
        dep_name for codec, dep_name in CODEC_DEP_NAMES.items()
        if getattr(args, f"no_{codec}")
    }
    components = collect(excluded)
    txt, js = render_txt(components), render_json(components)

    if args.check:
        stale = []
        if not TXT_OUT.is_file() or TXT_OUT.read_text(encoding="utf-8") != txt:
            stale.append(str(TXT_OUT.relative_to(REPO)))
        if (not JSON_OUT.is_file()
                or JSON_OUT.read_text(encoding="utf-8") != js):
            stale.append(str(JSON_OUT.relative_to(REPO)))
        if stale:
            sys.exit("error: third-party notices are stale: "
                     + ", ".join(stale)
                     + "\nRegenerate and commit: "
                       "python3 scripts/collect_third_party_notices.py")
        print("Third-party notices up to date.")
        return

    TXT_OUT.write_text(txt, encoding="utf-8")
    JSON_OUT.write_text(js, encoding="utf-8")
    print(f"Wrote {TXT_OUT.relative_to(REPO)} "
          f"and {JSON_OUT.relative_to(REPO)} "
          f"({len(components)} components).")


if __name__ == "__main__":
    main()
