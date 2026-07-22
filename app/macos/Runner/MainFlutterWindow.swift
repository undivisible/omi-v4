import Cocoa
import Carbon.HIToolbox
import FlutterMacOS

private class OvalBlurView: NSView {
  private let shell = NSView()
  private let effect = NSVisualEffectView()
  private var maskSize = NSSize.zero

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
    guard shell.bounds.size != maskSize, shell.bounds.width > 0, shell.bounds.height > 0 else { return }
    maskSize = shell.bounds.size
    shell.layer?.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 0.8).cgColor
    let mask = NSImage(size: maskSize, flipped: false) { bounds in
      guard
        let gradient = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceGray(),
          colors: [
            CGColor(gray: 1, alpha: 1),
            CGColor(gray: 1, alpha: 0.95),
            CGColor(gray: 1, alpha: 0.72),
            CGColor(gray: 1, alpha: 0.32),
            CGColor(gray: 1, alpha: 0),
          ] as CFArray,
          locations: [0, 0.32, 0.58, 0.8, 1]
        )
      else { return false }
      let context = NSGraphicsContext.current!.cgContext
      context.translateBy(x: bounds.midX, y: bounds.midY)
      context.scaleBy(x: bounds.width / 2, y: bounds.height / 2)
      context.drawRadialGradient(
        gradient,
        startCenter: .zero,
        startRadius: 0,
        endCenter: .zero,
        endRadius: 1,
        options: [.drawsAfterEndLocation])
      return true
    }
    effect.maskImage = mask
    let fillMask = CALayer()
    fillMask.frame = shell.bounds
    var proposedRect = NSRect(origin: .zero, size: maskSize)
    fillMask.contents = mask.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    shell.layer?.mask = fillMask
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
  private var restartTimer: Timer?
  private let restart: () -> Void
  private let restartButton = NSButton(title: "Restart Omi", target: nil, action: nil)

  init(
    frame frameRect: NSRect,
    appBundleURL: URL,
    restart: @escaping () -> Void
  ) {
    self.restart = restart
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]

    let blur = OvalBlurView(frame: bounds, blendingMode: .withinWindow)
    blur.autoresizingMask = [.width, .height]
    addSubview(blur)

    let title = NSTextField(labelWithString: "Drag this shortcut into Settings")
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    title.textColor = .white
    title.alignment = .center

    let icon = ShortcutDragView(shortcutURL: appBundleURL)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 112),
      icon.heightAnchor.constraint(equalToConstant: 112),
    ])

    restartButton.target = self
    restartButton.action = #selector(restartPressed)
    restartButton.isBordered = false
    restartButton.font = .systemFont(ofSize: 14, weight: .medium)
    restartButton.contentTintColor = .white
    restartButton.alphaValue = 0
    restartButton.isHidden = true

    let stack = NSStackView(views: [title, icon, restartButton])
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

  @objc private func restartPressed() {
    restart()
  }

  override func mouseDown(with event: NSEvent) {
    dismiss()
  }

  func show() {
    alphaValue = 0
    isHidden = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.35
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
    restartTimer?.invalidate()
    restartButton.alphaValue = 0
    restartButton.isHidden = true
    let restartTimer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
      guard let self else { return }
      restartButton.isHidden = false
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.35
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.restartButton.animator().alphaValue = 1
      }
    }
    self.restartTimer = restartTimer
    RunLoop.main.add(restartTimer, forMode: .common)
  }

  func dismiss() {
    guard !isHidden else { return }
    restartTimer?.invalidate()
    restartTimer = nil
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      self?.isHidden = true
    }
  }

}

class MainFlutterWindow: NSWindow, FlutterStreamHandler {
  private var eventKitBridge: AppleEventKitBridge?
  private var menuBarBridge: MenuBarBridge?
  private var voicePlayoutBridge: VoicePlayoutBridge?
  private var keyboardSink: FlutterEventSink?
  private var localKeyboardMonitor: Any?
  private var globalKeyboardMonitor: Any?
  private let permissionService = MacPermissionService()
  private var permissionOverlay: PermissionDragOverlay?
  private var windowChromeChannel: FlutterMethodChannel?
  private var pillPreviousFrame: NSRect?
  private var pillPreviousLevel: NSWindow.Level = .normal
  private var pillPreviousCollectionBehavior: NSWindow.CollectionBehavior = []
  private var pillLocalMouseMonitor: Any?
  private var pillGlobalMouseMonitor: Any?

