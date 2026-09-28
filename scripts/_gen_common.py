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

"""Shared by the generator scripts (gen_design_tokens.py,
gen_component_index.py): the repository root, the error type that
fails a build, and the app's Dart language version."""

import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class GenError(Exception):
    """A validation failure that must fail the build."""


def app_language_version():
    """The Dart language version of the app package, e.g. "3.11".

    The generated file is formatted in a temp directory, outside the
    package, where `dart format` would fall back to its newest style.
    `build.sh lint --check` formats app/ under the package's own version
    (the lower bound of `environment.sdk` in app/pubspec.yaml), so the
    generator passes the same one.
    """
    text = (REPO / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^\s+sdk:\s*[\^>=\"']*(\d+)\.(\d+)", text, re.MULTILINE)
    if not m:
        raise GenError("app/pubspec.yaml has no environment.sdk version")
    return f"{m.group(1)}.{m.group(2)}"
