# How to contribute

We'd love to accept your patches and contributions to this project.

## Before you begin

### Sign our Contributor License Agreement

Contributions to this project must be accompanied by a
[Contributor License Agreement](https://cla.developers.google.com/about) (CLA).
You (or your employer) retain the copyright to your contribution; this simply
gives us permission to use and redistribute your contributions as part of the
project.

If you or your current employer have already signed the Google CLA (even if it
was for a different project), you probably don't need to do it again.

Visit <https://cla.developers.google.com/> to see your current agreements or to
sign a new one.

### Review our community guidelines

This project follows
[Google's Open Source Community Guidelines](https://opensource.google/conduct/).

## Getting started

The README has the [prerequisites](README.md#prerequisites), with a
first-time setup for macOS and for Windows, and the
[build and run commands](README.md#build--run). The one rule that is not
obvious from a Flutter project: always build and run through the repo-root
script, `./build.sh` on macOS or `.\build.ps1` on Windows, never a bare
`flutter run`. The script builds the C++ audio engine with Bazel and copies
it into the app; a bare `flutter run` skips that and runs against a stale or
missing engine.

The repository is two siblings: `engine/`, the C++ real-time audio engine,
built with Bazel and reused outside the app; and `app/`, the Flutter desktop
app that drives it over FFI. The README's
[project structure](README.md#project-structure) section lists what lives
where. The constraints a change has to respect are stated in the comments
of the code it touches; read the header comments of the files in an area
before changing it.

## Before opening a pull request

CI runs these on every pull request; run them first so the review starts
from a green build:

```sh
cd engine && bazel test //...           # C++ engine unit tests
cd app && flutter analyze lib/          # Dart analysis
cd app && flutter test                  # widget, golden and FFI tests
./build.sh lint --check                 # formatting gate: clang-format, clang-tidy, dart format
```

`flutter test` drives the engine library when it has been built
(`./build.sh engine`) and skips those tests otherwise. `./build.sh lint`
without `--check` formats in place. On Windows, `.\build.ps1 lint --check`
is the equivalent.

Every new source file starts with the Apache 2.0 header; copy it from a
neighbouring file. Prose in the repository, from code comments to release
notes, is plain English stating facts: concrete numbers, names and units;
no speculation and no hedging about what something is (verify the fact or
leave it out); "must not" where the meaning is a prohibition; no rhetorical
fragments, rules of three or asides that comment on the text itself.

## Branches and commits

Branch off `main`. Name the branch `fix/<slug>` for a bug, `feat/<slug>`
for a feature, `chore/<slug>` for housekeeping or `docs/<slug>` for
documentation.

Commit subjects follow Conventional Commits: `type(scope): summary`,
lowercase, imperative, no trailing period. Types in use are `feat`, `fix`,
`chore`, `docs`, `style`, `refactor` and `test`; the scope is the area
touched (`engine`, `ci`, `adm-import`, ...) and is left out only when no
single scope fits. Anything beyond a trivial change gets a body that says
what problem it solves, why this approach, and what was tested (for
example `bazel test //... -> 69/69`, `flutter analyze` clean), wrapped at
about 72 characters.

## Pull requests

- One scope per pull request. Tightly related follow-up fixes can ride
  along; unrelated work goes in its own pull request.
- The description says what changed and why, in soft-wrapped paragraphs
  (GitHub reflows them; hard-wrapped prose renders ragged).
- A change to the UI or to runtime behaviour carries a test-plan
  checklist: the commands run, and what was checked in the running app.
- End the description with `Closes` and the issue number, so the issue
  closes when the pull request merges.
- Pull requests merge with a rebase, never a squash, so each commit's
  message survives on `main`. Keep the branch's history in the shape it
should have there.

## Code reviews

All submissions, including submissions by project members, require review. We
use GitHub pull requests for this purpose. Consult
[GitHub Help](https://help.github.com/articles/about-pull-requests/) for more
information on using pull requests.
