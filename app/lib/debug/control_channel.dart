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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../logging/log.dart';
import '../session/session_provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/theme_gallery.dart';
import '../workspace/workspace_mode.dart';

/// Whether the control channel is built at all.
///
/// [kDebugMode] is a compile-time const, so in a release build the one
/// call site collapses, this library becomes unreachable and the tree
/// shaker drops it — the same mechanism `kThemeGalleryEnabled` uses,
/// and verified the same way: no string that appears only here is
/// present in a release binary.
const bool kDebugControlChannelEnabled = kDebugMode;

/// A loopback HTTP server that drives the running app, so a screenshot
/// sweep is a loop rather than a sequence of hand-placed clicks (ES-688).
///
/// It exists because the app is the only place some things are
/// observable: the static scene renders in `test/render/` cover what a
/// drawing looks like, but not the engine, the real window, or native
/// chrome.
///
/// Not a general remote-control surface. Every command is one a
/// developer could perform by hand in a debug build; nothing here
/// reaches past the app's own providers.
///
/// **Access.** Bound to 127.0.0.1 on an ephemeral port, and every
/// request must carry the launch's token. The port and token are
/// written to `eclipsa_studio_control.json` beside the JSONL log, and
/// the file is rewritten on each launch. Loopback alone is not the
/// gate: any local process can reach a loopback port, so the token is
/// what stops one driving the app.
class DebugControlChannel {
  DebugControlChannel._(this._server, this._token, this._navigatorKey);

  final HttpServer _server;
  final String _token;
  final GlobalKey<NavigatorState> _navigatorKey;

