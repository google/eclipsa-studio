# Google Sans

Upstream SIL Open Font License 1.1 text for the typeface of the Eclipsa
Audio wordmark.

No font file is here or in `app/assets/fonts/`. The app draws the
wordmark "Eclipsa Audio" from vector outlines: the twelve glyphs it
needs (E, c, l, i, p, s, a, A, u, d, i, o), read out of the font at its
default instance (wght=400, opsz=18, GRAD=0) and written as Dart
constants in `app/lib/widgets/eclipsa_audio_wordmark_data.dart` by
`scripts/gen_eclipsa_audio_wordmark.py`. That is the whole of what the
repo carries from the font: the twelve outlines, as move, line,
quadratic-curve and close records in font units. The 5 MB variable
font is not bundled.

- Upstream: [googlefonts/googlesans](https://github.com/googlefonts/googlesans),
  distributed through [google/fonts](https://github.com/google/fonts)
  `ofl/googlesans/GoogleSans[GRAD,opsz,wght].ttf`, commit 5412d702,
  font version 14.000, fetched 2026-09-21. SHA-256 of that file:
  `d0a87d835a944b8b40d0e82a5651bb59ab97b936a2aeed5946eb57e7b2a3a90a`.
- Outlines transcribed unmodified, at integer font units, from the
  default instance of the variable font. The glyphs' positions in the
  lockup come from the Eclipsa Audio lockup artwork, not from the
  font's advances; the script records them.
- No Reserved Font Name: the `LICENSE` copyright line names "The Google
  Sans Project Authors" with no `with Reserved Font Name` clause.
  `TRADEMARKS.md` upstream states that "Google" and "Google Sans" are
  trademarks of Google LLC; this repo uses the name only to identify
  the source of the outlines.

`scripts/collect_third_party_notices.py` reads `LICENSE` into
`third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json`. The text is not listed in
`pubspec.yaml`, so it is not bundled into the shipped app.
