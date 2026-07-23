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

/// Native Liquid Glass backing for the cursor pill. On macOS 26+ this hosts
/// the real NSGlassEffectView (looked up dynamically so older SDKs still
/// build); earlier systems fall back to a behind-window NSVisualEffectView.
/// The glass is masked to the pill's rounded-rect regions, which Dart
/// reports through the omi/window_chrome channel so the native shape always
/// matches the Flutter layout above it.
private final class PillGlassView: NSView {
  private let glass: NSView
  private let maskLayer = CAShapeLayer()

  override init(frame frameRect: NSRect) {
    if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
      glass = glassClass.init(frame: frameRect)
    } else {
      let effect = NSVisualEffectView(frame: frameRect)
      effect.material = .hudWindow
      effect.blendingMode = .behindWindow
      effect.state = .active
      effect.isEmphasized = true
      glass = effect
    }
    super.init(frame: frameRect)
    wantsLayer = true
    glass.wantsLayer = true
    glass.autoresizingMask = [.width, .height]
    glass.frame = bounds
    addSubview(glass)
    layer?.mask = maskLayer
    maskLayer.fillRule = .evenOdd
    setRegions([], radius: 18)
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func setRegions(_ regions: [(rect: CGRect, radius: CGFloat)], radius fallback: CGFloat) {
    let path = CGMutablePath()
    for region in regions {
      let radius = min(region.radius > 0 ? region.radius : fallback,
                       min(region.rect.width, region.rect.height) / 2)
      path.addRoundedRect(in: region.rect, cornerWidth: radius, cornerHeight: radius)
    }
    maskLayer.frame = bounds
    maskLayer.fillRule = .nonZero
    maskLayer.path = path
  }
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
  private var pillPreviousFrame: NSRect?
  private var pillPreviousLevel: NSWindow.Level = .normal
  private var pillPreviousCollectionBehavior: NSWindow.CollectionBehavior = []
  private var pillGlassView: PillGlassView?
  private weak var hostContentView: NSView?
  private weak var flutterContentView: NSView?
  private weak var onboardingBlurView: NSView?
  private var pillPreviousBlurHidden = true

  func requestSettings() {
    SettingsWindowController.show()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// Key code for the global overlay keybind (49 = Space, combined with a
  /// bare Option modifier). Single source of truth on the native side.
  static let summonOverlayKeyCode: UInt16 = 49

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
    // Global keybind for the centered text overlay (Option+Space). Changeable
    // here and mirrored in Dart as `summonOverlayKeybindLabel`. Bare Option
    // only — Command/Control/Shift combos are left to other apps.
    if event.type == .keyDown && event.keyCode == Self.summonOverlayKeyCode {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if flags == .option {
        keyboardSink?(["type": "summonOverlay"])
        return
      }
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
    onboardingBlurView = blur
    hostContentView = rootView
    flutterContentView = flutterViewController.view
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
      case "openSettings":
        SettingsWindowController.show()
        result(nil)
      case "enterOnboarding":
        self?.enterOnboardingChrome()
        result(nil)
      case "summonPill":
        let arguments = call.arguments as? [String: Any]
        self?.summonPill(
          width: arguments?["width"] as? Double ?? 420,
          height: arguments?["height"] as? Double ?? 230,
          centered: arguments?["centered"] as? Bool ?? false)
        result(nil)
      case "restoreFromPill":
        self?.restoreFromPill()
        result(nil)
      case "updatePillGlass":
        let arguments = call.arguments as? [String: Any]
        self?.updatePillGlass(
          regions: arguments?["regions"] as? [[String: Any]] ?? [],
          radius: arguments?["radius"] as? Double ?? 18)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

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
  }

  private func enterHubChrome() {
    // The onboarding backdrop must never bleed into the hub (or the pill):
    // its grey radial-gradient blur shows through wherever Flutter is
    // transparent.
    onboardingBlurView?.isHidden = true
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    // Mutating styleMask rebuilds the theme frame, which can bring back the
    // default titlebar chrome — re-assert every property that keeps the bar
    // invisible so only the floating traffic lights remain over content.
    toolbar = nil
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    titlebarSeparatorStyle = .none
    isOpaque = false
    backgroundColor = .clear
    isMovableByWindowBackground = true
    hasShadow = true
    level = .normal
    collectionBehavior = [.fullScreenAuxiliary]
    invalidateShadow()
  }

  private func enterOnboardingChrome() {
    onboardingBlurView?.isHidden = false
    styleMask = [.borderless, .resizable, .miniaturizable]
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = false
    hasShadow = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  private static var activeScreen: NSScreen? {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
  }

  /// The full-screen voice overlay covers the active screen edge to edge so
  /// the waveform and its glow can hug the screen borders.
  static func voiceOverlayFrame(for screen: NSScreen?) -> NSRect {
    screen?.frame ?? .zero
  }

  static func centeredPillFrame(
    width: Double, height: Double, visible: NSRect
  ) -> NSRect {
    // Spotlight-style: horizontally centered, pinned to the upper third.
    let x = visible.midX - width / 2
    let y = visible.maxY - visible.height * 0.28 - height
    return NSRect(x: x, y: y, width: width, height: height)
  }

  func summonPill(width: Double, height: Double, centered: Bool) {
    if pillPreviousFrame == nil {
      pillPreviousFrame = frame
      pillPreviousLevel = level
      pillPreviousCollectionBehavior = collectionBehavior
      pillPreviousBlurHidden = onboardingBlurView?.isHidden ?? true
    }
    // Only the native Liquid Glass may render behind the pill — the
    // onboarding blur otherwise shows as a grey gradient wash inside the
    // summoned window.
    onboardingBlurView?.isHidden = true
    let screen = Self.activeScreen
    let target = centered
      ? Self.centeredPillFrame(
          width: width, height: height,
          visible: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: width, height: height))
      : Self.voiceOverlayFrame(for: screen)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // Voice is click-through: the full-screen overlay must never swallow
    // clicks meant for whatever the user is working in beneath it.
    ignoresMouseEvents = !centered
    setFrame(target, display: true)
    attachPillGlass()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func attachPillGlass() {
    guard pillGlassView == nil, let host = hostContentView else { return }
    let glass = PillGlassView(frame: host.bounds)
    glass.autoresizingMask = [.width, .height]
    if let flutterView = flutterContentView {
      host.addSubview(glass, positioned: .below, relativeTo: flutterView)
    } else {
      host.addSubview(glass)
    }
    pillGlassView = glass
  }

  private func updatePillGlass(regions: [[String: Any]], radius: Double) {
    guard pillPreviousFrame != nil else { return }
    attachPillGlass()
    let parsed: [(rect: CGRect, radius: CGFloat)] = regions.compactMap { region in
      guard
        let x = region["x"] as? Double,
        let y = region["y"] as? Double,
        let width = region["w"] as? Double,
        let height = region["h"] as? Double,
        width > 0, height > 0
      else { return nil }
      return (
        rect: CGRect(x: x, y: y, width: width, height: height),
        radius: CGFloat(region["r"] as? Double ?? 0)
      )
    }
    pillGlassView?.setRegions(parsed, radius: CGFloat(radius))
  }

  func restoreFromPill() {
    pillGlassView?.removeFromSuperview()
    pillGlassView = nil
    ignoresMouseEvents = false
    guard let previousFrame = pillPreviousFrame else { return }
    pillPreviousFrame = nil
    onboardingBlurView?.isHidden = pillPreviousBlurHidden
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
