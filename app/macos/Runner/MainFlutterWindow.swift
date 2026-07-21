import Cocoa
import AVFoundation
import ApplicationServices
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let capabilities = FlutterMethodChannel(
      name: "omi/core_capabilities",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    capabilities.setMethodCallHandler { call, rawResult in
      var completed = false
      let result: FlutterResult = { value in
        DispatchQueue.main.async {
          guard !completed else { return }
          completed = true
          rawResult(value)
        }
      }
      switch call.method {
      case "check":
        result([
          "accessibility": AXIsProcessTrusted(),
          "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
          "screenCapture": CGPreflightScreenCaptureAccess(),
        ])
      case "request":
        guard let capability = call.arguments as? String else {
          result(FlutterError(code: "invalid_capability", message: nil, details: nil))
          return
        }
        switch capability {
        case "accessibility":
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
          AXIsProcessTrustedWithOptions(options as CFDictionary)
          result(nil)
        case "microphone":
          AVCaptureDevice.requestAccess(for: .audio) { _ in result(nil) }
        case "screenCapture":
          CGRequestScreenCaptureAccess()
          result(nil)
        default:
          result(FlutterError(code: "invalid_capability", message: nil, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
