# iamf_tools patch

`iamf_tools.patch` is the engine-facing part of the Eclipsa Studio changes to
[AOMediaCodec/iamf-tools](https://github.com/AOMediaCodec/iamf-tools).
`engine/MODULE.bazel` fetches upstream at `IAMF_TOOLS_COMMIT` and applies it.
The first lines of the patch name the upstream base and the fork commit it was
generated from.

The patch carries the stream API (`iamf/api/stream` and the `iamf_stream_*`
headers under `iamf/include/iamf_tools`), public visibility on the targets the
engine links, `IAMF_TOOLS_DISABLE_BINAURAL_RENDERING` on `renderer_factory` so
iamf-tools' copy of OBR does not collide with the `obr` module at link time,
and the `--verify` and textproto output of `probe_main`. It also carries
`SpanBasedReadBitBuffer` (`iamf/common/span_read_bit_buffer.*`), which the
probe and the stream use to read a memory-mapped input without copying it, and
`SegmentedReadBitBuffer` (`iamf/common/segmented_read_bit_buffer.*`), which
`ProbeSegments` and `OpenFromSegments` use to read consecutive byte ranges as
one bitstream. `iamf/cli/iamf_extract_main.cc` is in the patch because
`iamf/cli/BUILD` declares it.

Upstream merged the probe's ascending-ID sort (AOMediaCodec/iamf-tools#107,
September 30, 2026), its rendering-config position parameter definitions
(AOMediaCodec/iamf-tools#110, October 1, 2026) and the one-step copy of
byte-aligned spans in `ReadBitBuffer::ReadUint8Span`
(AOMediaCodec/iamf-tools#108, October 1, 2026), so `probe_json.cc` and
`read_bit_buffer.cc` are no longer in the patch.

The fork's tests, binary test data, WASM build files and docs are not in the
patch; `engine/iamf/sync-iamf-tools.sh` lists the paths it takes.

Regenerate with `engine/iamf/sync-iamf-tools.sh <fork> [<ref>]`, which also
sets `IAMF_TOOLS_COMMIT` to the fork's merge base with upstream main. With
`--keep-pin` it writes the patch against the current `IAMF_TOOLS_COMMIT`,
which must be an ancestor of the merge base, and leaves `MODULE.bazel`
unchanged. The patch carries only the listed paths, so upstream changes
between the pin and the merge base outside them stay at the pinned
version; the script lists those files, and a carried file that depends on
the newer version of one of them does not build. Do not edit the patch file by hand.
