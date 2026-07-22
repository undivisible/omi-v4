import Cocoa
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import FlutterMacOS

private final class OnboardingBlurView: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class AppBundleDragView: NSImageView, NSDraggingSource {
  private let appURL: URL

  init(appURL: URL) {
    self.appURL = appURL
    super.init(frame: .zero)
    image = NSWorkspace.shared.icon(forFile: appURL.path)
    imageScaling = .scaleProportionallyUpOrDown
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDragged(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }
}

private final class FullDiskAccessDragOverlay: NSVisualEffectView {
  init(frame frameRect: NSRect, appURL: URL) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]
    material = .hudWindow
    blendingMode = .withinWindow
    state = .active

    let title = NSTextField(labelWithString: "Drag into Settings")
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    title.textColor = .white
    title.alignment = .center

    let icon = AppBundleDragView(appURL: appURL)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 112),
      icon.heightAnchor.constraint(equalToConstant: 112),
    ])

    let stack = NSStackView(views: [title, icon])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 22
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) {
    hide()
  }

  func show() {
    alphaValue = 0
    isHidden = false
    animator().alphaValue = 1
  }

  func hide() {
    isHidden = true
  }
}

class MainFlutterWindow: NSWindow, FlutterStreamHandler {
  private var eventKitBridge: AppleEventKitBridge?
  private var menuBarBridge: MenuBarBridge?
  private var keyboardSink: FlutterEventSink?
  private var localKeyboardMonitor: Any?
  private var globalKeyboardMonitor: Any?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    keyboardSink = events
    emitSecureInput()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    keyboardSink = nil
    return nil
  }

  private func keyboardEvent(_ event: NSEvent) {
    emitSecureInput()
    if IsSecureEventInputEnabled() { return }
    if event.type == .keyDown && event.keyCode == 53 {
      keyboardSink?(["type": "escape"])
      return
    }
    guard event.type == .flagsChanged, event.keyCode == 56 || event.keyCode == 60 else { return }
    keyboardSink?([
      "type": "shift",
      "key": event.keyCode == 56 ? "left" : "right",
      "pressed": CGEventSource.keyState(.combinedSessionState, key: event.keyCode),
    ])
  }

  private func emitSecureInput() {
    keyboardSink?(["type": "secureInput", "enabled": IsSecureEventInputEnabled()])
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.styleMask = [.borderless, .resizable, .miniaturizable]
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.isMovableByWindowBackground = false
    self.level = .floating
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    flutterViewController.backgroundColor = .clear
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor

    let rootViewController = NSViewController()
    let rootView = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor.clear.cgColor
    rootViewController.view = rootView
    rootViewController.addChild(flutterViewController)
    self.contentViewController = rootViewController
    self.setFrame(windowFrame, display: true)

    let blur = OnboardingBlurView(frame: rootView.bounds)
    blur.autoresizingMask = [.width, .height]
    blur.material = .underWindowBackground
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.alphaValue = 0
    flutterViewController.view.frame = rootView.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    rootView.addSubview(blur)
    rootView.addSubview(flutterViewController.view)
    let fullDiskAccessOverlay = FullDiskAccessDragOverlay(
      frame: rootView.bounds,
      appURL: Bundle.main.bundleURL)
    rootView.addSubview(fullDiskAccessOverlay)

    RegisterGeneratedPlugins(registry: flutterViewController)
    eventKitBridge = AppleEventKitBridge(binaryMessenger: flutterViewController.engine.binaryMessenger)
    menuBarBridge = MenuBarBridge(binaryMessenger: flutterViewController.engine.binaryMessenger, window: self)

    let windowEffects = FlutterMethodChannel(
      name: "omi/window_effects",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowEffects.setMethodCallHandler { call, result in
      guard call.method == "setOnboardingBlur", let enabled = call.arguments as? Bool else {
        result(FlutterMethodNotImplemented)
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 2.5
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        blur.animator().alphaValue = enabled ? 0.72 : 0
      }
      result(nil)
    }

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
        let fullDiskAccess = self.hasFullDiskAccess()
        if fullDiskAccess { fullDiskAccessOverlay.hide() }
        result([
          "accessibility": AXIsProcessTrusted(),
          "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
          "screenCapture": CGPreflightScreenCaptureAccess(),
          "fullDiskAccess": fullDiskAccess,
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
        case "appData":
          fullDiskAccessOverlay.show()
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
          result(nil)
        default:
          result(FlutterError(code: "invalid_capability", message: nil, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let keyboard = FlutterEventChannel(
      name: "omi/desktop_keyboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    keyboard.setStreamHandler(self)
    let keyboardControl = FlutterMethodChannel(
      name: "omi/desktop_keyboard_control",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    keyboardControl.setMethodCallHandler { [weak self] call, result in
      guard call.method == "focus" else {
        result(FlutterMethodNotImplemented)
        return
      }
      NSApp.activate(ignoringOtherApps: true)
      self?.makeKeyAndOrderFront(nil)
      result(nil)
    }
    localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown]
    ) { [weak self] event in
      self?.keyboardEvent(event)
      return event
    }
    globalKeyboardMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.flagsChanged, .keyDown]
    ) { [weak self] event in self?.keyboardEvent(event) }

    super.awakeFromNib()
  }

  deinit {
    if let localKeyboardMonitor { NSEvent.removeMonitor(localKeyboardMonitor) }
    if let globalKeyboardMonitor { NSEvent.removeMonitor(globalKeyboardMonitor) }
  }

  private func hasFullDiskAccess() -> Bool {
    let mail = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mail")
    do {
      _ = try FileManager.default.contentsOfDirectory(
        at: mail,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      return true
    } catch {
      return false
    }
  }

}
