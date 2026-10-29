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

#ifndef ECLIPSA_STUDIO_IAMF_IAMF_MUXER_H_
#define ECLIPSA_STUDIO_IAMF_IAMF_MUXER_H_

#include <cstdint>
#include <string>

namespace eclipsa_studio {

// Muxes an IAMF bitstream together with a video file into a single MP4
// (IAMF-in-ISOBMFF), in-process via libgpac. MuxAudioOnly() writes an MP4
// with the IAMF track and no video.
//
// The IAMF bytes are the exact ones the engine's IamfExporter produced, so
// the profile, substream layout, and measured loudness are carried through
// unchanged. The video track is stream-copied (no re-encode).
//
// The source video must be an ISOBMFF container (.mp4/.mov): the video
// track is copied with GPAC's ISO-media API, which does not demux
// Matroska/WebM/MXF. Callers gate on the source format upstream.
//
// Mirrors google/eclipsa-audio-plugin's IAMFExportHelper::muxIAMF():
//   1. a GPAC filter session writes the IAMF audio into a fresh MP4;
//   2. the source video track is cloned and its samples copied into that
//      same MP4, with the container duration clamped to the video.
//
// Control-thread only (heap-allocating, synchronous). Never call from the
// audio thread.
class IamfMuxer {
 public:
  IamfMuxer() = default;
  ~IamfMuxer() = default;

  IamfMuxer(const IamfMuxer&) = delete;
  IamfMuxer& operator=(const IamfMuxer&) = delete;

  // Mux `input_iamf` + `input_video` into `output_mp4` (overwritten if it
  // exists).
  //
  // Returns 0 on success, negative on error:
  //   -1   empty argument
  //   -2   input .iamf missing / unreadable
  //   -3   input video missing / unreadable
  //   -10  GPAC system init failed
  //   -11  audio mux (filter session) failed
  //   -12  video mux (ISO-media copy) failed
  int32_t Mux(const std::string& input_iamf, const std::string& input_video,
              const std::string& output_mp4);

  // Mux `input_iamf` into `output_mp4` (overwritten if it exists) with no
  // video track: step 1 of Mux() alone.
  //
  // Returns 0 on success, or the Mux() codes -1 (empty argument), -2
  // (input .iamf missing / unreadable), -10 (GPAC system init failed) and
  // -11 (audio mux failed). A failed mux (-11) removes `output_mp4`; the
  // other codes return before `output_mp4` is touched.
  int32_t MuxAudioOnly(const std::string& input_iamf,
                       const std::string& output_mp4);

  // Check that `input_video` opens with the GPAC ISO-media reader Mux()
  // uses and has a visual track. Reads only the file's metadata, so it is
  // quick even on a multi-gigabyte file. Callers run it before an export
  // so a container GPAC rejects is reported before the encode instead of
  // after it (ES-742); the track clone and sample copy in Mux() can still
  // fail on a file that passes here.
  //
  // Returns 0 when the container opens and has a visual track:
  //   -1   empty argument
  //   -3   input video missing / unreadable
  //   -10  GPAC system init failed
  //   -12  GPAC cannot open the container
  //   -13  the container has no visual track
  int32_t ProbeVideo(const std::string& input_video);
};

}  // namespace eclipsa_studio

#endif  // ECLIPSA_STUDIO_IAMF_IAMF_MUXER_H_
