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

#ifndef ECLIPSA_STUDIO_ENGINE_ENGINE_LOG_H_
#define ECLIPSA_STUDIO_ENGINE_ENGINE_LOG_H_

#include <stdint.h>

#ifdef __cplusplus
#include <string_view>

extern "C" {
#endif

/// Log levels (match Dart LogLevel ordering).
// NOLINTBEGIN(readability-identifier-naming,modernize-use-using,performance-enum-size)
typedef enum {
  ECLIPSA_STUDIO_LOG_DEBUG = 0,
  ECLIPSA_STUDIO_LOG_INFO = 1,
  ECLIPSA_STUDIO_LOG_WARN = 2,
  ECLIPSA_STUDIO_LOG_ERROR = 3,
} EclipsaStudioLogLevel;

/// Log callback signature.
typedef void (*EclipsaStudioLogCallback)(EclipsaStudioLogLevel level,
                                         const char* category,
                                         const char* message);
// NOLINTEND(readability-identifier-naming,modernize-use-using,performance-enum-size)

/// Register a log callback. Pass NULL to clear. The callback is only
/// ever invoked from eclipsa_studio_rt_log_drain() — never from the thread
/// that logged the message.
void eclipsa_studio_set_log_callback(EclipsaStudioLogCallback callback);

/// Forward messages staged in the log ring — all engine_log() and
/// engine_log_rt() traffic — through the registered callback (and on
/// into the JSONL log file). Call periodically from the main isolate's
/// thread; it must be the only invoker of the Dart callback because
/// calling a NativeCallable from a thread attached to another isolate
/// group (e.g. the video pop-out's decoder worker) aborts the process.
/// No-op when no callback is registered — entries stay in the ring so
/// they are not lost during startup. Single consumer: do not call from
/// more than one thread.
void eclipsa_studio_rt_log_drain(void);

#ifdef __cplusplus
}

/// Stage a log message in the lock-free log ring; delivered to the
/// registered callback by the next eclipsa_studio_rt_log_drain(). Safe from
/// any thread (no heap, no locks, no Dart callback on this thread).
/// Messages are truncated to 511 bytes, the 512-byte ring slot less its
/// terminating NUL. The ring
/// holds 512 entries; when it is full the message is dropped and the
/// drain reports the count, and a dropped WARN or ERROR is written to
/// stderr so the diagnostics of an error storm are not lost.
/// C++ only — not declared in the extern "C" block because callers are
/// all C++ translation units.  If C callers are needed in the future,
/// add an extern "C" wrapper.
void engine_log(EclipsaStudioLogLevel level, const char* category,
                const char* message);

/// engine_log() plus an immediate raw write to stderr, so the message
/// is visible even if the process dies before the next drain. Safe to
/// call from the audio thread. When the ring is full the message still
/// reaches stderr; the drain reports how many ring entries were
/// dropped.
void engine_log_rt(EclipsaStudioLogLevel level, const char* category,
                   const char* message);

/// engine_log() for text that can hold several lines or be longer than a
/// ring slot, such as an iamf-tools status: stages each line of `text` as
/// its own entry, and a line longer than the 511 bytes a slot holds as
/// entries of at most 511 bytes in order, each cut at a UTF-8 character
/// boundary. Lines end at "\n" or "\r\n", and empty lines are skipped.
/// A NUL byte ends the entry it falls in. Entries from other threads can
/// land between the entries of one call. Safe from any thread (no heap,
/// no locks).
void engine_log_lines(EclipsaStudioLogLevel level, const char* category,
                      std::string_view text) noexcept;
#endif

#endif  // ECLIPSA_STUDIO_ENGINE_ENGINE_LOG_H_
