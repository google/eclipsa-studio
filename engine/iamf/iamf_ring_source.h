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

#ifndef ECLIPSA_STUDIO_IAMF_IAMF_RING_SOURCE_H_
#define ECLIPSA_STUDIO_IAMF_IAMF_RING_SOURCE_H_

#include <cstdint>

#include "graph/audio_buffer.h"
#include "iamf/iamf_playback_session.h"

class PcmRing;

/// Per-element-chain source that reads one Audio Element's decoded
/// PCM out of a shared `IamfPlaybackSession`.
///
/// Mirrors the read/seek surface of `WavReader` so the graph's
/// `ElementChain` can hold either type behind a common contract. The
/// session owns the decoder; the ring source is a thin view that knows
/// its AE index and tracks its own cursor.
///
/// Seek goes through the session and therefore moves every attached
/// ring source together — consistent with how a single stream's AEs
/// share a timeline.
class IamfRingSource {
 public:
  IamfRingSource() = default;
  ~IamfRingSource() = default;

  IamfRingSource(const IamfRingSource&) = delete;
  IamfRingSource& operator=(const IamfRingSource&) = delete;

  /// Bind this source to a session + AE index. Safe to re-attach (the
  /// previous binding is dropped). Returns false if the session isn't
  /// open or the index is out of range / unsupported.
  bool attach(IamfPlaybackSession* session, uint32_t ae_index);

  /// Clear the binding. Does not close the session.
  void detach();

  bool is_attached() const { return session_ != nullptr; }

  uint32_t channels() const { return channels_; }
  uint32_t sample_rate() const;
  uint64_t total_frames() const;
  uint64_t cursor() const { return cursor_; }
  uint32_t ae_index() const { return ae_index_; }

  /// Read up to `frames` frames from this AE's buffer (planar).
  /// Returns frames produced; stops at EOF or error.
  uint32_t read(AudioBuffer& out, uint32_t frames);

  /// True once the producer has marked this AE's ring end-of-stream.
  /// Lets callers tell an expected drain-to-EOF short read apart from
  /// a starvation underrun (decode pump fell behind).
  bool eof() const;

  /// Seek the underlying session to `frame_pos`. Because all AEs
  /// share the timeline, this repositions every sibling ring source
  /// too. Returns false on upstream error.
  bool seek(uint64_t frame_pos);

 private:
  IamfPlaybackSession* session_ = nullptr;
  // Cached pointer to this AE's lock-free PCM ring inside the
  // session. The session retains ownership; we just read from it.
  PcmRing* ring_ = nullptr;
  uint32_t ae_index_ = 0;
  uint32_t channels_ = 0;
  uint64_t cursor_ = 0;
};

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_RING_SOURCE_H_
