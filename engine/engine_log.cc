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

#include "engine_log.h"

#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
std::atomic<EclipsaStudioLogCallback> g_log_callback{nullptr};

// strdup that falls back to an empty string on null/alloc failure.
char* safe_strdup(const char* s) {
  if (!s) s = "";
  char* copy = static_cast<char*>(malloc(strlen(s) + 1));
  if (!copy) return nullptr;
  strcpy(copy, s);
  return copy;
}

// Invoke the registered Dart callback with heap-copied strings (the
// Dart listener frees them with eclipsa_studio_string_free() — the copies are
// CRT-malloc'd, so the host runtime's own deallocator must not be
// used; see the eclipsa_studio_string_free() doc). Must only be called
// from eclipsa_studio_rt_log_drain(): the callback is a NativeCallable owned
// by the main isolate, and invoking it from a thread attached to a
// different isolate group — e.g. the video pop-out's decoder worker,
// a second Flutter engine in the same process — corrupts that
// thread's execution state in the Dart VM's cross-isolate-group
// callback path and aborts the process on the next invocation
// ("Cannot invoke native callback from a leaf call.").
void deliver_to_callback(EclipsaStudioLogLevel level, const char* cat,
                         const char* msg) {
  auto cb = g_log_callback.load(std::memory_order_relaxed);
  // Accepted loss: an entry already popped from the ring is dropped
  // if the callback unregisters mid-drain during shutdown teardown.
  if (!cb) return;
  char* cat_copy = safe_strdup(cat);
  char* msg_copy = safe_strdup(msg);
  if (cat_copy && msg_copy) {
    cb(level, cat_copy, msg_copy);
  } else {
    free(cat_copy);
    free(msg_copy);
  }
}

// ── Log ring ────────────────────────────────────────────────────────
//
// All C++ log traffic is staged in this fixed-size lock-free ring
// (Vyukov bounded MPMC: producers are any engine thread — control,
// audio, video decode workers — one consumer). eclipsa_studio_rt_log_drain(),
// called periodically on the main isolate's thread, forwards staged
// entries through the registered Dart callback into the JSONL file.
// Nothing else may touch the callback: see deliver_to_callback().

constexpr uint32_t kLogRingCapacity = 512;  // power of two
constexpr uint32_t kLogRingMask = kLogRingCapacity - 1;

struct LogEntry {
  std::atomic<uint32_t> seq{0};
  EclipsaStudioLogLevel level = ECLIPSA_STUDIO_LOG_DEBUG;
  char category[16] = {};
  // Sized to the largest snprintf buffer any engine_log() caller
  // formats into (512), so staging never truncates existing messages.
  char message[512] = {};
};

struct LogRing {
  LogEntry cells[kLogRingCapacity];
  std::atomic<uint32_t> head{0};     // producers claim slots here
  std::atomic<uint32_t> tail{0};     // consumer position
  std::atomic<uint32_t> dropped{0};  // ring-full discards since last drain

  LogRing() noexcept {
    for (uint32_t i = 0; i < kLogRingCapacity; ++i) {
      cells[i].seq.store(i, std::memory_order_relaxed);
    }
  }
};

// Plain global (not function-local static): dynamic init runs at load
// time, before any audio thread exists, so producers never hit a
// C++ static-init guard lock.
LogRing g_log_ring;

// Bounded copy that always NUL-terminates.
void ring_copy(char* dst, size_t dst_size, const char* src) {
  if (!src) src = "";
  snprintf(dst, dst_size, "%s", src);
}

// Raw write() to stderr: no stdio lock (fprintf would take one, and a
// lower-priority thread holding it would block the audio thread), no
// heap. write() can still block on a pipe whose reader has stalled, so
// callers keep it for rare events, never per-callback logging.
void write_stderr(EclipsaStudioLogLevel level, const char* cat,
                  const char* msg) {
  static constexpr const char* kLevelStr[] = {"DEBUG", "INFO", "WARN", "ERROR"};
  const int idx = (level >= 0 && level <= 3) ? level : 0;
  char buf[512];
  int n = snprintf(buf, sizeof(buf), "[%s] [%s] %s\n", kLevelStr[idx],
                   cat ? cat : "", msg ? msg : "");
  if (n <= 0) return;
  auto len = static_cast<size_t>(n);
  if (len >= sizeof(buf)) len = sizeof(buf) - 1;
#ifdef _WIN32
  (void)_write(_fileno(stderr), buf, static_cast<unsigned int>(len));
#else
  (void)write(STDERR_FILENO, buf, len);
#endif
}

