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

# Regenerate engine/deps/iamf_tools/iamf_tools.patch from the Eclipsa
# Studio fork of AOMediaCodec/iamf-tools, and set IAMF_TOOLS_COMMIT in
# engine/MODULE.bazel to the fork's merge base with upstream main.
#
# The engine fetches the public AOMediaCodec/iamf-tools at
# IAMF_TOOLS_COMMIT and applies the patch. Fork work happens in the fork;
# this script turns the fork's state into the patch the public build
# applies.
#
# Usage: engine/iamf/sync-iamf-tools.sh <fork> [<ref>]
#   <fork>  a local clone of the fork, or its git URL
#   <ref>   the fork commit to regenerate from (default: main). In a local
#           clone the ref is resolved as it stands there; after `git fetch`
#           pass origin/main to use the pushed state.
#
# The patch carries only the paths the engine builds, listed in PATHS
# below: the probe library and probe_main, the stream API under
# iamf/api/stream and iamf/include/iamf_tools, and the BUILD files that
# make those targets public and disable iamf-tools' own binaural renderer.
# iamf_extract_main.cc rides along because iamf/cli/BUILD declares it.
# The fork's tests, binary test data, WASM build files and docs stay out.
# The script lists every fork change it left out; a new source file next
# to the carried ones needs an entry in PATHS.
#
# Afterwards run `bazel test //...` from engine/, check the patch for
# private repository names, and commit the patch and MODULE.bazel
# together.

set -euo pipefail

. "$(dirname "$0")/../deps/sync_patch_lib.sh"

UPSTREAM="https://github.com/AOMediaCodec/iamf-tools.git"
PIN="IAMF_TOOLS_COMMIT"
GENERATOR="engine/iamf/sync-iamf-tools.sh"
OUT="$ENGINE_DIR/deps/iamf_tools/iamf_tools.patch"

PATHS=(
  iamf/api/stream
  ':(exclude)iamf/api/stream/tests'
  iamf/cli/BUILD
  iamf/cli/iamf_extract_main.cc
  iamf/cli/probe.cc
  iamf/cli/probe.h
  iamf/cli/probe_json.cc
  iamf/cli/probe_main.cc
  iamf/cli/proto/BUILD
  iamf/include/iamf_tools
  ':(exclude)iamf/include/iamf_tools/tests'
)

sync_args "$@"
resolve_fork
read_pin
find_base

write_patch "$OUT" \
  "Eclipsa Studio changes to AOMediaCodec/iamf-tools: the probe and stream API paths the engine builds." \
  "$BASE_SHA" "$FORK_SHA" -- "${PATHS[@]}"
report_omitted "$OUT"
update_pin

echo
echo "Now run 'bazel test //...' from engine/ and commit"
echo "deps/iamf_tools/iamf_tools.patch with MODULE.bazel."
