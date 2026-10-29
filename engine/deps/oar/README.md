# oar and obr patches

`oar.patch` and `obr.patch` are the Eclipsa Studio changes to
[AOMediaCodec/oar](https://github.com/AOMediaCodec/oar). `engine/MODULE.bazel`
fetches upstream at `OAR_COMMIT` and applies `oar.patch` to the `oar` module
and `obr.patch` to the nested `obr` module, which is the
`src/renderer/obr/obr_capi/obr` subdirectory fetched with `strip_prefix`.
The first lines of each patch name the upstream base and the fork commit it
was generated from.

`oar.patch` carries `oar_get_limiter_env()`, the layout-anchored
cartesian-to-polar position conversion and its public helpers
(`oar_position_anchors_create()`, `oar_cartesian_to_polar()`), the
threading contract in `oar.h`, OLR azimuth wrapping, an EAR dangling-pointer
fix, OLR's interpolated-gain loop without a per-sample bounds check, group
and element gain passes skipped when no gain metadata is queued, and the
fork's tests and docs. Upstream has the render path that does not allocate,
OLR's position timeline after renders without positions and the OBR
changes (one encoder per head-locked and world-locked pass, head rotation
and flags set without the render mutex) from AOMediaCodec/oar#52,
AOMediaCodec/oar#54, AOMediaCodec/oar#55, AOMediaCodec/oar#56 and
AOMediaCodec/oar#58, merged on October 21, 2026; `a7a5cc89` includes all
five. obr has no fork changes, so `obr.patch` carries only its header.

Regenerate with `engine/renderer/sync-oar.sh <fork> [<ref>]`, which also
sets `OAR_COMMIT` to the fork's merge base with upstream main. With
`--keep-pin` it writes the patches against the current `OAR_COMMIT`, which
must be an ancestor of the merge base, and leaves `MODULE.bazel`
unchanged. Do not edit the patch files by hand.
