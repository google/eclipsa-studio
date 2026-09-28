# Inter

Upstream SIL Open Font License 1.1 text for the UI typeface.

The font binaries are **not** here. Flutter resolves `pubspec.yaml` asset
paths relative to the package root and they cannot escape it, so the five
bundled weights live at `app/assets/fonts/Inter-{Light,Regular,Medium,
SemiBold,Bold}.ttf` (300/400/500/600/700). See
`app/assets/fonts/README.md` for the weight audit and the upstream drop
procedure.

- Upstream: [rsms/inter](https://github.com/rsms/inter) release v4.1,
  `extras/ttf/`.
- Font-internal version string: `4.001;git-9221beed3`.
- Shipped unmodified.
- No Reserved Font Name: the `LICENSE` copyright line names only "The
  Inter Project Authors", with no `with Reserved Font Name` clause.

`scripts/collect_third_party_notices.py` reads `LICENSE` into
`third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json`. The text is not listed in
`pubspec.yaml`, so it is not bundled into the shipped app.
