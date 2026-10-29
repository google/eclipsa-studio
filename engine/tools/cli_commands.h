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

#include <cstdint>
#include <functional>
#include <ostream>
#include <string>
#include <vector>

/// Subcommand implementations for eclipsa_studio_cli (issue ES-39 proposal 1).
///
/// Thin wrappers over existing engine internals — ElementBouncer,
/// OfflineMixRenderer, OfflineIamfMeasurer, IamfExporter, IamfMuxer,
/// eclipsa_studio_iamf_probe — with no new audio logic. Factored out of
/// main() so unit tests can drive them in-process with captured streams.
///
/// Each Run* takes the arguments AFTER the subcommand word and returns
/// a process exit code: 0 success; 1 the arguments are rejected, before
/// any file is read or because they do not fit the input file; 2 a
/// failure reading, decoding or writing a file. Normal output goes to
/// `out`, diagnostics to `err`.
namespace eclipsa_studio::cli {

/// What an input file holds, judged from its first 12 bytes.
enum class InputKind : uint8_t {
  kUnreadable,  // missing, not a regular file, or cannot be opened
  kWav,         // a RIFF, RF64 or BW64 header with the WAVE form type
  kOther,       // anything else, such as a raw IA sequence or an MP4
};
InputKind DetectInputKind(const std::string& path);

int RunBounce(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err);
/// Measures a mix WAV, or a .iamf or an MP4 with an IAMF track, chosen by
/// DetectInputKind.
int RunMeasure(const std::vector<std::string>& args, std::ostream& out,
               std::ostream& err);
/// measure-iamf, the old name of measure: calls RunMeasure.
int RunMeasureIamf(const std::vector<std::string>& args, std::ostream& out,
                   std::ostream& err);
int RunEncode(const std::vector<std::string>& args, std::ostream& out,
              std::ostream& err);
int RunProbe(const std::vector<std::string>& args, std::ostream& out,
             std::ostream& err);

/// Runs `subcommand` and returns its exit code. A std::exception thrown
/// out of it is caught, reported on `err` as "error: <what>", and the
/// exit code is 2. Catching it unwinds the stack, so destructors that
/// remove scratch files run; an uncaught exception may terminate the
/// process without unwinding.
int RunCatchingExceptions(const std::function<int()>& subcommand,
                          std::ostream& err);

/// Top-level dispatch (argv[1] selects the subcommand) through
/// RunCatchingExceptions. `--help`, `-h` and `help` print the usage to
/// `out` and return 0; a missing or unknown subcommand prints it to `err`
/// and returns 1. `--help` or `-h` after a subcommand prints the usage of
/// that subcommand to `out` and returns 0.
///
/// For the duration of the subcommand, RunCli registers the process-wide
/// engine log callback (eclipsa_studio_set_log_callback), discards the
/// entries staged before the call, prints each WARN and ERROR entry the
/// subcommand logged to `err` as "engine error [category]: message" or
/// "engine warning [category]: message", and then sets the callback to
/// null. It must not run concurrently with another RunCli call or in a
/// process that has another engine log consumer.
int RunCli(int argc, const char* const* argv, std::ostream& out,
           std::ostream& err);

}  // namespace eclipsa_studio::cli

#endif  // ECLIPSA_STUDIO_TOOLS_CLI_COMMANDS_H_
