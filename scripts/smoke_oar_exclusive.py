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

"""Smoke test for the OAR offline-exclusive contract (ES-158, ES-44).

Drives the real engine dylib over ctypes against the real output
device — the same FFI surface the app uses (engine.h documents this
external-harness use). Automates the engine-level core of the manual
QA items on the live-renderer hardening PR:

  1. play a test tone and confirm signal on the output bus;
  2. setExportPaused(1): output must fall silent (audio thread skips
     OAR while the offline-exclusive mode is held);
  3. eclipsa_studio_engine_reconfigure() with a new buffer size WHILE paused —
     the historical escape path that resumed the live OAR mid-export —
     and confirm the output STAYS silent;
  4. setExportPaused(0): signal must return;
  5. a second pause/resume cycle (back-to-back offline passes);
  6. overlapping holds (the refcount contract): a nested
     pause/release pair — the export dialog opened via the native
     menu while the Loudness Report measures, then closed first —
     must leave the output silent, through a device reconfigure,
     until the LAST release.

What this cannot check: audible click-freeness of the fades and the
app-side dialog behaviour — those remain the manual half of the QA.

Plays a quiet 440 Hz tone on the default output device while running
(~10 s total). Run from the repo root after `./build.sh engine`:

  python3 scripts/smoke_oar_exclusive.py

Exit codes: 0 = pass, 1 = fail, 3 = skipped (no running output device,
e.g. headless CI — the test needs a live audio thread to be meaningful).
"""

import ctypes
import math
import struct
import sys
import tempfile
import time
import wave
from pathlib import Path

SAMPLE_RATE = 48000
INIT_BUFFER = 512
RECONFIG_BUFFER = 1024  # flipped while paused — the escape path
TONE_SECONDS = 60  # long enough to outlive the whole test
TONE_AMPLITUDE = 0.1  # ~ -20 dBFS, quiet but unambiguous
SIGNAL_THRESHOLD = 0.005  # peak above this = audible signal
SILENCE_THRESHOLD = 0.0005  # peak below this = silent
MAX_CHANNELS = 32


def load_engine() -> ctypes.CDLL:
    # Prefer the app bundle's copy: its Frameworks/ directory carries the
    # @rpath dependencies (gpac, ffmpeg), so it dlopens standalone. The
    # bare engine/build copy resolves those only against Bazel's _solib
    # tree, which is not on this process's search path.
    repo = Path(__file__).resolve().parent.parent
    candidates = [
        *sorted(
            repo.glob(
                "app/build/macos/Build/Products/*/"
                "*.app/Contents/Frameworks/libeclipsa_studio_engine.dylib"
            )
        ),
        repo / "engine/build/libeclipsa_studio_engine.dylib",
    ]
    dylib = next((c for c in candidates if c.exists()), None)
    if dylib is None:
        sys.exit("engine dylib not found — run ./build.sh run once first")
    # A `./build.sh engine` refreshes engine/build but not the app
    # bundle copy this harness prefers — testing a stale dylib produces
    # confusing failures (been there). Refuse rather than warn.
    bare = repo / "engine/build/libeclipsa_studio_engine.dylib"
    if bare.exists() and dylib != bare:
        if bare.stat().st_mtime > dylib.stat().st_mtime + 1:
            sys.exit(
                f"stale bundle dylib: {dylib}\n"
                f"is older than {bare}\n"
                f"copy the fresh build in first:  cp {bare} {dylib}"
            )
    # The engine's @rpath dependencies (gpac, ffmpeg) point into Bazel's
    # _solib tree, which doesn't exist outside the build sandbox. In the
    # app they resolve because the images are already loaded; do the
    # same here — preload every sibling dylib so dyld reuses them by
    # install name when the engine loads.
    deps = [d for d in sorted(dylib.parent.glob("*.dylib")) if d != dylib]
    for _ in range(len(deps)):  # fixpoint: deps depend on each other
        remaining = []
        for dep in deps:
            try:
                ctypes.CDLL(str(dep), mode=ctypes.RTLD_GLOBAL)
            except OSError:
                remaining.append(dep)
        if not remaining:
            break
        deps = remaining
    lib = ctypes.CDLL(str(dylib))
    lib.eclipsa_studio_engine_init.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    lib.eclipsa_studio_engine_init.restype = ctypes.c_int32
    lib.eclipsa_studio_element_add.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
    lib.eclipsa_studio_element_add.restype = ctypes.c_int32
    lib.eclipsa_studio_element_set_type.argtypes = [
        ctypes.c_uint32,
        ctypes.c_int32,
        ctypes.c_int32,
        ctypes.c_uint32,
    ]
    lib.eclipsa_studio_element_set_type.restype = ctypes.c_int32
    lib.eclipsa_studio_engine_set_export_paused.argtypes = [ctypes.c_uint8]
    lib.eclipsa_studio_engine_set_export_paused.restype = None
    lib.eclipsa_studio_engine_reconfigure.argtypes = [
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_uint32,
    ]
    lib.eclipsa_studio_engine_reconfigure.restype = ctypes.c_int32
    lib.eclipsa_studio_current_device_index.restype = ctypes.c_uint32
    lib.eclipsa_studio_transport_is_audio_thread_running.restype = ctypes.c_uint8
    lib.eclipsa_studio_get_output_peaks.argtypes = [
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_uint32,
    ]
    lib.eclipsa_studio_get_output_peaks.restype = ctypes.c_uint32
    return lib


