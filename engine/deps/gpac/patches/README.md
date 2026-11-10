# Local GPAC patches

`build_gpac.sh` and `build_gpac.ps1` apply every `*.patch` here, in name
order, to the pinned GPAC checkout before configuring it (`git apply`, so
a patch that no longer fits the pin fails the build). Each patch is a
`git diff` against the pinned commit and changes one thing. Drop a patch
when a pin bump picks up the upstream fix.
