// Copyright 2026 Google LLC
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

// Headless render/export CLI over the engine internals (issue ES-39).
// All logic lives in tools/cli_commands.cc so unit tests can drive the
// subcommands in-process.

#include <iostream>

#include "absl/base/log_severity.h"
#include "absl/log/globals.h"
#include "absl/log/initialize.h"
#include "tools/cli_commands.h"

int main(int argc, char** argv) {
  // iamf-tools logs its descriptor OBUs and audio frames at INFO: 263
  // stderr lines for a 0.5 s encode of the multi_mix golden. Keep
  // warnings and errors. The settings apply to every absl user in the
  // process. Before InitializeLog(), absl writes every severity to
  // stderr and ignores the stderr threshold.
  absl::InitializeLog();
  absl::SetMinLogLevel(absl::LogSeverityAtLeast::kWarning);
  absl::SetStderrThreshold(absl::LogSeverityAtLeast::kWarning);
  return eclipsa_studio::cli::RunCli(argc, argv, std::cout, std::cerr);
}
