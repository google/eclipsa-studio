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
//
// Pins the audio-thread read path's claim: after ReserveReadScratch(),
// ReadPlanarFloatInto() allocates nothing, on sequential reads, on the
// clipped tail read and on a seek back. The global allocation functions
// are replaced in this translation unit alone, so the counter sees every
// operator new in the process while a test has it switched on.

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <new>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "wav/reader.h"
#include "wav/testing/fixture.h"
#include "wav/types.h"

namespace {

std::atomic<bool> g_counting{false};
std::atomic<uint64_t> g_allocations{0};

void* CountedAlloc(std::size_t n) {
  if (g_counting.load(std::memory_order_relaxed)) {
    g_allocations.fetch_add(1, std::memory_order_relaxed);
  }
  void* p = std::malloc(n == 0 ? 1 : n);
  if (p == nullptr) throw std::bad_alloc();
  return p;
}

}  // namespace

void* operator new(std::size_t n) { return CountedAlloc(n); }
void* operator new[](std::size_t n) { return CountedAlloc(n); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

namespace wav {
namespace {

namespace wt = wav::testing;

// Runs `fn` with the allocation counter on and returns the count.
template <typename Fn>
uint64_t CountAllocations(Fn&& fn) {
  g_allocations.store(0, std::memory_order_relaxed);
  g_counting.store(true, std::memory_order_relaxed);
  fn();
  g_counting.store(false, std::memory_order_relaxed);
  return g_allocations.load(std::memory_order_relaxed);
}

TEST(ReaderRtAlloc, CounterSeesAnAllocation) {
  // The replacement is in effect: a heap allocation is counted.
  EXPECT_GE(CountAllocations([] { std::vector<int> v(64, 1); }), 1u);
}

TEST(ReaderRtAlloc, ReservedReadPathAllocatesNothing) {
  wt::FixtureSpec spec;
  spec.format = SampleFormat::kInt24;
  spec.channels = 2;
  spec.num_frames = 4800;
  const std::string path = wt::WriteFixture("rt_alloc", spec);
  auto r = Reader::Open(path);
  ASSERT_TRUE(r.ok()) << r.error();

  constexpr uint64_t kBlock = 512;
  r->ReserveReadScratch(kBlock);
  float ch0[kBlock], ch1[kBlock];
  float* dsts[2] = {ch0, ch1};

  uint64_t total = 0;
  bool ok = true;
  const uint64_t allocations = CountAllocations([&] {
    // Sequential blocks to the end, including the clipped tail.
    for (uint64_t start = 0; start < spec.num_frames; start += kBlock) {
      auto n = r->ReadPlanarFloatInto(start, kBlock, dsts);
      ok = ok && n.ok();
      total += n.ok() ? *n : 0;
    }
    // A seek back to the start, then one more sequential block.
    auto n = r->ReadPlanarFloatInto(0, kBlock, dsts);
    ok = ok && n.ok();
    n = r->ReadPlanarFloatInto(kBlock, kBlock, dsts);
    ok = ok && n.ok();
  });
  ASSERT_TRUE(ok);
  EXPECT_EQ(total, spec.num_frames);
  EXPECT_EQ(allocations, 0u);

  // The reads decoded the right samples: the last block read frames
  // [512, 1024) of the ramp.
  for (uint32_t i = 0; i < kBlock; ++i) {
    ASSERT_EQ(ch1[i], wt::ExpectedFloat(spec.format, kBlock + i, 1))
        << "frame " << (kBlock + i);
  }
}

}  // namespace
}  // namespace wav
