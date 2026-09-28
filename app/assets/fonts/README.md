# Bundled typefaces

Upstream font binaries shipped inside the app bundle. Do not edit them —
they must stay byte-identical to the upstream drop so a version bump is
a plain re-copy.

## What is bundled

| File | Family / weight | Upstream |
|------|-----------------|----------|
| `Inter-Light.ttf` | Inter 300 | [rsms/inter](https://github.com/rsms/inter) v4.1, `extras/ttf/` |
| `Inter-Regular.ttf` | Inter 400 | ” |
| `Inter-Medium.ttf` | Inter 500 | ” |
| `Inter-SemiBold.ttf` | Inter 600 | ” |
| `Inter-Bold.ttf` | Inter 700 | ” |
| `JetBrainsMono-Regular.ttf` | JetBrains Mono 400 | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono), `fonts/ttf/` |
| `JetBrainsMono-Bold.ttf` | JetBrains Mono 700 | ” |

Inter and JetBrains Mono are the faces of every theme (Dark, Light,
Classic and High Contrast). The 2026-09 remake of Classic, Theme B and
High Contrast bundled five more families, and all five have since left:
Source Sans 3 and Source Code Pro with Theme B, IBM Plex Sans and IBM
Plex Mono when Classic moved to Inter and JetBrains Mono, and Atkinson
Hyperlegible when High Contrast did the same.

`third_party/fonts/<family>/LICENSE` (`inter`, `jetbrains_mono`) are
the upstream licence texts. They sit there so
`scripts/collect_third_party_notices.py` can read them, but are **not**
listed in `pubspec.yaml`, so they are not bundled into the shipped app.
`third_party/fonts/google_sans/` holds a licence text only: no Google
Sans file ships, and the Eclipsa Audio wordmark is drawn from glyph
outlines generated into `app/lib/widgets/eclipsa_audio_wordmark_data.dart`.

Weights are exactly the ones the app uses — Inter at 300/400/500/600/700
and mono at 400/700, from a call-site audit. The 300 weight is used by
the top bar's inactive workspace tabs in every theme. Adding a weight
means adding the file *and* a `pubspec.yaml` entry; Flutter otherwise
synthesises it from the nearest, which looks subtly wrong rather than
failing.

## Why the binaries are here and the licences are not

Flutter resolves `pubspec.yaml` asset paths relative to the package root
and they cannot escape it, so the `.ttf` files would not load from the
repo root. The licence texts carry no such constraint, so they live under
`third_party/fonts/<family>/LICENSE` with every other third-party licence
in the tree.

## Licensing

Both families are licensed under the **SIL Open Font License 1.1**, which
permits embedding in an application, bundling in a source repository, and
redistribution. The obligations are: provide the copyright notice and
licence text, do not sell the fonts on their own, and do not reuse a
Reserved Font Name on a *modified* version.

All three are met. The licence texts are under `third_party/fonts/`,
aggregated into `third_party/THIRD_PARTY_NOTICES.txt` and
`app/assets/third_party_notices.json` and gated by
`collect_third_party_notices.py --check`. Both families ship
unmodified, and neither declares a Reserved Font Name.

The top-level `README.md` states that the typefaces sit outside the
project's Apache 2.0 grant and points at both licence texts.