  func requestSettings() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    windowChromeChannel?.invokeMethod("openSettings", arguments: nil)
  }

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
      permissionOverlay?.dismiss()
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
    self.alphaValue = 0
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
      appBundleURL: permissionService.bundleURL
    ) { [weak self] in
      self?.restart()
    }
    rootView.addSubview(permissionOverlay)
    self.permissionOverlay = permissionOverlay

    RegisterGeneratedPlugins(registry: flutterViewController)
    eventKitBridge = AppleEventKitBridge(binaryMessenger: flutterViewController.engine.binaryMessenger)
    menuBarBridge = MenuBarBridge(binaryMessenger: flutterViewController.engine.binaryMessenger, window: self)
    voicePlayoutBridge = VoicePlayoutBridge(binaryMessenger: flutterViewController.engine.binaryMessenger)

    let capabilities = FlutterMethodChannel(
      name: "omi/core_capabilities",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    capabilities.setMethodCallHandler { [weak self] call, rawResult in
      var completed = false
      let result: FlutterResult = { value in
        DispatchQueue.main.async {
          guard !completed else { return }
          completed = true
          rawResult(value)
        }
      }
      guard let self else {
        result(FlutterError(code: "window_unavailable", message: nil, details: nil))
        return
      }
      switch call.method {
      case "check":
        result(self.permissionService.rawSnapshot())
      case "promptAccessibility":
        self.permissionService.promptAccessibility()
        result(nil)
      case "requestMicrophone":
        self.permissionService.requestMicrophone { result(nil) }
      case "promptScreenCapture":
        self.permissionService.promptScreenCapture()
        result(nil)
      case "openSettingsPane":
        guard
          let pane = call.arguments as? String,
          self.permissionService.openPrivacyPane(pane)
        else {
          result(FlutterError(code: "invalid_pane", message: nil, details: nil))
          return
        }
        result(nil)
      case "showOverlay":
        self.permissionOverlay?.show()
        result(nil)
      case "dismissOverlay":
        self.permissionOverlay?.dismiss()
        result(nil)
      case "restart":
        self.restart()
        result(nil)
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

    let windowChrome = FlutterMethodChannel(
      name: "omi/window_chrome",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChrome.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "enterHub":
        self?.enterHubChrome()
        result(nil)
      case "enterOnboarding":
        self?.enterOnboardingChrome()
        result(nil)
      case "summonPill":
        let arguments = call.arguments as? [String: Any]
        self?.summonPill(
          width: arguments?["width"] as? Double ?? 420,
          height: arguments?["height"] as? Double ?? 230)
        result(nil)
      case "restoreFromPill":
        self?.restoreFromPill()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChromeChannel = windowChrome

    super.awakeFromNib()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.45
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      self.animator().alphaValue = 1
    }
  }

  deinit {
    if let localKeyboardMonitor { NSEvent.removeMonitor(localKeyboardMonitor) }
    if let globalKeyboardMonitor { NSEvent.removeMonitor(globalKeyboardMonitor) }
    stopFollowingCursor()
  }

  private func enterHubChrome() {
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = true
    hasShadow = true
    level = .normal
    collectionBehavior = [.fullScreenAuxiliary]
  }

  private func enterOnboardingChrome() {
    styleMask = [.borderless, .resizable, .miniaturizable]
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = false
    hasShadow = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  private func pillFrame(cursor: NSPoint, width: Double, height: Double) -> NSRect {
    var target = NSRect(
      x: cursor.x + 18,
      y: cursor.y - height - 18,
      width: width,
      height: height)
    let screen =
      NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }
      ?? NSScreen.main
    if let visible = screen?.visibleFrame {
      target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - width)
      target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - height)
    }
    return target
  }

  private func followCursor(width: Double, height: Double) {
    let reposition: (NSPoint) -> Void = { [weak self] cursor in
      guard let self else { return }
      self.setFrameOrigin(self.pillFrame(cursor: cursor, width: width, height: height).origin)
    }
    pillLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved]
    ) { event in
      reposition(NSEvent.mouseLocation)
      return event
    }
    pillGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.mouseMoved]
    ) { _ in reposition(NSEvent.mouseLocation) }
  }

  private func stopFollowingCursor() {
    if let pillLocalMouseMonitor { NSEvent.removeMonitor(pillLocalMouseMonitor) }
    if let pillGlobalMouseMonitor { NSEvent.removeMonitor(pillGlobalMouseMonitor) }
    pillLocalMouseMonitor = nil
    pillGlobalMouseMonitor = nil
  }

  private func summonPill(width: Double, height: Double) {
    if pillPreviousFrame == nil {
      pillPreviousFrame = frame
      pillPreviousLevel = level
      pillPreviousCollectionBehavior = collectionBehavior
    }
    let target = pillFrame(cursor: NSEvent.mouseLocation, width: width, height: height)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    setFrame(target, display: true)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    stopFollowingCursor()
    followCursor(width: width, height: height)
  }

  private func restoreFromPill() {
    stopFollowingCursor()
    guard let previousFrame = pillPreviousFrame else { return }
    pillPreviousFrame = nil
    level = pillPreviousLevel
    collectionBehavior = pillPreviousCollectionBehavior
    setFrame(previousFrame, display: true)
  }

  private func restart() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL,
      configuration: configuration
    ) { application, _ in
      if application != nil {
        DispatchQueue.main.async { NSApp.terminate(nil) }
      }
    }
  }

}
