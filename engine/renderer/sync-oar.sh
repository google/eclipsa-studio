#!/usr/bin/env bash
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

# Regenerate engine/deps/oar/oar.patch and obr.patch from the Eclipsa
# Studio fork of AOMediaCodec/oar, and set OAR_COMMIT in engine/MODULE.bazel
# to the fork's merge base with upstream main, or leave it unchanged with
# --keep-pin.
#
# The engine fetches the public AOMediaCodec/oar at OAR_COMMIT and applies
# the two patches, so the fetched tree equals the fork at <ref>. Fork work
# happens in the fork; this script turns the fork's state into the patches
# the public build applies.
#
# Usage: engine/renderer/sync-oar.sh [--keep-pin] <fork> [<ref>]
#   --keep-pin  write the patches against the current OAR_COMMIT instead
#               of the merge base and leave MODULE.bazel unchanged; the pin
#               must be an ancestor of the merge base
#   <fork>      a local clone of the fork, or its git URL
#   <ref>       the fork commit to regenerate from (default: main). In a
#               local clone the ref is resolved as it stands there; after
#               `git fetch` pass origin/main to use the pushed state.
#
# oar.patch carries every change between the base (the merge base, or
# OAR_COMMIT with --keep-pin) and <ref> except every top-level Markdown
# file (the fork notes, which name private repositories and local paths;
# doc/ is carried) and every .bazelversion file. obr.patch is the slice of
# that diff under src/renderer/obr/obr_capi/obr with paths relative to
# that directory, which the strip_prefix obr override in MODULE.bazel
# applies. .bazelversion is left out because upstream's and the fork's
# copies end without a trailing newline, which Bazel's patch reader
# rejects, and a dependency's .bazelversion has no effect on the consumer.
# The script lists what it left out.
#
# Afterwards run `bazel test //...` from engine/, check the patches for
# private repository names, and commit the patches, together with
# MODULE.bazel when OAR_COMMIT moved.

set -euo pipefail

. "$(dirname "$0")/../deps/sync_patch_lib.sh"

UPSTREAM="https://github.com/AOMediaCodec/oar.git"
PIN="OAR_COMMIT"
GENERATOR="engine/renderer/sync-oar.sh"
OBR_SUBDIR="src/renderer/obr/obr_capi/obr"
OUT_DIR="$ENGINE_DIR/deps/oar"

sync_args "$@"
resolve_fork
read_pin
find_base

write_patch "$OUT_DIR/oar.patch" \
  "Eclipsa Studio changes to AOMediaCodec/oar." \
  "$BASE_SHA" "$FORK_SHA" -- . ':(exclude,glob)*.md' \
  ':(exclude).bazelversion' ':(exclude,glob)**/.bazelversion'
write_patch "$OUT_DIR/obr.patch" \
  "Eclipsa Studio changes to AOMediaCodec/oar under $OBR_SUBDIR, paths relative to it." \
  --relative="$OBR_SUBDIR/" "$BASE_SHA" "$FORK_SHA" -- "$OBR_SUBDIR" \
  ":(exclude)$OBR_SUBDIR/.bazelversion"
report_omitted "$OUT_DIR/oar.patch"
update_pin

echo
echo "Now run 'bazel test //...' from engine/ and commit deps/oar/*.patch,"
echo "with MODULE.bazel when OAR_COMMIT moved."
