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

#ifndef ECLIPSA_STUDIO_GRAPH_AUDIO_NODE_H_
#define ECLIPSA_STUDIO_GRAPH_AUDIO_NODE_H_

#include "audio_buffer.h"

/// Abstract base class for all pull-based audio processing nodes.
///
/// Nodes form a directed acyclic graph; the leaf nodes (e.g. WavReader)
/// produce audio and interior nodes transform it.  The root (mix bus /
/// device output) drives the graph by calling process() on its inputs.
///
/// Real-time safety: implementations MUST NOT allocate heap memory inside
/// process().  All buffers must be pre-allocated in init/constructor.
class AudioNode {
 public:
  virtual ~AudioNode() = default;

  /// Fill `output` with exactly `frames` frames of processed audio.
  ///
  /// @param output  Pre-allocated buffer (channels and capacity already set
  ///                by the graph).  Set output.frames = frames on return.
  /// @param frames  Number of frames requested by the downstream caller.
  virtual void process(AudioBuffer& output, uint32_t frames) = 0;

  /// Reset internal state (e.g. on transport seek).
  /// Called from the control thread — NOT the audio thread.
  virtual void reset() {}
};

#endif  // ECLIPSA_STUDIO_GRAPH_AUDIO_NODE_H_
