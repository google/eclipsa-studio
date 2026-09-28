# oar and obr patches

`oar.patch` and `obr.patch` are the Eclipsa Studio changes to
[AOMediaCodec/oar](https://github.com/AOMediaCodec/oar). `engine/MODULE.bazel`
fetches upstream at `OAR_COMMIT` and applies `oar.patch` to the `oar` module
and `obr.patch` to the nested `obr` module, which is the
`src/renderer/obr/obr_capi/obr` subdirectory fetched with `strip_prefix`.
The first lines of each patch name the upstream base and the fork commit it
was generated from.

The patches carry `oar_get_limiter_env()`, the layout-anchored
cartesian-to-polar position conversion and its public helpers
(`oar_position_anchors_create()`, `oar_cartesian_to_polar()`), OLR azimuth
wrapping, an EAR dangling-pointer fix, the fork's tests and docs, and the
Bazel 8 wiring for the nested obr module (its pffft build file moves from
`external/` to `third_party/`, because Bazel reserves a top-level `external`
package).

Regenerate with `engine/renderer/sync-oar.sh <fork> [<ref>]`, which also
sets `OAR_COMMIT`. Do not edit the patch files by hand.
