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

import Cocoa
import FlutterMacOS
import ObjectiveC
import desktop_multi_window

// Associated-object keys used to pin the video plugins to a sub-window's view
// controller (see below) so they live exactly as long as that window.
private var avfPluginKey: UInt8 = 0
private var ffmpegPluginKey: UInt8 = 0

@main
class AppDelegate: FlutterAppDelegate {
  // Quit handling (ES-844). FlutterAppDelegate hands `terminate:` to the
  // termination handler of the most recently created engine, which is the
  // video pop-out's engine while a pop-out exists, so Quit could skip the
  // main window's unsaved-changes prompt. It also marks the app as
  // terminating before asking Dart, so a second Quit while the prompt was
  // open exited at once. This delegate asks the main window's engine
  // itself, on its own channel, and holds further quits until it answers.

  /// The main window's `eclipsa/app_exit` channel, set once it exists.
  private var appExitChannel: FlutterMethodChannel?
  /// A quit request has been sent to Dart and not answered yet.
  private var exitRequestInFlight = false
  /// Dart answered "exit": the next `terminate:` goes through.
  private var exitApproved = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    if exitApproved { return .terminateNow }
    // No main engine to ask: nothing can hold unsaved changes.
    guard let channel = appExitChannel else { return .terminateNow }
    // The prompt for an earlier Quit is still open; that answer decides.
    if exitRequestInFlight { return .terminateCancel }
    exitRequestInFlight = true
    channel.invokeMethod("requestExit", arguments: nil) { [weak self] result in
      guard let self = self else { return }
      self.exitRequestInFlight = false
      // "cancel" keeps the app running. Anything else, including no Dart
      // handler (FlutterMethodNotImplemented) or an error, quits: a handler
      // that cannot answer must not make the app unquittable.
      if (result as? String) == "cancel" { return }
      self.exitApproved = true
      NSApp.terminate(nil)
    }
    return .terminateCancel
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The main window's engine answers quit requests (see
    // applicationShouldTerminate). Created here, after the main nib has
    // loaded, so the window's view controller exists.
    if let controller = mainFlutterWindow?.contentViewController
      as? FlutterViewController
    {
      appExitChannel = FlutterMethodChannel(
        name: "eclipsa/app_exit", binaryMessenger: controller.engine.binaryMessenger)
    }

    // Register all plugins for secondary windows created by desktop_multi_window.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)

      // Register the AVFoundation video controller on sub-windows too, so a
      // pop-out can run the AVFoundation backend (the macOS default). It is
      // not a pub plugin, so it isn't in GeneratedPluginRegistrant — mirrors
      // MainFlutterWindow. Retained via an associated object so the plugin's
      // lifetime tracks the sub-window's view controller rather than leaking
      // one per pop-out.
      let avfRegistrar = controller.registrar(forPlugin: "AvfVideo")
      let avfVideo = AvfVideoPlugin(
        textures: avfRegistrar.textures,
        messenger: avfRegistrar.messenger)
      objc_setAssociatedObject(
        controller, &avfPluginKey, avfVideo, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

      // The FFmpeg-in-engine texture bridge, likewise pinned to the sub-window
      // so a pop-out can run the FFmpeg backend's zero-copy HW path.
      let ffmpegRegistrar = controller.registrar(forPlugin: "FfmpegVideo")
      let ffmpegVideo = FfmpegVideoPlugin(
        textures: ffmpegRegistrar.textures,
        messenger: ffmpegRegistrar.messenger)
      objc_setAssociatedObject(
        controller, &ffmpegPluginKey, ffmpegVideo,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
