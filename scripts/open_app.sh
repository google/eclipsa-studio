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

# Launch the already-compiled Eclipsa Studio.app — no engine rebuild,
# no flutter build. Useful for re-opening the last build quickly.
#
#   ./scripts/open_app.sh            # release build (the default)
#   ./scripts/open_app.sh debug      # debug build
#
# The binary is exec'd directly (not `open`) so stdout/stderr —
# including the engine's rt log — land in this terminal and the
# terminal returns when the app exits. Build first with ./build.sh
# if the bundle is missing or stale.

set -euo pipefail

die() { echo "error: $1" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Eclipsa Studio"

CONFIG=Release
case "${1:-}" in
  "" | release) ;;
  debug)        CONFIG=Debug ;;
  -h|--help)    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)            die "unknown argument: $1 (see --help)" ;;
esac

APP_PATH="$REPO_ROOT/app/build/macos/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || die "no $CONFIG build at $APP_PATH — run ./build.sh first"

echo "Launching $APP_PATH"
exec "$APP_PATH/Contents/MacOS/$APP_NAME"