// Stages one entry. When the ring is full the entry is dropped and
// counted; with `stderr_on_drop`, a dropped WARN or ERROR is written to
// stderr instead, so a storm of control-thread errors that overruns the
// ring within one drain interval still leaves its diagnostics somewhere
// (ES-270). engine_log_rt() has already written to stderr and passes false.
void ring_push(EclipsaStudioLogLevel level, const char* cat, const char* msg,
               bool stderr_on_drop) {
  uint32_t pos = g_log_ring.head.load(std::memory_order_relaxed);
  for (;;) {
    LogEntry& cell = g_log_ring.cells[pos & kLogRingMask];
    const uint32_t seq = cell.seq.load(std::memory_order_acquire);
    const auto dif = static_cast<int32_t>(seq - pos);
    if (dif == 0) {
      if (g_log_ring.head.compare_exchange_weak(pos, pos + 1,
                                                std::memory_order_relaxed)) {
        cell.level = level;
        ring_copy(cell.category, sizeof(cell.category), cat);
        ring_copy(cell.message, sizeof(cell.message), msg);
        cell.seq.store(pos + 1, std::memory_order_release);
        return;
      }
      // CAS failed: pos was reloaded by compare_exchange — retry.
    } else if (dif < 0) {
      // Ring full — account for the loss so the drain can report it.
      g_log_ring.dropped.fetch_add(1, std::memory_order_relaxed);
      if (stderr_on_drop && level >= ECLIPSA_STUDIO_LOG_WARN) {
        write_stderr(level, cat, msg);
      }
      return;
    } else {
      pos = g_log_ring.head.load(std::memory_order_relaxed);
    }
  }
}
}  // namespace

extern "C" void eclipsa_studio_set_log_callback(
    EclipsaStudioLogCallback callback) {
  g_log_callback.store(callback, std::memory_order_relaxed);
}

void engine_log(EclipsaStudioLogLevel level, const char* cat, const char* msg) {
  // Stage only — delivery to the Dart callback happens on the drain
  // thread (see deliver_to_callback for why calling it here, on an
  // arbitrary producer thread, aborts the process).
  ring_push(level, cat, msg, /*stderr_on_drop=*/true);
}

void engine_log_rt(EclipsaStudioLogLevel level, const char* cat,
                   const char* msg) {
  // Real-time-safe log path for the audio thread: stderr first, so the
  // message is visible even if the process dies before the next drain,
  // then the ring for the JSONL pipeline (drained by
  // eclipsa_studio_rt_log_drain()).
  write_stderr(level, cat, msg);
  ring_push(level, cat, msg, /*stderr_on_drop=*/false);
}

extern "C" void eclipsa_studio_rt_log_drain(void) {
  // Leave entries staged until a callback exists, so messages emitted
  // before the Dart side registers (early startup) are not lost.
  if (!g_log_callback.load(std::memory_order_relaxed)) return;

  uint32_t pos = g_log_ring.tail.load(std::memory_order_relaxed);
  for (;;) {
    LogEntry& cell = g_log_ring.cells[pos & kLogRingMask];
    const uint32_t seq = cell.seq.load(std::memory_order_acquire);
    if (static_cast<int32_t>(seq - (pos + 1)) != 0) break;  // ring empty
    deliver_to_callback(cell.level, cell.category, cell.message);
    // Release the slot for the producer one lap ahead.
    cell.seq.store(pos + kLogRingCapacity, std::memory_order_release);
    ++pos;
    g_log_ring.tail.store(pos, std::memory_order_relaxed);
  }

  const uint32_t dropped =
      g_log_ring.dropped.exchange(0, std::memory_order_relaxed);
  if (dropped > 0) {
    char buf[96];
    snprintf(buf, sizeof(buf), "log ring overflow: %u message(s) dropped",
             dropped);
    deliver_to_callback(ECLIPSA_STUDIO_LOG_WARN, "engine", buf);
  }
}
