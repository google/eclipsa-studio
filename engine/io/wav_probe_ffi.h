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

// C FFI: WAV header probe over the shared in-house wav library
// (engine/wav), so the Dart UI and the engine share one parser — a file
// the probe accepts is a file the engine will open, and vice versa.

#ifndef ECLIPSA_STUDIO_IO_WAV_PROBE_FFI_H_
#define ECLIPSA_STUDIO_IO_WAV_PROBE_FFI_H_

#ifdef __cplusplus
extern "C" {
#endif

// Probes `path`'s WAV header (no sample data is decoded) and returns a
// heap-allocated JSON string the caller frees with
// `eclipsa_studio_string_free`:
//
//   {"ok":true,"container":"riff|rf64|bw64","channels":2,
//    "sample_rate":48000,"bits_per_sample":24,"is_float":false,
//    "num_frames":480000,"data_offset":92,"data_size":2880000,
//    "axml_bytes":0,"chna_bytes":0}
//
// or {"ok":false,"error":"..."} when the file is rejected (the error is
// the parser's fail-closed reason). Returns NULL only if allocating the
// result string itself fails.
char* eclipsa_studio_wav_probe_json(const char* path);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ECLIPSA_STUDIO_IO_WAV_PROBE_FFI_H_
