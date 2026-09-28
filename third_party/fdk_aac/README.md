# Fraunhofer FDK AAC Codec Library

Notice text only; no upstream source is checked in. Bazel fetches the
library at build time through iamf-tools (`git_repository` `fdk_aac` in
iamf-tools' `MODULE.bazel`, pinned to the commit in `METADATA`), and
iamf-tools links its AAC decoder into the targets the engine uses.

- `NOTICE` is ours: what is shipped, the exact source commit, and where
  it is linked. Section 2 of the Fraunhofer license requires the
  complete license text with binary redistributions and that the
  complete source be made available; the notice names the unmodified
  upstream at the built commit.
- The license text itself is upstream's `NOTICE` file, read from the
  fetched repository by `scripts/collect_third_party_notices.py`, which
  places this `NOTICE` before it in `THIRD_PARTY_NOTICES.txt` and the
  in-app licenses page.

`license_type` is `BY_EXCEPTION_ONLY`, the value upstream's own
`METADATA` carries; the license is not an OSI license and grants no
patent rights.

Consumers: `engine/iamf/` (through `@iamf_tools//iamf/cli:probe`,
`iamf_stream_factory` and the encoder factory).
