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

// Times the live OAR path and counts its heap allocations per block:
//   oar_render_bench [--frames N] [--rate HZ] [--blocks N] [--trace N]
//                    [--only TEXT] [--contend]
// Each block runs the calls AudioGraph::process makes on the audio thread:
// for every element a mix-gain push, a position push for an object element
// and the PCM feed, then the output mix-gain push, render() and
// snapshot_limiter_env(). One row per output layout and element set;
// --only runs the rows whose "output / elements" name contains TEXT.
// --contend runs a second thread that allocates and frees blocks of 16 bytes
// to 64 KiB while the blocks are timed, as other threads of the app do.
//
// The allocation count needs the sanitizer malloc hooks, so it is reported
// only in an --config=asan or --config=tsan build. It counts the bench
// thread's allocations in the measured blocks, after 64 warm-up blocks;
// --trace N prints the stack of the first N of them. tsan on macOS does not
// call the hooks for posix_memalign() and aligned_alloc(); asan does. Time
// a -c opt build: sanitizer timings are not representative.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "renderer/oar_renderer.h"

extern "C" {
#include "oar.h"
}

#if defined(ADDRESS_SANITIZER) || defined(THREAD_SANITIZER)
#include <pthread.h>
#include <sanitizer/allocator_interface.h>
#include <sanitizer/common_interface_defs.h>
#define ECLIPSA_STUDIO_BENCH_COUNTS_ALLOCATIONS 1
#endif

namespace {

using Clock = std::chrono::steady_clock;

std::atomic<bool> g_counting{false};
std::atomic<uint64_t> g_allocations{0};
std::atomic<int> g_trace_left{0};

#if defined(ECLIPSA_STUDIO_BENCH_COUNTS_ALLOCATIONS)
// The thread whose allocations are counted.
pthread_t g_bench_thread;
// Set while a stack is printed, so the printing's own allocations are not
// counted. A plain flag rather than thread_local: on macOS the first touch
// of a thread_local allocates, which would re-enter the hook.
std::atomic<bool> g_in_hook{false};

void OnMalloc(const volatile void*, size_t size) {
  if (!g_counting.load(std::memory_order_relaxed) ||
      !pthread_equal(pthread_self(), g_bench_thread) ||
      g_in_hook.load(std::memory_order_relaxed)) {
    return;
  }
  g_allocations.fetch_add(1, std::memory_order_relaxed);
  if (g_trace_left.load(std::memory_order_relaxed) > 0) {
    g_in_hook.store(true, std::memory_order_relaxed);
    g_trace_left.fetch_sub(1, std::memory_order_relaxed);
    std::fprintf(stderr, "allocation of %zu bytes:\n", size);
    __sanitizer_print_stack_trace();
    g_in_hook.store(false, std::memory_order_relaxed);
  }
}

void OnFree(const volatile void*) {}
#endif

// Allocates and frees blocks of 16 bytes to 64 KiB until *stop is set,
// keeping up to 64 of them live and writing to each.
void Contend(const std::atomic<bool>* stop) {
  std::vector<void*> live(64, nullptr);
  uint32_t s = 12345u;
  size_t i = 0;
  while (!stop->load(std::memory_order_relaxed)) {
    s = s * 1664525u + 1013904223u;
    std::free(live[i]);
    live[i] = std::malloc(size_t{16} << ((s >> 8) % 13));
    if (live[i] != nullptr) static_cast<volatile char*>(live[i])[0] = 1;
    i = (i + 1) % live.size();
  }
  for (void* p : live) std::free(p);
}

struct Element {
  uint32_t id;
  int type;      // 0 channel-based, 1 scene-based, 2 object-based.
  int sub_type;  // oar_layout_t, oar_hoa_t or the object count.
  uint32_t channels;
};

struct ElementSet {
  const char* name;
  std::vector<Element> elements;
};

struct Layout {
  const char* name;
  uint32_t layout;
};

std::vector<ElementSet> ElementSets() {
  std::vector<ElementSet> sets;
  sets.push_back({"7.1.4 bed", {{1, 0, ck_oar_layout_714, 12}}});
  sets.push_back({"3OA scene", {{1, 1, ck_oar_3oa, 16}}});
  {
    ElementSet objects{"8 objects", {}};
    for (uint32_t i = 0; i < 8; ++i)
      objects.elements.push_back({i + 1, 2, 1, 1});
    sets.push_back(objects);
  }
  sets.push_back({"bed+3OA+2 obj",
                  {{1, 0, ck_oar_layout_714, 12},
                   {2, 1, ck_oar_3oa, 16},
                   {3, 2, 1, 1},
                   {4, 2, 1, 1}}});
  return sets;
}

// Deterministic noise at about -20 dBFS, so every renderer has signal.
void FillNoise(std::vector<float>* buf, uint32_t seed) {
  uint32_t s = seed * 2654435761u + 1u;
  for (float& v : *buf) {
    s = s * 1664525u + 1013904223u;
    v = (static_cast<float>(s >> 8) / 16777216.0f - 0.5f) * 0.2f;
  }
}

struct Result {
  bool ok = false;
  double allocations_per_block = 0.0;
  double mean_us = 0.0;
  double p50_us = 0.0;
  double p99_us = 0.0;
  double max_us = 0.0;
  uint32_t out_channels = 0;
  // FNV-1a over the bytes of the warm-up blocks' output, to compare the
  // output of two builds.
  uint32_t digest = 2166136261u;
};

// An OarRenderer for one row and the calls of one block on it.
class BlockDriver {
 public:
  BlockDriver(const ElementSet& set, uint32_t frames)
      : set_(set), frames_(frames), pcm_(set.elements.size()) {
    for (size_t i = 0; i < pcm_.size(); ++i) {
      pcm_[i].resize(static_cast<size_t>(set.elements[i].channels) * frames);
      FillNoise(&pcm_[i], static_cast<uint32_t>(i) + 1);
    }
  }

