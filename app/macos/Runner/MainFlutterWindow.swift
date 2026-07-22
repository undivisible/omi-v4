import Cocoa
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import FlutterMacOS

private class OvalBlurView: NSView {
  private let shell = NSView()
  private let effect = NSVisualEffectView()

  init(frame frameRect: NSRect, blendingMode: NSVisualEffectView.BlendingMode) {
    super.init(frame: frameRect)
    shell.wantsLayer = true
    shell.translatesAutoresizingMaskIntoConstraints = false
    effect.wantsLayer = true
    effect.material = .hudWindow
    effect.blendingMode = blendingMode
    effect.isEmphasized = true
    effect.state = .active
    effect.translatesAutoresizingMaskIntoConstraints = false
    shell.addSubview(effect)
    addSubview(shell)
    NSLayoutConstraint.activate([
      shell.centerXAnchor.constraint(equalTo: centerXAnchor),
      shell.centerYAnchor.constraint(equalTo: centerYAnchor),
      shell.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.88),
      shell.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.76),
      effect.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
      effect.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
      effect.topAnchor.constraint(equalTo: shell.topAnchor),
      effect.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    let radius = shell.bounds.height / 2
    shell.layer?.cornerRadius = radius
    shell.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
    shell.layer?.shadowColor = NSColor.black.withAlphaComponent(0.2).cgColor
    shell.layer?.shadowOpacity = 1
    shell.layer?.shadowRadius = 56
    shell.layer?.shadowOffset = .zero
    effect.layer?.cornerRadius = radius
    effect.layer?.masksToBounds = true
  }
}

private final class OnboardingBlurView: OvalBlurView {
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

private final class PermissionDragOverlay: NSView {
  private var capability: String?

  init(frame frameRect: NSRect, shortcutURL: URL) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]

    let blur = OvalBlurView(frame: bounds, blendingMode: .withinWindow)
    blur.autoresizingMask = [.width, .height]
    addSubview(blur)

    let title = NSTextField(labelWithString: "Drag this shortcut into Settings")
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

  func show(for capability: String) {
    self.capability = capability
    alphaValue = 0
    isHidden = false
    animator().alphaValue = 1
  }

  func hideIfGranted(
    accessibility: Bool,
    screenCapture: Bool,
    fullDiskAccess: Bool
  ) {
    let granted = switch capability {
    case "accessibility": accessibility
    case "screenCapture": screenCapture
    case "appData": fullDiskAccess
    default: false
    }
    if granted {
      capability = nil
      isHidden = true
    }
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

    let blur = OnboardingBlurView(frame: rootView.bounds, blendingMode: .behindWindow)
    blur.autoresizingMask = [.width, .height]
    flutterViewController.view.frame = rootView.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]
    rootView.addSubview(blur)
    rootView.addSubview(flutterViewController.view)
    let permissionOverlay = PermissionDragOverlay(
      frame: rootView.bounds,
      shortcutURL: fullDiskAccessShortcut())
    rootView.addSubview(permissionOverlay)

    RegisterGeneratedPlugins(registry: flutterViewController)
    eventKitBridge = AppleEventKitBridge(binaryMessenger: flutterViewController.engine.binaryMessenger)
    menuBarBridge = MenuBarBridge(binaryMessenger: flutterViewController.engine.binaryMessenger, window: self)

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
        let accessibility = AXIsProcessTrusted()
        let screenCapture = CGPreflightScreenCaptureAccess()
        let fullDiskAccess = self.hasFullDiskAccess()
        permissionOverlay.hideIfGranted(
          accessibility: accessibility,
          screenCapture: screenCapture,
          fullDiskAccess: fullDiskAccess)
        result([
          "accessibility": accessibility,
          "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
          "screenCapture": screenCapture,
          "fullDiskAccess": fullDiskAccess,
        ])
      case "request":
        guard let capability = call.arguments as? String else {
          result(FlutterError(code: "invalid_capability", message: nil, details: nil))
          return
        }
        switch capability {
        case "accessibility":
          permissionOverlay.show(for: capability)
          let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
          AXIsProcessTrustedWithOptions(options as CFDictionary)
          self.openPrivacyPane("Privacy_Accessibility")
          result(nil)
        case "microphone":
          AVCaptureDevice.requestAccess(for: .audio) { _ in result(nil) }
        case "screenCapture":
          permissionOverlay.show(for: capability)
          CGRequestScreenCaptureAccess()
          self.openPrivacyPane("Privacy_ScreenCapture")
          result(nil)
        case "appData":
          permissionOverlay.show(for: capability)
          self.openPrivacyPane("Privacy_AllFiles")
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

  private func openPrivacyPane(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
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