  /// Starts the channel, or returns null if it could not bind.
  ///
  /// Failing to bind is not fatal: the app runs without the channel and
  /// says so in the log.
  static Future<DebugControlChannel?> start({
    required GlobalKey<NavigatorState> navigatorKey,
    required String stateDir,
  }) async {
    if (!kDebugControlChannelEnabled) return null;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final token = _newToken();
      final channel = DebugControlChannel._(server, token, navigatorKey);
      final file = File(p.join(stateDir, 'eclipsa_studio_control.json'));
      file.writeAsStringSync(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'port': server.port, 'token': token}),
      );
      Log.i(LogCat.app, 'control channel: ${file.path} (port ${server.port})');
      unawaited(channel._serve());
      return channel;
    } on SocketException catch (e) {
      Log.w(LogCat.app, 'control channel not started', e);
      return null;
    } on FileSystemException catch (e) {
      Log.w(LogCat.app, 'control channel not started', e);
      return null;
    }
  }

  static String _newToken() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      // Not awaited: one slow or wedged command must not stop the
      // channel answering the next. A screenshot that cannot get a
      // frame used to block every later request behind it.
      unawaited(_respond(request));
    }
  }

  Future<void> _respond(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (e, stack) {
      Log.e(LogCat.app, 'control channel request failed: $e', stack);
      _text(request, HttpStatus.internalServerError, '$e');
    }
    try {
      await request.response.close();
    } catch (_) {
      // close(force: true) can cut a request off mid-flight, and the
      // socket is then gone. Nothing is waiting on this response, so
      // there is nowhere to report it.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final given =
        request.headers.value('x-debug-token') ??
        request.uri.queryParameters['token'];
    if (given != _token) {
      // No detail: an unauthorised caller learns nothing about what
      // the channel offers.
      return _text(request, HttpStatus.forbidden, 'bad token');
    }

    // Only the commands that read or write app state need the
    // container. /screenshot does not, and requiring one would mean a
    // capture could never be taken before the first frame mounts.
    final container = _container;

    switch (request.uri.path) {
      case '/health':
        if (container == null) return _notReady(request);
        return _json(request, {
          'theme': T.mode.name,
          'workspace': container.read(workspaceModeProvider).name,
          'trackScale': container.read(timelineViewportProvider).trackScale,
          'tab': container.read(activeTabProvider),
          ..._loopJson(container),
        });

      case '/tab':
        if (container == null) return _notReady(request);
        final body = await _body(request);
        final tab = body['tab'];
        final allowed = WorkspaceTabs.allowedIn(
          container.read(workspaceModeProvider),
        );
        if (allowed.isEmpty) {
          return _text(request, HttpStatus.conflict, 'no workspace is open');
        }
        if (tab is! String || !allowed.contains(tab)) {
          return _text(
            request,
            HttpStatus.badRequest,
            'tab must be one of $allowed in the current workspace',
          );
        }
        container.read(activeTabProvider.notifier).set(tab);
        return _json(request, {'tab': tab});

      case '/loop':
        // A loop region in seconds, as a drag across the ruler sets
        // one, plus the loop toggle. `clear` removes the region and,
        // if there was one, disarms the toggle, as Escape does.
        if (container == null) return _notReady(request);
        // Only the Creator Elements ruler draws a loop region; anywhere
        // else /loop would set one the app gives no way to see or make.
        if (container.read(workspaceModeProvider) != WorkspaceMode.creator) {
          return _text(
            request,
            HttpStatus.conflict,
            'a loop region exists only in a Creator session',
          );
        }
        final body = await _body(request);
        // Every field is checked before any provider is written, so a
        // refused request changes nothing.
        final rawStart = body['start'];
        final rawEnd = body['end'];
        final rawEnabled = body['enabled'];
        final rawClear = body['clear'];
        if ((rawStart != null && rawStart is! num) ||
            (rawEnd != null && rawEnd is! num) ||
            (rawEnabled != null && rawEnabled is! bool) ||
            (rawClear != null && rawClear is! bool)) {
          return _text(
            request,
            HttpStatus.badRequest,
            'start and end are numbers; enabled and clear are booleans',
          );
        }
        if (rawClear == true) {
          if (rawStart != null || rawEnd != null || rawEnabled != null) {
            return _text(
              request,
              HttpStatus.badRequest,
              'clear takes no other field',
            );
          }
          container.read(loopRegionProvider.notifier).clear();
          return _json(request, _loopJson(container));
        }
        final start = (rawStart as num?)?.toDouble();
        final end = (rawEnd as num?)?.toDouble();
        if ((start != null && !start.isFinite) ||
            (end != null && !end.isFinite)) {
          return _text(
            request,
            HttpStatus.badRequest,
            'start and end must be finite',
          );
        }
        if ((start == null) != (end == null)) {
          return _text(
            request,
            HttpStatus.badRequest,
            'start and end go together, in seconds',
          );
        }
        if (start != null && end != null) {
          final transport = container.read(transportProvider);
          final rate = transport.sampleRate;
          final s = (start * rate).round().clamp(0, transport.durationSamples);
          final e = (end * rate).round().clamp(0, transport.durationSamples);
          if (e <= s) {
            return _text(
              request,
              HttpStatus.badRequest,
              'end must be after start, within '
              '${transport.durationSeconds.toStringAsFixed(3)} s',
            );
          }
          container
              .read(loopRegionProvider.notifier)
              .set(LoopRegion(startSample: s, endSample: e));
        }
        // Setting a region arms the toggle unless told otherwise;
        // `enabled` alone arms or disarms it without touching the region.
        final enabled = rawEnabled as bool? ?? (start != null ? true : null);
        if (enabled != null) {
          container.read(loopingProvider.notifier).set(enabled);
        }
        return _json(request, _loopJson(container));

      case '/theme':
        if (container == null) return _notReady(request);
        final body = await _body(request);
        final name = body['mode'] as String?;
        final mode = AppThemeMode.values
            .where((m) => m.name == name)
            .firstOrNull;
        if (mode == null) {
          return _text(
            request,
            HttpStatus.badRequest,
            'mode must be one of ${AppThemeMode.values.map((m) => m.name)}',
          );
        }
        container.read(themeModeProvider.notifier).set(mode);
        return _json(request, {'theme': mode.name});

      case '/track-scale':
        if (container == null) return _notReady(request);
        final body = await _body(request);
        final value = (body['value'] as num?)?.toDouble();
        if (value == null) {
          return _text(request, HttpStatus.badRequest, 'value is required');
        }
        container.read(timelineViewportProvider.notifier).setTrackScale(value);
        return _json(request, {
          'trackScale': container.read(timelineViewportProvider).trackScale,
        });

      case '/session':
        if (container == null) return _notReady(request);
        final body = await _body(request);
        final path = body['path'] as String?;
        if (path == null) {
          return _text(request, HttpStatus.badRequest, 'path is required');
        }
        // loadFile alone is only safe for the transitions
        // prepareForWorkspaceSwitch says need no teardown: from the
        // landing screen, or Creator to Creator. Leaving Playback has
        // to close the open playback session first, and that path
        // raises a dialog this channel cannot answer, so it is refused
        // rather than half-performed.
        final mode = container.read(workspaceModeProvider);
        if (mode == WorkspaceMode.playback) {
          return _text(
            request,
            HttpStatus.conflict,
            'in Playback: close the file in the app first, so the '
            'playback engine session is torn down',
          );
        }
        // A dirty Creator session would be discarded silently. File >
        // Open asks; this refuses unless the caller says to discard.
        if (container.read(sessionProvider).dirty &&
            body['discardUnsaved'] != true) {
          return _text(
            request,
            HttpStatus.conflict,
            'the open session has unsaved changes: pass '
            '"discardUnsaved": true to load over them',
          );
        }
        final ok = await container
            .read(sessionProvider.notifier)
            .loadFile(path);
        return _json(request, {'loaded': ok, 'path': path});

      case '/gallery':
        // The Theme Gallery is where every registered component is
        // drawn per theme, so it is the one screen worth reaching by
        // name: a component in a state the running session cannot
        // produce is visible there and nowhere else.
        final body = await _body(request);
        final open = body['open'] as bool? ?? true;
        final scrollTo = (body['scrollTo'] as num?)?.toDouble();
        // Read the context after the body, and check it is still
        // mounted: this runs in an async handler, so the tree may have
        // changed while the request was being read.
        final context = _navigatorKey.currentContext;
        if (context == null || !context.mounted) {
          return _text(request, HttpStatus.serviceUnavailable, 'app not ready');
        }
        if (open != ThemeGallery.isOpen) ThemeGallery.toggle(context);
        if (!open || scrollTo == null) return _json(request, {'gallery': open});
        // A gallery opened by this request has no scroll extent until
        // it has laid out once. An occluded window produces no frame,
        // so the wait is bounded rather than the request hanging.
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        final scrolled = ThemeGallery.scrollTo(scrollTo);
        return _json(request, {
          'gallery': open,
          if (scrolled != null) 'scroll': scrolled.offset,
          if (scrolled != null) 'maxScroll': scrolled.max,
        });

      case '/screenshot':
        final settleMs =
            int.tryParse(request.uri.queryParameters['settle'] ?? '') ?? 400;
        final png = await _capture(Duration(milliseconds: settleMs));
        if (png == null) {
          return _text(
            request,
            HttpStatus.serviceUnavailable,
            'no frame: the window produces none while it is occluded, '
            'so bring it to the front before capturing',
          );
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'png')
          ..add(png);
        return;

      default:
        return _text(
          request,
          HttpStatus.notFound,
          'paths: /health /tab /loop /theme /track-scale /session '
          '/gallery /screenshot',
        );
    }
  }

  /// The loop toggle state and the loop region, in seconds.
  Map<String, Object?> _loopJson(ProviderContainer container) {
    final region = container.read(loopRegionProvider);
    final rate = container.read(transportProvider).sampleRate;
    return {
      'looping': container.read(loopingProvider),
      'loop': region == null
          ? null
          : {
              'start': region.startSeconds(rate),
              'end': region.endSeconds(rate),
            },
    };
  }

  /// The app's provider container, reached through the navigator's
  /// context so the channel needs no structural change to the app.
  /// Null until the first frame has mounted the navigator.
  ProviderContainer? get _container {
    final context = _navigatorKey.currentContext;
    if (context == null) return null;
    return ProviderScope.containerOf(context, listen: false);
  }

  /// The Flutter scene as a PNG, at the window's device pixel ratio.
  ///
  /// This is the rasterised widget tree, so it shows what the app
  /// draws and nothing the window server draws around it — the macOS
  /// menu bar, native sheets and the titlebar are not in it. Capture
  /// those with `screencapture` instead.
  /// [settle] is how long to keep producing frames before reading the
  /// scene. `?settle=<ms>` overrides it.
  ///
  /// Counting frames is not enough. A command that changes state
  /// returns as soon as the provider is written, and the widgets that
  /// animate implicitly are still tweening: `DropZone` is an
  /// `AnimatedContainer` with a 120 ms duration, so a capture a few
  /// frames after a theme switch catches its ground half way between
  /// the two themes. In a single frame that looks the same as a widget
  /// that missed the switch because it was constructed `const` upstream
  /// and never rebuilt. The 400 ms default is longer than
  /// `DropZone`'s 120 ms animation.
  Future<Uint8List?> _capture(Duration settle) async {
    final binding = WidgetsBinding.instance;
    final deadline = DateTime.now().add(settle);
    // scheduleFrame is required: endOfFrame only
    // completes when a frame is actually produced, and an idle desktop
    // app schedules none — awaiting it bare hangs until something else
    // repaints. macOS also stops producing frames while the window is
    // occluded, so a capture behind another window times out rather
    // than returning a stale image.
    do {
      binding.scheduleFrame();
      try {
        await binding.endOfFrame.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        return null;
      }
    } while (DateTime.now().isBefore(deadline));
    final root = binding.rootElement?.renderObject;
    if (root is! RenderView) return null;
    final layer = root.debugLayer;
    if (layer is! OffsetLayer) return null;
    // Bounds are in the layer's own coordinate space, and the root
    // layer's transform already carries the device pixel ratio, so
    // that space is physical pixels: paintBounds covers the window and
    // pixelRatio must stay 1. Passing the logical size instead
    // captures the top-left corner at the right pixel count and the
    // wrong content; passing paintBounds with the ratio squares it.
    final image = await layer.toImage(root.paintBounds, pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes?.buffer.asUint8List();
  }

  Future<Map<String, Object?>> _body(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : {};
  }

  void _json(HttpRequest request, Map<String, Object?> body) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  void _notReady(HttpRequest request) =>
      _text(request, HttpStatus.serviceUnavailable, 'app not ready');

  void _text(HttpRequest request, int status, String message) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..write(message);
  }
}
