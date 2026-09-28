# JetBrains Mono

Upstream SIL Open Font License 1.1 text for the monospace typeface.

The font binaries are **not** here. Flutter resolves `pubspec.yaml` asset
paths relative to the package root and they cannot escape it, so the two
bundled weights live at
`app/assets/fonts/JetBrainsMono-{Regular,Bold}.ttf` (400/700). See
`app/assets/fonts/README.md` for the weight audit and the upstream drop
procedure.

- Upstream:
  [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono),
  `fonts/ttf/`.
- Font-internal version string: `2.305`.
- Shipped unmodified.
- No Reserved Font Name: the `LICENSE` copyright line names only "The
  JetBrains Mono Project Authors", with no `with Reserved Font Name`
  clause.

`scripts/collect_third_party_notices.py` reads `LICENSE` into
`third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json`. The text is not listed in
`pubspec.yaml`, so it is not bundled into the shipped app.
