/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef ECLIPSA_STUDIO_TOOLS_CLI_COMMANDS_H_
#define ECLIPSA_STUDIO_TOOLS_CLI_COMMANDS_H_

#include <ostream>
#include <string>
#include <vector>

/// Subcommand implementations for eclipsa_studio_cli (issue ES-39 proposal 1).
///
/// Thin wrappers over existing engine internals — ElementBouncer,
/// OfflineMixRenderer, IamfExporter, eclipsa_studio_iamf_probe — with no new
/// audio logic. Factored out of main() so unit tests can drive them
/// in-process with captured streams.
///
/// Each Run* takes the arguments AFTER the subcommand word and returns
/// a process exit code: 0 success, 1 usage/input error, 2 runtime
/// failure. Normal output goes to `out`, diagnostics to `err`.
namespace eclipsa_studio::cli {

int RunBounce(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err);
int RunMeasure(const std::vector<std::string>& args, std::ostream& out,
               std::ostream& err);
int RunEncode(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err);
int RunProbe(const std::vector<std::string>& args, std::ostream& out,
             std::ostream& err);

/// Top-level dispatch (argv[1] selects the subcommand). Prints usage
/// and returns 1 for unknown/missing subcommands.
int RunCli(int argc, const char* const* argv, std::ostream& out,
           std::ostream& err);

}  // namespace eclipsa_studio::cli

#endif  // ECLIPSA_STUDIO_TOOLS_CLI_COMMANDS_H_
