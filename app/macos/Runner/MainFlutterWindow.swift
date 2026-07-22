import Cocoa
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import FlutterMacOS

private class RadialBlurView: NSVisualEffectView {
  private var maskSize = NSSize.zero

  override func layout() {
    super.layout()
    guard bounds.size != maskSize, bounds.width > 0, bounds.height > 0 else { return }
    maskSize = bounds.size
    let mask = NSImage(size: bounds.size)
    mask.lockFocus()
    NSGradient(
      colorsAndLocations:
        (NSColor.black, 0),
        (NSColor.black, 0.42),
        (NSColor.black.withAlphaComponent(0.72), 0.62),
        (NSColor.clear, 1)
    )?.draw(
      in: NSRect(
        x: bounds.width * 0.06,
        y: bounds.height * 0.12,
        width: bounds.width * 0.88,
        height: bounds.height * 0.76),
      relativeCenterPosition: .zero)
    mask.unlockFocus()
    maskImage = mask
  }
}

private final class OnboardingBlurView: RadialBlurView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ShortcutDragView: NSImageView, NSDraggingSource {
  private let shortcutURL: URL

  init(shortcutURL: URL) {
    self.shortcutURL = shortcutURL
    super.init(frame: .zero)
    image = NSWorkspace.shared.icon(forFile: shortcutURL.path)
    imageScaling = .scaleProportionallyUpOrDown
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDragged(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: shortcutURL as NSURL)
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

private final class FullDiskAccessDragOverlay: RadialBlurView {
  init(frame frameRect: NSRect, shortcutURL: URL) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]
    material = .underWindowBackground
    blendingMode = .withinWindow
    state = .active

    let title = NSTextField(labelWithString: "Drag into Settings")
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    title.textColor = .white
    title.alignment = .center

    let icon = ShortcutDragView(shortcutURL: shortcutURL)
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
      shortcutURL: fullDiskAccessShortcut())
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

  private func fullDiskAccessShortcut() -> URL {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(
      "com.omi.permission-shortcut",
      isDirectory: true)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let shortcut = directory.appendingPathComponent("Omi — drag into Settings.app")
    if (try? manager.destinationOfSymbolicLink(atPath: shortcut.path)) != nil {
      try? manager.removeItem(at: shortcut)
    }
    if !manager.fileExists(atPath: shortcut.path) {
      try? manager.createSymbolicLink(at: shortcut, withDestinationURL: Bundle.main.bundleURL)
    }
    return manager.fileExists(atPath: shortcut.path) ? shortcut : Bundle.main.bundleURL
  }

}
