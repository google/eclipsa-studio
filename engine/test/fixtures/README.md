# IAMF test fixtures

Vendored from `AOMediaCodec/iamf-tools` under the BSD 3-Clause Clear
License and the Alliance for Open Media Patent License 1.0. The
`sine_128samp_*` files are not in upstream: the Eclipsa Studio fork of
iamf-tools generated them from its `iamf/cli/testdata/sine_128samp_*.textproto`
inputs, and their path column gives the fork path.

| File | Upstream path | Notes |
|---|---|---|
| `noise_3s_stereo_opus.iamf` | `iamf/cli/testdata/iamf/noise_3s_stereo_opus.iamf` | 3 s stereo Opus — one channel-based AE. |
| `tones_100ms_3OA_stereo_opus.iamf` | `iamf/cli/testdata/iamf/tones_100ms_3OA_stereo_opus.iamf` | 100 ms two-AE file: 3rd-order ambisonics + stereo. Used for multi-AE tests. |
| `noise_1024samp_stereo_flac.iamf` | `iamf/cli/testdata/iamf/noise_1024samp_stereo_flac.iamf` | 1024-sample stereo FLAC — one channel-based AE. Exercises the descriptors-only duration (FLAC STREAMINFO) and the Inspector's FLAC codec-config path. Source SHA `c89b902`. |
| `sine_128samp_mono_pcm.iamf` | `iamf/cli/testdata/iamf/sine_128samp_mono_pcm.iamf` | 128-sample mono LPCM. Capability coverage (ES-330). |
| `sine_128samp_binaural_pcm.iamf` | `iamf/cli/testdata/iamf/sine_128samp_binaural_pcm.iamf` | 128-sample Binaural LPCM. Capability coverage (ES-326/ES-330). |
| `sine_128samp_7_1_pcm.iamf` | `iamf/cli/testdata/iamf/sine_128samp_7_1_pcm.iamf` | 128-sample 7.1 LPCM. Capability coverage (ES-330). |
| `sine_128samp_expanded916_pcm.iamf` | `iamf/cli/testdata/iamf/sine_128samp_expanded916_pcm.iamf` | 128-sample Expanded 9.1.6 LPCM (Base-Enhanced). Capability coverage (ES-330). |
| `sine_128samp_4oa_pcm.iamf` | `iamf/cli/testdata/iamf/sine_128samp_4oa_pcm.iamf` | 128-sample mono-mode 4OA LPCM. Capability coverage (ES-330). |

Upstream LICENSE and PATENTS files apply; see
https://github.com/AOMediaCodec/iamf-tools.

Do not modify these files. If a fixture is regenerated upstream, re-copy
it here and note the source SHA in the commit message.

## MP4 fixtures

Generated here, not vendored.

| File | Generator | Notes |
|---|---|---|
| `stts_zero_tail_h264.mp4` | `engine/tools/generate_stts_fixture.py` | 12 frames of ffmpeg's `testsrc` at 64x64, H.264, whose `stts` box ends with an entry of 2 samples at duration 0, the table VLC 4.0's stream output writes (ES-742). Unpatched GPAC rejects it; `iamf_muxer_test.cc` checks the patched libgpac (`engine/deps/gpac/patches/0001-*.patch`) accepts it. Regenerate with the script; it needs ffmpeg on PATH. |