  bool Init(uint32_t layout, uint32_t rate) {
    oar_.set_no_audio_thread();
    if (!oar_.init(rate, frames_, layout)) return false;
    for (const Element& e : set_.elements) {
      if (!oar_.add_element(e.id, e.type, e.sub_type, e.channels)) {
        return false;
      }
    }
    return true;
  }

  uint32_t channel_count() const { return oar_.channel_count(); }

  // Runs one block and returns the rendered output, or null.
  const float* Block() {
    for (size_t i = 0; i < set_.elements.size(); ++i) {
      const Element& e = set_.elements[i];
      oar_.set_element_mix_gain(e.id, -1.0f, -1.0f, frames_);
      if (e.type == 2) {
        // A slow pan, so the positions change from block to block.
        const float az[2] = {std::fmod(azimuth_ + 45.0f * i, 360.0f) - 180.0f,
                             0.0f};
        const float el[2] = {10.0f, 0.0f};
        const float dist[2] = {1.0f, 1.0f};
        oar_.set_element_object_positions(e.id, 1, az, el, dist, frames_);
      }
      oar_.update_element_data(e.id, pcm_[i].data(), e.channels, frames_,
                               frames_);
    }
    oar_.set_output_mix_gain(0.0f, 0.0f, frames_);
    const float* out = oar_.render(frames_);
    oar_.snapshot_limiter_env();
    azimuth_ += 0.5f;
    return out;
  }

 private:
  const ElementSet& set_;
  const uint32_t frames_;
  std::vector<std::vector<float>> pcm_;
  float azimuth_ = 0.0f;
  OarRenderer oar_;
};

// Fills the mean, percentiles and maximum of `us` into `r`.
void Summarize(std::vector<double> us, Result* r) {
  const size_t n = us.size();
  double sum = 0.0;
  for (double v : us) sum += v;
  r->mean_us = sum / n;
  std::sort(us.begin(), us.end());
  r->p50_us = us[n / 2];
  r->p99_us = us[std::min(n - 1, (n * 99) / 100)];
  r->max_us = us.back();
}

Result Run(const Layout& layout, const ElementSet& set, uint32_t frames,
           uint32_t rate, uint32_t blocks, int trace, bool contend) {
  Result r;
  BlockDriver driver(set, frames);
  if (!driver.Init(layout.layout, rate)) return r;
  r.out_channels = driver.channel_count();

  // Warm-up: 64 blocks before the measured ones. Their output goes into
  // the digest; their allocations and times are not counted.
  for (int i = 0; i < 64; ++i) {
    const float* out = driver.Block();
    if (out == nullptr) return r;
    const auto* bytes = reinterpret_cast<const unsigned char*>(out);
    const size_t n = sizeof(float) * r.out_channels * frames;
    for (size_t k = 0; k < n; ++k) {
      r.digest = (r.digest ^ bytes[k]) * 16777619u;
    }
  }

  std::vector<double> us(blocks);
  if (trace > 0) {
    std::fprintf(stderr, "=== %s / %s\n", layout.name, set.name);
  }
  std::atomic<bool> stop{false};
  std::thread contender;
  if (contend) contender = std::thread(Contend, &stop);
  g_allocations.store(0, std::memory_order_relaxed);
  g_trace_left.store(trace, std::memory_order_relaxed);
  g_counting.store(true, std::memory_order_relaxed);
  for (uint32_t i = 0; i < blocks; ++i) {
    const auto t0 = Clock::now();
    driver.Block();
    us[i] =
        std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
  }
  g_counting.store(false, std::memory_order_relaxed);
  g_trace_left.store(0, std::memory_order_relaxed);
  stop.store(true, std::memory_order_relaxed);
  if (contender.joinable()) contender.join();

  r.allocations_per_block =
      static_cast<double>(g_allocations.load(std::memory_order_relaxed)) /
      blocks;
  Summarize(std::move(us), &r);
  r.ok = true;
  return r;
}

uint32_t ParseUint(const char* s, const char* flag) {
  char* end = nullptr;
  const unsigned long v = std::strtoul(s, &end, 10);
  if (end == s || *end != '\0' || v == 0 || v > 1000000) {
    std::fprintf(stderr, "%s: expected a positive integer, got '%s'\n", flag,
                 s);
    std::exit(2);
  }
  return static_cast<uint32_t>(v);
}

}  // namespace

