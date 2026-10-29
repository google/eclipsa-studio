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

#ifndef ECLIPSA_STUDIO_TEST_ALLOC_COUNTER_H_
#define ECLIPSA_STUDIO_TEST_ALLOC_COUNTER_H_

/// Counts the heap allocations one thread makes, for tests that check a
/// real-time path does not allocate. It counts through the sanitizer
/// malloc hooks, so it works in the asan and tsan builds only; elsewhere
/// kAvailable is false and tests skip. tsan on macOS does not call the
/// hooks for posix_memalign() and aligned_alloc(); asan counts them.

#include <atomic>
#include <cstdint>
#include <cstdlib>

#if defined(ADDRESS_SANITIZER) || defined(THREAD_SANITIZER)
#include <pthread.h>
#include <sanitizer/allocator_interface.h>
#define ECLIPSA_STUDIO_ALLOC_COUNTER_HOOKS 1
#endif

namespace alloc_counter {

#if defined(ECLIPSA_STUDIO_ALLOC_COUNTER_HOOKS)
inline constexpr bool kAvailable = true;

namespace internal {

inline std::atomic<bool> g_counting{false};
inline std::atomic<uint64_t> g_allocations{0};
inline std::atomic<pthread_t> g_thread{};

inline void OnMalloc(const volatile void*, size_t) {
  if (g_counting.load(std::memory_order_acquire) &&
      pthread_equal(pthread_self(), g_thread.load(std::memory_order_relaxed))) {
    g_allocations.fetch_add(1, std::memory_order_relaxed);
  }
}

inline void OnFree(const volatile void*) {}

inline bool InstallHooks() {
  static const bool installed =
      __sanitizer_install_malloc_and_free_hooks(OnMalloc, OnFree) != 0;
  return installed;
}

}  // namespace internal

/// Starts counting the calling thread's allocations. It first makes one
/// allocation of its own and returns whether the hook counted it, so a
/// hook that installs but is not called fails the caller's check.
inline bool Start() {
  if (!internal::InstallHooks()) return false;
  internal::g_thread.store(pthread_self(), std::memory_order_relaxed);
  internal::g_allocations.store(0, std::memory_order_relaxed);
  internal::g_counting.store(true, std::memory_order_release);
  void* volatile probe = std::malloc(16);
  std::free(probe);
  return internal::g_allocations.exchange(0, std::memory_order_relaxed) == 1;
}

/// Stops counting and returns the allocations counted since Start().
inline uint64_t Stop() {
  internal::g_counting.store(false, std::memory_order_release);
  return internal::g_allocations.load(std::memory_order_relaxed);
}

#else
inline constexpr bool kAvailable = false;
inline bool Start() { return false; }
inline uint64_t Stop() { return 0; }
#endif

}  // namespace alloc_counter

#endif  // ECLIPSA_STUDIO_TEST_ALLOC_COUNTER_H_
