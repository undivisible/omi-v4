import CoreGraphics
import CoreImage
import Cocoa
import FlutterMacOS
import Vision

/// The native half of Rewind. It does three things and nothing else: report
/// what is on screen, hand Dart a tiny luminance preview while keeping the
/// full frame in memory, and — only when Dart asks — encode that held frame to
/// JPEG and read its text with Apple's Vision framework, on-device.
///
/// The split matters. Encoding is the expensive part of continuous capture, so
/// the encoder is never run for a frame the policy is going to discard, and a
/// frame that is discarded is released without ever becoming bytes.
@MainActor
final class RewindCaptureBridge: NSObject {
  private let channel: FlutterMethodChannel
  private let context = CIContext(options: [.useSoftwareRenderer: false])
  private var heldFrame: CGImage?
  private var statusItem: NSStatusItem?
  private var recording = false
  private var paused = false
  private var screenLocked = false
  private var systemAsleep = false

  /// Nine by eight luminance samples: the difference-hash grid. Derived from a
  /// downscale of roughly eighty pixels wide, which is small enough that the
  /// similarity check costs nothing next to a full-frame encode.
  private static let previewWidth = 9
  private static let previewHeight = 8

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "omi/rewind_capture", binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "state":
        result(self.state())
      case "preview":
        result(self.preview())
      case "encodeHeldFrame":
        let arguments = call.arguments as? [String: Any]
        let recognize = arguments?["recognizeText"] as? Bool ?? true
        self.encodeHeldFrame(recognizeText: recognize, result: result)
      case "discardHeldFrame":
        self.heldFrame = nil
        result(nil)
      case "indicator":
        let arguments = call.arguments as? [String: Any]
        self.recording = arguments?["recording"] as? Bool ?? false
        self.paused = arguments?["paused"] as? Bool ?? false
        self.renderIndicator()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    observeSessionEvents()
  }

  // MARK: - Screen lock and sleep

  /// Capture stops entirely while the screen is locked or the machine is
  /// asleep. Both are observed rather than polled, so the pause takes effect
  /// on the same runloop turn as the lock.
  private func observeSessionEvents() {
    let distributed = DistributedNotificationCenter.default()
    distributed.addObserver(
      self, selector: #selector(screenDidLock),
      name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    distributed.addObserver(
      self, selector: #selector(screenDidUnlock),
      name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(
      self, selector: #selector(systemWillSleep),
      name: NSWorkspace.willSleepNotification, object: nil)
    workspace.addObserver(
      self, selector: #selector(systemDidWake),
      name: NSWorkspace.didWakeNotification, object: nil)
    workspace.addObserver(
      self, selector: #selector(systemWillSleep),
      name: NSWorkspace.screensDidSleepNotification, object: nil)
    workspace.addObserver(
      self, selector: #selector(systemDidWake),
      name: NSWorkspace.screensDidWakeNotification, object: nil)
  }

  @objc private func screenDidLock() {
    screenLocked = true
    heldFrame = nil
  }

  @objc private func screenDidUnlock() { screenLocked = false }

  @objc private func systemWillSleep() {
    systemAsleep = true
    heldFrame = nil
  }

  @objc private func systemDidWake() { systemAsleep = false }

  // MARK: - State

  private func state() -> [String: Any] {
    let frontmost = NSWorkspace.shared.frontmostApplication
    var payload: [String: Any] = [
      "idleSeconds": Self.idleSeconds(),
      "locked": screenLocked || systemAsleep,
      "permitted": CGPreflightScreenCaptureAccess(),
    ]
    if let bundleId = frontmost?.bundleIdentifier { payload["bundleId"] = bundleId }
    if let name = frontmost?.localizedName { payload["appName"] = name }
    if let title = Self.frontmostWindowTitle(pid: frontmost?.processIdentifier) {
      payload["windowTitle"] = title
    }
    return payload
  }

  private static func idleSeconds() -> Double {
    let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
    return types
      .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
      .min() ?? 0
  }

  /// Reads the frontmost window's title through the accessibility API. Titles
  /// are the only signal that distinguishes a private browsing window from an
  /// ordinary one, so this is a privacy input, not a nicety. Returns nil
  /// whenever accessibility is not granted.
  private static func frontmostWindowTitle(pid: pid_t?) -> String? {
    guard let pid, AXIsProcessTrusted() else { return nil }
    let application = AXUIElementCreateApplication(pid)
    var window: AnyObject?
    guard
      AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window)
        == .success,
      let window
    else { return nil }
    var title: AnyObject?
    guard
      AXUIElementCopyAttributeValue(
        window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
      let value = title as? String,
      !value.isEmpty
    else { return nil }
    return value
  }

  // MARK: - Capture

  private func preview() -> FlutterStandardTypedData? {
    heldFrame = nil
    guard !screenLocked, !systemAsleep, CGPreflightScreenCaptureAccess() else { return nil }
    guard let image = Self.captureMainDisplay() else { return nil }
    heldFrame = image
    guard let luma = Self.lumaPreview(image) else { return nil }
    return FlutterStandardTypedData(bytes: luma)
  }

  private static func captureMainDisplay() -> CGImage? {
    CGDisplayCreateImage(CGMainDisplayID())
  }

  /// Downsamples to the 9x8 difference-hash grid in one draw, straight from
  /// the CGImage. Nothing is encoded and nothing is written.
  private static func lumaPreview(_ image: CGImage) -> Data? {
    let width = previewWidth
    let height = previewHeight
    var buffer = [UInt8](repeating: 0, count: width * height)
    guard
      let space = CGColorSpace(name: CGColorSpace.linearGray),
      let context = CGContext(
        data: &buffer, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Data(buffer)
  }

  private func encodeHeldFrame(recognizeText: Bool, result: @escaping FlutterResult) {
    guard let image = heldFrame else {
      result(nil)
      return
    }
    heldFrame = nil
    let context = self.context
    DispatchQueue.global(qos: .utility).async {
      guard let jpeg = Self.jpeg(image, context: context) else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let text = recognizeText ? Self.recognizeText(image) : nil
      var payload: [String: Any] = ["jpeg": FlutterStandardTypedData(bytes: jpeg)]
      if let text, !text.isEmpty { payload["text"] = text }
      DispatchQueue.main.async { result(payload) }
    }
  }

  private nonisolated static func jpeg(_ image: CGImage, context: CIContext) -> Data? {
    let ciImage = CIImage(cgImage: image)
    return context.jpegRepresentation(
      of: ciImage,
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5])
  }

  /// On-device text recognition. Vision ships with macOS, runs locally, and
  /// costs nothing per frame — which is what makes it possible to keep the
  /// images on this machine and still have a searchable timeline.
  private nonisolated static func recognizeText(_ image: CGImage) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return nil
    }
    let lines = (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .filter { !$0.isEmpty }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  // MARK: - Indicator

  /// The always-visible proof that Rewind is on. It is a menu bar item, not a
  /// panel the user can lose behind a window, and its first menu entry is the
  /// one-click pause.
  private func renderIndicator() {
    guard recording else {
      if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
      statusItem = nil
      return
    }
    if statusItem == nil {
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
    let symbol = paused ? "pause.circle" : "record.circle"
    let description = paused ? "Rewind paused" : "Rewind is recording your screen"
    statusItem?.button?.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: description)
    statusItem?.button?.toolTip = description

    let menu = NSMenu()
    let status = NSMenuItem(title: description, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())
    let toggle = NSMenuItem(
      title: paused ? "Resume Rewind" : "Pause Rewind",
      action: #selector(togglePause), keyEquivalent: "")
    toggle.target = self
    menu.addItem(toggle)
    let stop = NSMenuItem(
      title: "Turn Rewind off", action: #selector(disableRewind), keyEquivalent: "")
    stop.target = self
    menu.addItem(stop)
    statusItem?.menu = menu
  }

  @objc private func togglePause() {
    channel.invokeMethod(paused ? "resume" : "pause", arguments: nil)
  }

  @objc private func disableRewind() {
    channel.invokeMethod("disable", arguments: nil)
  }
}