int main(int argc, char** argv) {
  uint32_t frames = 512;
  uint32_t rate = 48000;
  uint32_t blocks = 2000;
  int trace = 0;
  const char* only = nullptr;
  bool contend = false;
  for (int i = 1; i < argc; ++i) {
    const bool has_value = i + 1 < argc;
    if (std::strcmp(argv[i], "--frames") == 0 && has_value) {
      frames = ParseUint(argv[++i], "--frames");
    } else if (std::strcmp(argv[i], "--rate") == 0 && has_value) {
      rate = ParseUint(argv[++i], "--rate");
    } else if (std::strcmp(argv[i], "--blocks") == 0 && has_value) {
      blocks = ParseUint(argv[++i], "--blocks");
    } else if (std::strcmp(argv[i], "--contend") == 0) {
      contend = true;
    } else if (std::strcmp(argv[i], "--only") == 0 && has_value) {
      only = argv[++i];
    } else if (std::strcmp(argv[i], "--trace") == 0 && has_value) {
      trace = static_cast<int>(ParseUint(argv[++i], "--trace"));
    } else {
      std::fprintf(stderr,
                   "usage: %s [--frames N] [--rate HZ] [--blocks N] "
                   "[--trace N] [--only TEXT] [--contend]\n",
                   argv[0]);
      return 2;
    }
  }

#if defined(ECLIPSA_STUDIO_BENCH_COUNTS_ALLOCATIONS)
  g_bench_thread = pthread_self();
  bool counts =
      __sanitizer_install_malloc_and_free_hooks(OnMalloc, OnFree) != 0;
  if (counts) {
    // One allocation of the bench's own: a hook that installs but is not
    // called would report 0 allocations per block in every row.
    g_counting.store(true, std::memory_order_relaxed);
    void* volatile probe = std::malloc(16);
    std::free(probe);
    g_counting.store(false, std::memory_order_relaxed);
    counts = g_allocations.exchange(0, std::memory_order_relaxed) == 1;
  }
  if (!counts && trace > 0) {
    std::fprintf(stderr, "--trace: the malloc hooks do not count\n");
    return 2;
  }
#else
  const bool counts = false;
  if (trace > 0) {
    std::fprintf(stderr, "--trace needs an asan or tsan build\n");
    return 2;
  }
#endif

  const double budget_us = 1e6 * frames / rate;
  std::printf("%u frames at %u Hz (%.0f us per block), %u blocks%s\n", frames,
              rate, budget_us, blocks,
              contend ? ", with a contending allocator thread" : "");
  std::printf("%-9s %-14s %4s %12s %9s %9s %9s %9s %7s %8s\n", "output",
              "elements", "ch", "allocs/block", "mean us", "p50 us", "p99 us",
              "max us", "load %", "digest");

  const Layout layouts[] = {{"stereo", ck_oar_layout_stereo},
                            {"7.1.4", ck_oar_layout_714},
                            {"binaural", ck_oar_layout_binaural}};
  int failures = 0;
  for (const Layout& layout : layouts) {
    for (const ElementSet& set : ElementSets()) {
      const std::string name = std::string(layout.name) + " / " + set.name;
      if (only != nullptr && name.find(only) == std::string::npos) continue;
      const Result r = Run(layout, set, frames, rate, blocks, trace, contend);
      if (!r.ok) {
        std::printf("%-9s %-14s setup failed\n", layout.name, set.name);
        ++failures;
        continue;
      }
      char allocs[16];
      if (counts) {
        std::snprintf(allocs, sizeof(allocs), "%.2f", r.allocations_per_block);
      } else {
        std::snprintf(allocs, sizeof(allocs), "n/a");
      }
      std::printf("%-9s %-14s %4u %12s %9.1f %9.1f %9.1f %9.1f %7.1f %08x\n",
                  layout.name, set.name, r.out_channels, allocs, r.mean_us,
                  r.p50_us, r.p99_us, r.max_us, 100.0 * r.mean_us / budget_us,
                  r.digest);
      std::fflush(stdout);
    }
  }
  return failures == 0 ? 0 : 1;
}
