# Steinberg ASIO SDK (host subset) — license and notice texts

Attribution files for the Windows ASIO output backend (the engine
workspace's `//io:asio_backend`, ES-101). No SDK source is checked in
here. The build fetches Steinberg's archive,
`ASIO-SDK_2.3.4_2025-10-15.zip`, from the versioned URL that
<https://www.steinberg.net/asiosdk> redirects to, verifies its sha256,
and compiles the host-side subset into the Windows engine DLL. The
pin is the `asio` `http_archive` in `engine/MODULE.bazel`; the build
file is `engine/deps/asio/asio.BUILD`.

| File | What it is |
|------|------------|
| `LICENSE` | Upstream: the SDK's `LICENSE.txt`, verbatim. |
| `LICENSE.host` | Upstream: the license block embedded in the five `host/` files that are compiled (`asiodrivers.{h,cpp}`, `ginclude.h`, `pc/asiolist.{h,cpp}`), verbatim. `LICENSE.txt` applies only to files that reference it, and these files carry this BSD-style text instead; its binary-redistribution clause is why it ships in the notices. |
| `NOTICE` | Project-authored: the trademark attribution and the licence Eclipsa Studio uses the SDK under. |

## What is compiled

The files a *host* application needs, from the archive's `ASIOSDK/`
directory:

| Path | Role |
|------|------|
| `common/asio.{h,cpp}` | C-style host API (`ASIOInit`, `ASIOCreateBuffers`, …) wrapping the loaded driver |
| `common/asiosys.h` | Platform defines (auto-detects `_WIN32`) |
| `common/iasiodrv.h` | The COM-style `IASIO` driver interface |
| `host/asiodrivers.{h,cpp}` | Driver enumeration + load/unload (`AsioDrivers`) |
| `host/ginclude.h` | Endianness/CPU defines |
| `host/pc/asiolist.{h,cpp}` | Registry walk + COM instantiation of installed drivers |

Not compiled: the `driver/` tree, `combase.*`, `dllentry.cpp`,
`register.cpp`, `debugmessage.cpp`, `wxdebug.h` (driver-side),
`ASIOConvertSamples.*` (the backend does its own real-time sample
conversion), the docs and the logo artwork.

To move to a new SDK release, change the URL and `sha256` in
`engine/MODULE.bazel` together, and update `METADATA`, `LICENSE` and
`LICENSE.host`.

## Licensing

The SDK is dual-licensed (`LICENSE`): **Steinberg proprietary ASIO
License** OR **GPLv3**. Eclipsa Studio uses it under the executed
Steinberg ASIO SDK Licensing Agreement (ES-101, ES-818). The agreement
permits distributing a product built with the SDK (§2.1b) but not the
SDK or parts of it (§2.3), which is why no SDK file is in this
repository. Anyone building from source obtains the SDK from
Steinberg on Steinberg's terms.

Trademark: the agreement fixes Steinberg's copyrights notice (§3.1k):
*"ASIO is a trademark of Steinberg Media Technologies GmbH, registered
in Europe and other countries"*. The Steinberg ASIO Usage Guidelines,
attached to the agreement as its Annex (§3.1d), add the ® symbol on the
first use of "ASIO" in product material (§15) and the ASIO Compatible
Logo in the places listed below. Both texts ship in the SDK archive
(`Steinberg ASIO Licensing Agreement.pdf`, `Steinberg ASIO Usage
Guidelines.pdf`).

Where each obligation is met for a product distributed without a
tangible form (ES-554, ES-888):

| Source | Obligation | Where |
|---|---|---|
| Agreement 3.1b | "ASIO" and the notice in an About box, a splash screen or bundled documentation, at least one of them bundled | `THIRD_PARTY_NOTICES.txt` carries the notice and is staged beside the app by `./build.sh package` (DMG) and `build.ps1 package` (Windows zip); the in-app Third-Party Licenses window shows the same entry |
| Agreement 3.1c | the notice in documentation that mentions ASIO | `README.md`, with the logo; the notices file for the shipped product |
| Agreement 3.1c | the notice in every About box or splash screen that names any third party | the app has neither; add the notice to whichever is added first |
| Agreement 3.1c, Guidelines 4 | the logo and the notice on every web page that mentions ASIO | the repository `README.md` shows both next to its ASIO mention. Release pages and the documentation site are outside this repository: a page that mentions ASIO must show the logo and the notice |
| Guidelines 1f | ASIO activated manually: the logo in every dialog that enables or configures ASIO | the Audio tab of Settings shows the logo and the notice (`AsioTrademarkNotice`, `app/lib/widgets/asio_trademark_notice.dart`) whenever the device list contains an ASIO device |
| Guidelines 15 | ® on the first use of "ASIO" in product material | `NOTICE` and `README.md`. The device list's " (ASIO)" suffix is a device label and carries no mark |
| Agreement 3.1e to 3.1i, Guidelines 6 to 13 | "ASIO" in regular type, never stylised, never in a product or firm name, never altered into derivatives | it appears as "ASIO" or "(ASIO)" in device labels and prose only |
| Agreement 3.1j | records of ASIO trademark use by country, year and product once 1000 or more people use the products | not yet required |

The logo files are Steinberg's artwork from the SDK archive's `Steinberg
ASIO Logo Artwork/` folder, unaltered. The folder ships two designs
rather than two colourways of one, and they differ in both proportion
and trademark symbol, so each is used where it reads correctly:

- `app/assets/asio/asio_compatible_logo_white.png`
  (`ASIO-compatible-logo-Steinberg-®-white-transparent-RGB.png`), the ®
  lockup on transparency, aspect 1.57. The app shows this one in every
  theme; a light theme puts it on a black plate for contrast, which
  leaves the artwork itself untouched.
- `app/assets/asio/asio_compatible_logo_bw.png`
  (`ASIO-compatible-logo-Steinberg-TM-BW.png`), the ™ lockup reversed
  out of a black plate, aspect 1.08. Used by the repository `README.md`,
  which GitHub renders on white. It is not bundled into the app.

Choosing per theme between the two was what made the logo change size
and trademark symbol with the theme; one lockup everywhere fixes both.
The agreement permits using the logo as the guidelines define (§3.1d,
§3.1l).

Re-check the table when the Windows packaging changes (ES-279) or when an
About box or splash screen is added.

## Build

`@asio` is an `http_archive` declared in `engine/MODULE.bazel` with
`strip_prefix = "ASIOSDK"` and the overlay build file
`engine/deps/asio/asio.BUILD`.

`@asio//:asio` is a Windows-only `cc_library`
(`target_compatible_with = ["@platforms//os:windows"]`); consumers keep
the dependency edge behind a `select()` so non-Windows build graphs
never reference it, and the archive is downloaded only by Windows
builds. It links `ole32`, `advapi32`, and `user32` (COM + registry +
`CharLowerBuff` used by `asiolist.cpp`).
