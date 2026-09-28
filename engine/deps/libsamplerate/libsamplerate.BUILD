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

# Overlay build file for the @libsamplerate http_archive (see MODULE.bazel).
# Upstream builds with CMake/autotools which generate config.h; here the
# handful of macros the sources actually need are passed as defines
# instead (HAVE_CONFIG_H stays unset).
load("@rules_cc//cc:defs.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "samplerate",
    srcs = [
        "src/common.h",
        "src/fastest_coeffs.h",
        "src/high_qual_coeffs.h",
        "src/mid_qual_coeffs.h",
        "src/samplerate.c",
        "src/src_linear.c",
        "src/src_sinc.c",
        "src/src_zoh.c",
    ],
    hdrs = ["include/samplerate.h"],
    includes = ["include"],
    local_defines = [
        "ENABLE_SINC_BEST_CONVERTER",
        "ENABLE_SINC_MEDIUM_CONVERTER",
        "ENABLE_SINC_FAST_CONVERTER",
        "HAVE_STDBOOL_H",
        'PACKAGE=\\"libsamplerate\\"',
        'VERSION=\\"0.2.2\\"',
    ],
)