def write_tone_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        frames = bytearray()
        for i in range(TONE_SECONDS * SAMPLE_RATE):
            s = int(
                TONE_AMPLITUDE
                * 32767
                * math.sin(2 * math.pi * 440 * i / SAMPLE_RATE)
            )
            frames += struct.pack("<hh", s, s)
        w.writeframes(bytes(frames))


def max_output_peak(lib: ctypes.CDLL) -> float:
    peaks = (ctypes.c_float * MAX_CHANNELS)()
    n = lib.eclipsa_studio_get_output_peaks(peaks, MAX_CHANNELS)
    return max(peaks[:n], default=0.0)


def wait_for(lib, predicate, timeout_s: float) -> bool:
    """Polls the output peak until predicate(peak) holds, or times out."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate(max_output_peak(lib)):
            return True
        time.sleep(0.02)
    return False


def hold_silent(lib, duration_s: float) -> float:
    """Monitors the output for duration_s; returns the loudest peak seen."""
    loudest = 0.0
    deadline = time.monotonic() + duration_s
    while time.monotonic() < deadline:
        loudest = max(loudest, max_output_peak(lib))
        time.sleep(0.02)
    return loudest


def main() -> int:
    lib = load_engine()
    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        tag = "PASS" if ok else "FAIL"
        print(f"  [{tag}] {name}" + (f" — {detail}" if detail else ""))
        if not ok:
            failures.append(name)

    print("smoke_oar_exclusive: offline-exclusive contract vs live device")
    if lib.eclipsa_studio_engine_init(SAMPLE_RATE, INIT_BUFFER) != 0:
        print("engine init failed")
        return 1
    try:
        if not lib.eclipsa_studio_transport_is_audio_thread_running():
            print("SKIP: no running output device (headless?)")
            return 3

        with tempfile.TemporaryDirectory() as tmp:
            tone = Path(tmp) / "tone.wav"
            write_tone_wav(tone)
            if lib.eclipsa_studio_element_add(str(tone).encode(), 1) != 0:
                print("element add failed")
                return 1
            # Register with OAR (channel-based stereo bed) — without the
            # type registration the element renders silence, exactly as
            # the app's session load does after addElement.
            if lib.eclipsa_studio_element_set_type(1, 0, 2, 2) != 0:
                print("element set_type failed")
                return 1
            lib.eclipsa_studio_transport_play()

            check(
                "signal on output bus after play",
                wait_for(lib, lambda p: p > SIGNAL_THRESHOLD, 3.0),
            )

            # ── Cycle 1: pause → reconfigure (the escape path) → resume ──
            lib.eclipsa_studio_engine_set_export_paused(1)
            check(
                "silent after setExportPaused(1)",
                wait_for(lib, lambda p: p < SILENCE_THRESHOLD, 2.0),
            )

            dev = lib.eclipsa_studio_current_device_index()
            rc = lib.eclipsa_studio_engine_reconfigure(dev, 0, RECONFIG_BUFFER)
            check("reconfigure while paused returns 0", rc == 0, f"rc={rc}")

            # The ES-158 assertion: the device restart must NOT resume the
            # live OAR while the export pause is held.
            loudest = hold_silent(lib, 1.5)
            check(
                "STILL silent after reconfigure-during-pause",
                loudest < SILENCE_THRESHOLD,
                f"loudest peak {loudest:.6f}",
            )

            lib.eclipsa_studio_engine_set_export_paused(0)
            check(
                "signal returns after setExportPaused(0)",
                wait_for(lib, lambda p: p > SIGNAL_THRESHOLD, 3.0),
            )

            # ── Cycle 2: back-to-back pause/resume (export → report) ──
            lib.eclipsa_studio_engine_set_export_paused(1)
            check(
                "second pause goes silent",
                wait_for(lib, lambda p: p < SILENCE_THRESHOLD, 2.0),
            )
            lib.eclipsa_studio_engine_set_export_paused(0)
            check(
                "second resume restores signal",
                wait_for(lib, lambda p: p > SIGNAL_THRESHOLD, 3.0),
            )

            # ── Cycle 3: overlapping passes (the refcount contract) ──
            # The macOS repro: the Loudness Report is measuring, Cmd-E
            # opens the export dialog (native menu bar — the modal
            # barrier does not block it), then the export dialog closes
            # first. Its resume must NOT bring the live OAR back while
            # the report's offline renderers are still running.
            lib.eclipsa_studio_engine_set_export_paused(1)  # report begins
            check(
                "overlap: first hold goes silent",
                wait_for(lib, lambda p: p < SILENCE_THRESHOLD, 2.0),
            )
            lib.eclipsa_studio_engine_set_export_paused(1)  # export nests
            lib.eclipsa_studio_engine_set_export_paused(0)  # export closes
            loudest = hold_silent(lib, 1.5)
            check(
                "overlap: STILL silent after nested release",
                loudest < SILENCE_THRESHOLD,
                f"loudest peak {loudest:.6f}",
            )
            # A device change mid-overlap must not resume it either.
            rc = lib.eclipsa_studio_engine_reconfigure(dev, 0, INIT_BUFFER)
            check(
                "overlap: reconfigure during hold returns 0",
                rc == 0,
                f"rc={rc}",
            )
            loudest = hold_silent(lib, 1.5)
            check(
                "overlap: STILL silent after reconfigure",
                loudest < SILENCE_THRESHOLD,
                f"loudest peak {loudest:.6f}",
            )
            lib.eclipsa_studio_engine_set_export_paused(0)  # report finishes
            check(
                "overlap: last release restores signal",
                wait_for(lib, lambda p: p > SIGNAL_THRESHOLD, 3.0),
            )
    finally:
        lib.eclipsa_studio_engine_shutdown()

    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
