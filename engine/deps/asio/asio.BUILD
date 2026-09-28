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

# Overlay build file for the @asio http_archive (see MODULE.bazel): the
# host-side subset of the Steinberg ASIO SDK 2.3.4, fetched from
# Steinberg at build time. Licensing and the trademark notice are in
# third_party/asio/.
#
# Windows-only: `target_compatible_with` makes any non-Windows target
# that accidentally depends on this get skipped rather than failing the
# build. Keep consumer edges behind a select() so non-Windows build
# graphs never reference it, which also keeps the archive from being
# downloaded on macOS.
load("@rules_cc//cc:defs.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "asio",
    srcs = [
        "common/asio.cpp",
        "host/asiodrivers.cpp",
        "host/pc/asiolist.cpp",
    ],
    hdrs = [
        "common/asio.h",
        "common/asiosys.h",
        "common/iasiodrv.h",
        "host/asiodrivers.h",
        "host/ginclude.h",
        "host/pc/asiolist.h",
    ],
    includes = [
        "common",
        "host",
        "host/pc",
    ],
    # The SDK sources carry no #pragma comment(lib, ...), so the
    # COM/registry link libs are explicit: ole32 for
    # CoCreateInstance/CLSIDFromString in asiolist.cpp, advapi32 for its
    # registry walk, user32 for CharLowerBuff.
    linkopts = [
        "/DEFAULTLIB:ole32.lib",
        "/DEFAULTLIB:advapi32.lib",
        "/DEFAULTLIB:user32.lib",
    ],
    target_compatible_with = ["@platforms//os:windows"],
)
