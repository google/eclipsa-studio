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

// Atomic file replacement for session saves (ES-840), on the
// `eclipsa/atomic_file` method channel.
//
// A sandboxed app that got a file from the Save panel holds a grant to
// that file alone, so it cannot create a temp file beside it and rename
// it over the original. Foundation's atomic write (`Data.write` with
// `.atomic`) stages the new contents where the sandbox allows it and
// replaces the file in one step, so an interrupted save leaves the
// previous file intact.

import Cocoa
import FlutterMacOS

final class AtomicFilePlugin: NSObject {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "eclipsa/atomic_file", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { call, result in
      AtomicFilePlugin.handle(call, result)
    }
  }

  private static func handle(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard call.method == "write" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      let bytes = args["bytes"] as? FlutterStandardTypedData
    else {
      result(
        FlutterError(
          code: "bad_args", message: "path and bytes are required",
          details: nil))
      return
    }
    do {
      try bytes.data.write(to: URL(fileURLWithPath: path), options: .atomic)
      result(nil)
    } catch let error as NSError {
      // The Dart side falls back to an in-place write only for a
      // permission failure; anything else (a full disk) must leave the
      // previous file alone.
      let denied = AtomicFilePlugin.isPermissionDenial(error)
      result(
        FlutterError(
          code: denied ? "no_permission" : "write_failed",
          message: error.localizedDescription, details: nil))
    }
  }

  /// A sandbox refusal can surface as NSFileWriteNoPermissionError or as
  /// a generic write error whose underlying POSIX error is EPERM or
  /// EACCES.
  private static func isPermissionDenial(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain
      && error.code == NSFileWriteNoPermissionError
    {
      return true
    }
    if error.domain == NSPOSIXErrorDomain
      && (error.code == Int(EPERM) || error.code == Int(EACCES))
    {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isPermissionDenial(underlying)
    }
    return false
  }
}
