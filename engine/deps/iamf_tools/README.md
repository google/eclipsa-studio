# iamf_tools patch

`iamf_tools.patch` is the engine-facing part of the Eclipsa Studio changes to
[AOMediaCodec/iamf-tools](https://github.com/AOMediaCodec/iamf-tools).
`engine/MODULE.bazel` fetches upstream at `IAMF_TOOLS_COMMIT` and applies it.
The first lines of the patch name the upstream base and the fork commit it was
generated from.

The patch carries the `probe` and `probe_json` libraries and `probe_main`, the
stream API (`iamf/api/stream` and the `iamf_stream_*` headers under
`iamf/include/iamf_tools`), public visibility on the targets the engine links,
and `IAMF_TOOLS_DISABLE_BINAURAL_RENDERING` on `renderer_factory` so
iamf-tools' copy of OBR does not collide with the `obr` module at link time.
The fork's tests, binary test data, WASM build files and docs are not in the
patch; `engine/iamf/sync-iamf-tools.sh` lists the paths it takes.

Regenerate with `engine/iamf/sync-iamf-tools.sh <fork> [<ref>]`, which also
sets `IAMF_TOOLS_COMMIT`. Do not edit the patch file by hand.
