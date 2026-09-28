// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ffi_bridge.dart';
import '../state.dart';
import '../theme.dart';

/// Suffix the Windows device manager appends to every ASIO driver's
/// name (`engine/io/device_manager_wasapi.cc`), which keeps an ASIO
/// device distinct from the same interface's WASAPI endpoint.
const String kAsioDeviceSuffix = ' (ASIO)';

/// Steinberg's copyrights notice, verbatim from §3.1k of the Steinberg
/// ASIO SDK Licensing Agreement. The text is fixed by the agreement
/// and must not be reworded.
const String kAsioTrademarkNotice =
    'ASIO is a trademark of Steinberg Media Technologies GmbH, '
    'registered in Europe and other countries.';

/// The Steinberg ASIO Compatible Logo, unaltered from the SDK's
/// `Steinberg ASIO Logo Artwork/` folder.
///
/// The SDK ships two designs rather than two colourways of one: a ™
/// lockup reversed out of a solid black plate (near square, aspect
/// 1.08) and this ® lockup, the bare mark on transparency (aspect
/// 1.57). Picking one per theme therefore changed the logo's size and
/// its trademark symbol with the theme, so both themes use the ® mark
/// and a light theme puts it on a black plate for contrast. Placing
/// the artwork on a background leaves it unaltered, which is what the
/// usage guidelines require.
const String kAsioLogo = 'assets/asio/asio_compatible_logo_white.png';

/// Whether [devices] lists an ASIO device, which makes the device
/// picker a dialog that enables ASIO.
bool listsAsioDevice(List<AudioDeviceInfo> devices) =>
    devices.any((d) => d.name.endsWith(kAsioDeviceSuffix));

/// The ASIO Compatible Logo and Steinberg's notice. The Steinberg ASIO
/// Usage Guidelines (§1f) require the logo in every dialog that enables
/// or configures ASIO when ASIO is activated manually, which is how
/// Eclipsa Studio uses it: an ASIO device is picked in the audio
/// settings.
class AsioTrademarkNotice extends ConsumerWidget {
  const AsioTrademarkNotice({super.key});

  /// Rendered logo height in logical pixels. The same in every theme:
  /// only the plate behind it changes.
  static const double logoHeight = 36;

  /// Padding between the logo and the edge of its plate.
  static const double _platePadding = T.gapSm;

  /// The plate a light theme draws behind the white logo, in the black
  /// of the SDK's own ™ artwork, so the mark reads as Steinberg
  /// presents it rather than as a hole in the dialog.
  static const Color _plateColor = Color(0xFF0C0C0C);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    const logo = Image(
      image: AssetImage(kAsioLogo),
      height: logoHeight,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'ASIO Compatible logo',
    );
    return Row(
      children: [
        if (T.brightness == Brightness.light)
          DecoratedBox(
            decoration: BoxDecoration(
              color: _plateColor,
              borderRadius: BorderRadius.circular(T.radiusSm),
            ),
            child: const Padding(
              padding: EdgeInsets.all(_platePadding),
              child: logo,
            ),
          )
        else
          logo,
        const SizedBox(width: T.gapMd),
        Expanded(
          child: Text(
            kAsioTrademarkNotice,
            style: TextStyle(color: T.textTertiary, fontSize: T.fontSmall),
          ),
        ),
      ],
    );
  }
}
