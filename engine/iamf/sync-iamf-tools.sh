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
# engine/MODULE.bazel to the fork's merge base with upstream main, or leave
# it unchanged with --keep-pin.
#
# The engine fetches the public AOMediaCodec/iamf-tools at
# IAMF_TOOLS_COMMIT and applies the patch. Fork work happens in the fork;
# this script turns the fork's state into the patch the public build
# applies.
#
# Usage: engine/iamf/sync-iamf-tools.sh [--keep-pin] <fork> [<ref>]
#   --keep-pin  write the patch against the current IAMF_TOOLS_COMMIT instead of
#               the merge base and leave MODULE.bazel unchanged; the pin
#               must be an ancestor of the merge base
#   <fork>      a local clone of the fork, or its git URL
#   <ref>       the fork commit to regenerate from (default: main). In a
#               local clone the ref is resolved as it stands there; after
#               `git fetch` pass origin/main to use the pushed state.
#
# The patch is limited to the paths listed in PATHS below, which the
# engine builds: the probe library and probe_main, the stream API under
# iamf/api/stream and iamf/include/iamf_tools, the in-place span and
# segmented readers under iamf/common, and the BUILD files that make
# those targets public and disable iamf-tools' own binaural renderer. A
# listed path that matches upstream adds nothing to the patch. Two
# listed paths currently match upstream, iamf/cli/probe_json.cc and
# iamf/common/read_bit_buffer.cc, because upstream has merged their
# fork changes; they stay listed so a later fork change to them is
# carried.
# iamf_extract_main.cc rides along because iamf/cli/BUILD declares it.
# The fork's tests, binary test data, WASM build files and docs stay out.
# The script lists every fork change it left out; a new source file next
# to the carried ones needs an entry in PATHS. With --keep-pin it also
# lists the files upstream changed between IAMF_TOOLS_COMMIT and the merge
# base outside PATHS: the patched tree keeps the pinned version of those,
# so a carried file that depends on the newer version does not build.
#
# Afterwards run `bazel test //...` from engine/, check the patch for
# private repository names, and commit the patch, together with
# MODULE.bazel when IAMF_TOOLS_COMMIT moved.

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
  iamf/common/BUILD
  iamf/common/read_bit_buffer.cc
  iamf/common/segmented_read_bit_buffer.cc
  iamf/common/segmented_read_bit_buffer.h
  iamf/common/span_read_bit_buffer.cc
  iamf/common/span_read_bit_buffer.h
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
echo "deps/iamf_tools/iamf_tools.patch, with MODULE.bazel when"
echo "IAMF_TOOLS_COMMIT moved."
