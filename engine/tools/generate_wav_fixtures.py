#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Generate the golden WAV fixture matrix + manifest.json (issue ES-39).

Synthesizes a documented set of reference WAVs — bit depths, sample
rates, channel layouts, and deliberately malformed files — with
expected values computed exactly from the samples actually written,
so any engine build (or external harness) can verify decode behavior
independently:

    python3 engine/tools/generate_wav_fixtures.py <output-dir>

Outputs <output-dir>/manifest.json plus one .wav per entry. Manifest
schema per entry:

    name            fixture file name
    valid           false for the malformed set
    reject_reason   (malformed only) why open/import must fail
    expect          (valid only) channels, sample_rate, bits, format
                    ("pcm"|"float"), frames, peak_dbfs, rms_dbfs
    tolerance_db    allowed deviation when checking peak/RMS
    expect_frames_on_disk
                    (truncated fixture only) overrides the "open must
                    fail" rule: the file should OPEN, at this many
                    frames

peak_dbfs / rms_dbfs are per-file maxima across channels, computed
from the quantized samples (not the ideal sine), so checks against a
correct decoder can use a tight tolerance. Everything is stdlib-only
and deterministic (no dithering, fixed phases).
"""

import json
import math
import struct
import sys
from pathlib import Path

FULL = {16: 32768, 24: 8388608, 32: 2147483648}


def _fmt_chunk(fmt_tag, channels, rate, bits):
    block = channels * (bits // 8)
    return struct.pack(
        "<HHIIHH", fmt_tag, channels, rate, rate * block, block, bits
    )


def build_wav(channels_samples, rate, bits, fmt="pcm", fmt_tag=None,
              declared_data_size=None, drop_data_bytes=0):
    """Build WAV bytes from per-channel float sample lists in [-1, 1].

    Returns (bytes, expect_dict). Malformed knobs: fmt_tag overrides
    the format tag; declared_data_size lies in the data chunk header;
    drop_data_bytes truncates the payload after the header is written.
    """
    nch = len(channels_samples)
    frames = len(channels_samples[0]) if nch else 0
    is_float = fmt == "float"
    tag = fmt_tag if fmt_tag is not None else (3 if is_float else 1)

    peak_sq = 0.0
    sum_sq = 0.0
    data = bytearray()
    quantized = [[0.0] * frames for _ in range(nch)]
    for f in range(frames):
        for ch in range(nch):
            s = channels_samples[ch][f]
            if is_float:
                q = s
                data += struct.pack("<f", s)
            else:
                full = FULL[bits]
                code = min(round(s * full), full - 1)
                q = code / full
                if bits == 16:
                    data += struct.pack("<h", code)
                elif bits == 24:
                    data += struct.pack("<i", code)[:3]
                else:
                    data += struct.pack("<i", code)
            quantized[ch][f] = q
    for ch in range(nch):
        ch_sum = sum(q * q for q in quantized[ch])
        ch_peak = max((q * q for q in quantized[ch]), default=0.0)
        peak_sq = max(peak_sq, ch_peak)
        sum_sq = max(sum_sq, ch_sum)

    if drop_data_bytes:
        data = data[: len(data) - drop_data_bytes]
    declared = declared_data_size if declared_data_size is not None else len(
        data
    )

    fmt_body = _fmt_chunk(tag, nch, rate, bits)
    riff_payload = 4 + (8 + len(fmt_body)) + (8 + declared)
    blob = (
        b"RIFF" + struct.pack("<I", riff_payload) + b"WAVE"
        + b"fmt " + struct.pack("<I", len(fmt_body)) + fmt_body
        + b"data" + struct.pack("<I", declared) + bytes(data)
    )

    def dbfs(x):
        return -120.0 if x <= 0 else 20.0 * math.log10(math.sqrt(x))

    expect = {
        "channels": nch,
        "sample_rate": rate,
        "bits": bits,
        "format": fmt,
        "frames": frames,
        "peak_dbfs": round(dbfs(peak_sq), 4),
        "rms_dbfs": round(dbfs(sum_sq / frames) if frames else -120.0, 4),
    }
    return blob, expect


def sine(freq, rate, frames, amp, phase=0.0):
    w = 2.0 * math.pi * freq / rate
    return [amp * math.sin(w * i + phase) for i in range(frames)]


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    entries = []

    def emit(name, blob, expect=None, reject_reason=None,
             expect_frames_on_disk=None):
        (out / name).write_bytes(blob)
        entry = {"name": name, "valid": reject_reason is None}
        if expect is not None:
            entry["expect"] = expect
            entry["tolerance_db"] = 0.05
        if reject_reason is not None:
            entry["reject_reason"] = reject_reason
        if expect_frames_on_disk is not None:
            # Machine-checkable exception to "valid: false => open must
            # fail": this file should OPEN, at this many frames.
            entry["expect_frames_on_disk"] = expect_frames_on_disk
        entries.append(entry)

    rate = 48000
    frames = rate // 2  # 500 ms

    # ── valid: bit-depth / format sweep (997 Hz, -1 dBFS, stereo) ──
    amp = 10.0 ** (-1.0 / 20.0)
    stereo = [sine(997, rate, frames, amp), sine(997, rate, frames, amp)]
    for bits, fmt in [(16, "pcm"), (24, "pcm"), (32, "pcm"), (32, "float")]:
        suffix = "f32" if fmt == "float" else f"s{bits}"
        blob, expect = build_wav(stereo, rate, bits, fmt)
        emit(f"sine997_m1db_{suffix}_48k_stereo.wav", blob, expect)

    # ── valid: sample-rate sweep (16-bit stereo) ──
    for r in (44100, 96000):
        ch = [sine(997, r, r // 2, amp), sine(997, r, r // 2, amp)]
        blob, expect = build_wav(ch, r, 16)
        emit(f"sine997_m1db_s16_{r // 1000}k_stereo.wav", blob, expect)

    # ── valid: level sweep (16-bit stereo, -20 / -60 dBFS) ──
    for db in (-20, -60):
        a = 10.0 ** (db / 20.0)
        ch = [sine(997, rate, frames, a), sine(997, rate, frames, a)]
        blob, expect = build_wav(ch, rate, 16)
        emit(f"sine997_m{-db}db_s16_48k_stereo.wav", blob, expect)

    # ── valid: silence and impulse ──
    blob, expect = build_wav([[0.0] * frames] * 2, rate, 16)
    emit("silence_s16_48k_stereo.wav", blob, expect)
    imp = [0.0] * frames
    imp[0] = 32767 / 32768
    blob, expect = build_wav([imp], rate, 16)
    emit("impulse_s16_48k_mono.wav", blob, expect)

    # ── valid: channel-count sweep (multitone, -6 dBFS per channel) ──
    a6 = 10.0 ** (-6.0 / 20.0)
    for nch, label in [(1, "mono"), (6, "5_1"), (12, "7_1_4"), (32, "32ch")]:
        chans = [
            sine(220.0 * (1 + c % 16), rate, frames, a6) for c in range(nch)
        ]
        blob, expect = build_wav(chans, rate, 16)
        emit(f"multitone_m6db_s16_48k_{label}.wav", blob, expect)

    # ── valid: single-frame edge case ──
    blob, expect = build_wav([[0.5], [0.5]], rate, 16)
    emit("oneframe_s16_48k_stereo.wav", blob, expect)

    # ── malformed: each must be rejected (or, for the truncated one,
    #    decoded at its real length — see reject_reason text) ──
    blob, _ = build_wav(stereo, rate, 16, fmt_tag=0x55)
    emit("bad_format_tag_mp3.wav", blob,
         reject_reason="compressed format tag 0x55 (MP3)")
    blob, _ = build_wav(stereo, rate, 16, fmt_tag=0x06)
    emit("bad_format_tag_alaw.wav", blob,
         reject_reason="compressed format tag 0x06 (A-law)")
    full_bytes = frames * 4  # stereo 16-bit
    blob, _ = build_wav(stereo, rate, 16, declared_data_size=full_bytes,
                        drop_data_bytes=full_bytes // 2)
    emit("bad_truncated_data.wav", blob,
         reject_reason=(
             "data chunk declares more bytes than present — duration "
             f"must reflect the {frames - frames // 2} frames on disk"
         ),
         expect_frames_on_disk=frames - frames // 2)
    chans33 = [sine(220.0 * (1 + c % 16), rate, 256, a6) for c in range(33)]
    blob, _ = build_wav(chans33, rate, 16)
    emit("bad_channels_33.wav", blob,
         reject_reason="33 channels exceeds the engine cap of 32")
    emit("bad_not_riff.wav", b"JUNKJUNKJUNKJUNK",
         reject_reason="not a RIFF/WAVE file")
    blob, _ = build_wav(stereo, rate, 16)
    emit("bad_no_data_chunk.wav", blob[:36],
         reject_reason="fmt chunk only, data chunk missing")

    manifest = {
        "generator": "engine/tools/generate_wav_fixtures.py",
        "fixture_count": len(entries),
        "entries": entries,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {len(entries)} fixtures + manifest.json to {out}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: generate_wav_fixtures.py <output-dir>")
    main(sys.argv[1])
