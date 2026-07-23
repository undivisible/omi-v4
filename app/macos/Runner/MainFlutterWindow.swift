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

/// Pure shake detector mirroring the Dart onboarding logic
/// (`lib/keyboard/shake_gesture.dart`): rapid horizontal direction reversals
/// fill a progress meter that fires at 100, with time-based decay between
/// reversals so ordinary pointer travel never triggers it.
final class MouseShakeDetector {
  private var lastX: CGFloat?
  private var lastDirection = 0
  private var lastReversalAtMs = 0.0
  private var lastEventAtMs: Double?
  private(set) var progress = 0.0

  /// Feeds one pointer sample; returns true exactly when the shake meter
  /// fills, then resets for the next gesture.
  func feed(x: CGFloat, atMs: Double) -> Bool {
    if let lastEventAtMs, progress > 0 {
      progress = max(0, progress - (atMs - lastEventAtMs) * 8.0 / 120.0)
    }
    lastEventAtMs = atMs
    defer { lastX = x }
    guard let lastX else { return false }
    let movement = x - lastX
    let direction = movement > 0 ? 1 : (movement < 0 ? -1 : 0)
    let elapsed = atMs - lastReversalAtMs
    if abs(movement) >= 7, lastDirection != 0, direction != 0,
      direction != lastDirection, elapsed < 260 {
      progress = min(100, progress + min(abs(movement), 20))
      lastReversalAtMs = atMs
    } else if direction != lastDirection {
      lastReversalAtMs = atMs
    }
    if direction != 0 { lastDirection = direction }
    if progress >= 100 {
      reset()
      return true
    }
    return false
  }

  func reset() {
    progress = 0
    lastDirection = 0
    lastReversalAtMs = 0
    lastEventAtMs = nil
    lastX = nil
  }
}

/// The full-screen listening glow, rendered natively: four warm gradient
/// bands hugging the screen edges whose intensity swells with the live audio
/// level. Lives in its own click-through overlay window so the main app
/// window is never touched while voice is up.
final class VoiceEdgeGlowView: NSView {
  private var edgeLayers: [CAGradientLayer] = []
  private static let glowThickness: CGFloat = 150

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    let core = NSColor(calibratedRed: 1, green: 0.72, blue: 0.45, alpha: 0.6)
    for _ in 0..<4 {
      let gradient = CAGradientLayer()
      gradient.colors = [core.cgColor, core.withAlphaComponent(0).cgColor]
      gradient.opacity = 0
      layer?.addSublayer(gradient)
      edgeLayers.append(gradient)
    }
    layoutEdges()
    // Entry burst: sweep the glow in, then settle at the resting level.
    let entry = CABasicAnimation(keyPath: "opacity")
    entry.fromValue = 0
    entry.toValue = 0.85
    entry.duration = 0.45
    entry.timingFunction = CAMediaTimingFunction(name: .easeOut)
    for gradient in edgeLayers {
      gradient.opacity = 0.55
      gradient.add(entry, forKey: "entry")
    }
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    layoutEdges()
  }

  private func layoutEdges() {
    guard edgeLayers.count == 4 else { return }
    let thickness = Self.glowThickness
    let size = bounds.size
    let frames = [
      NSRect(x: 0, y: 0, width: size.width, height: thickness),
      NSRect(x: 0, y: size.height - thickness, width: size.width, height: thickness),
      NSRect(x: 0, y: 0, width: thickness, height: size.height),
      NSRect(x: size.width - thickness, y: 0, width: thickness, height: size.height),
    ]
    let directions: [(CGPoint, CGPoint)] = [
      (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
      (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
      (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
      (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
    ]
    for (index, gradient) in edgeLayers.enumerated() {
      gradient.frame = frames[index]
      gradient.endPoint = directions[index].0
      gradient.startPoint = directions[index].1
    }
  }

  func setAudioLevel(_ level: Double) {
    let clamped = min(max(level, 0), 1)
    for gradient in edgeLayers {
      gradient.opacity = Float(0.45 + 0.55 * clamped)
    }
  }
}

/// The separate borderless, transparent, click-through overlay window that
/// hosts the edge glow while listening. It joins all Spaces at a level above
/// normal windows, and — crucially — is its own window instance: summoning
/// it never moves, resizes, or restyles the main app window.
final class VoiceGlowOverlayWindow: NSWindow {
  static func make(frame: NSRect) -> VoiceGlowOverlayWindow {
    let window = VoiceGlowOverlayWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    window.contentView = VoiceEdgeGlowView(
      frame: NSRect(origin: .zero, size: frame.size))
    return window
  }

  func setAudioLevel(_ level: Double) {
    (contentView as? VoiceEdgeGlowView)?.setAudioLevel(level)
  }
}

/// The native waveform bars shown next to the cursor while listening,
/// animated from the live audio level.
final class VoiceWaveformView: NSView {
  private var bars: [CALayer] = []
  private var timer: Timer?
  private var level = 0.0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    for _ in 0..<5 {
      let bar = CALayer()
      bar.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.92).cgColor
      bar.cornerRadius = 2.5
      bar.shadowColor = NSColor(
        calibratedRed: 1, green: 0.72, blue: 0.45, alpha: 1).cgColor
      bar.shadowOpacity = 0.8
      bar.shadowRadius = 8
      bar.shadowOffset = .zero
      layer?.addSublayer(bar)
      bars.append(bar)
    }
    layoutBars()
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.layoutBars()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  required init?(coder: NSCoder) { nil }

  deinit { timer?.invalidate() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func setAudioLevel(_ level: Double) {
    self.level = min(max(level, 0), 1)
  }

  private func layoutBars() {
    let width: CGFloat = 5
    let gap: CGFloat = 7
    let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * gap
    let left = (bounds.width - total) / 2
    CATransaction.begin()
    CATransaction.setAnimationDuration(1.0 / 15.0)
    for (index, bar) in bars.enumerated() {
      let jitter = 0.35 + 0.65 * Double.random(in: 0...1)
      let height = 6 + CGFloat(level * jitter) * (bounds.height - 12)
      bar.frame = NSRect(
        x: left + CGFloat(index) * (width + gap),
        y: (bounds.height - height) / 2,
        width: width,
        height: height)
    }
    CATransaction.commit()
  }
}

/// A small non-activating, click-through panel hosting the waveform. It is
/// summoned next to the cursor and follows it while listening, clamped to
/// the screen's visible frame — again its own window, so the main app window
/// stays untouched.
final class VoiceWaveformPanel: NSPanel {
  static let waveformSize = NSSize(width: 120, height: 64)

  static func panelFrame(cursor: NSPoint, size: NSSize, visible: NSRect) -> NSRect {
    var target = NSRect(
      x: cursor.x + 18,
      y: cursor.y - size.height - 18,
      width: size.width,
      height: size.height)
    target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - size.width)
    target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - size.height)
    return target
  }

  static func make() -> VoiceWaveformPanel {
    let panel = VoiceWaveformPanel(
      contentRect: NSRect(origin: .zero, size: waveformSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.contentView = VoiceWaveformView(
      frame: NSRect(origin: .zero, size: waveformSize))
    return panel
  }

  func setAudioLevel(_ level: Double) {
    (contentView as? VoiceWaveformView)?.setAudioLevel(level)
  }
}

/// Owns the two native voice surfaces (glow overlay + follow-cursor waveform
/// panel) and the mouse monitors that keep the panel glued to the cursor.
/// Shown without activating the app, so voice summoned from the background
/// never steals focus from whatever the user is working in.
final class VoiceOverlayController {
  private var glowWindow: VoiceGlowOverlayWindow?
  private var waveformPanel: VoiceWaveformPanel?
  private var localMouseMonitor: Any?
  private var globalMouseMonitor: Any?

  var isActive: Bool { glowWindow != nil }

  private static var activeScreen: NSScreen? {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
  }

  func start() {
    guard glowWindow == nil else { return }
    let screen = Self.activeScreen
    let glow = VoiceGlowOverlayWindow.make(frame: screen?.frame ?? .zero)
    glow.orderFrontRegardless()
    glowWindow = glow
    let panel = VoiceWaveformPanel.make()
    reposition(panel: panel, cursor: NSEvent.mouseLocation)
    panel.orderFrontRegardless()
    waveformPanel = panel
    let follow: () -> Void = { [weak self] in
      guard let self, let panel = self.waveformPanel else { return }
      self.reposition(panel: panel, cursor: NSEvent.mouseLocation)
    }
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved]
    ) { event in
      follow()
      return event
    }
    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.mouseMoved]
    ) { _ in follow() }
  }

  private func reposition(panel: VoiceWaveformPanel, cursor: NSPoint) {
    let screen =
      NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }
      ?? NSScreen.main
    let frame = VoiceWaveformPanel.panelFrame(
      cursor: cursor,
      size: VoiceWaveformPanel.waveformSize,
      visible: screen?.visibleFrame
        ?? NSRect(origin: cursor, size: VoiceWaveformPanel.waveformSize))
    panel.setFrameOrigin(frame.origin)
  }

  func stop() {
    if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    localMouseMonitor = nil
    globalMouseMonitor = nil
    glowWindow?.orderOut(nil)
    glowWindow?.close()
    glowWindow = nil
    waveformPanel?.orderOut(nil)
    waveformPanel?.close()
    waveformPanel = nil
  }

  func setAudioLevel(_ level: Double) {
    glowWindow?.setAudioLevel(level)
    waveformPanel?.setAudioLevel(level)
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
  private var localShakeMonitor: Any?
  private var globalShakeMonitor: Any?
  private let shakeDetector = MouseShakeDetector()
  let voiceOverlayController = VoiceOverlayController()
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
    // Global NSEvent monitors only fire while another app is frontmost when
    // the process holds the Accessibility grant; without it the double-shift
    // chord and Option+Space work solely inside omi, so tell Dart to surface
    // a clear notice.
    if !AXIsProcessTrusted() {
      events(["type": "globalHotkeyUnavailable"])
    }
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

  /// Feeds every pointer sample (local, and global once Accessibility is
  /// granted) to the shake detector; a completed shake reaches Dart as its
  /// own keyboard event, the mouse twin of the double chord.
  private func mouseMovedEvent() {
    if IsSecureEventInputEnabled() { return }
    let firedShake = shakeDetector.feed(
      x: NSEvent.mouseLocation.x,
      atMs: ProcessInfo.processInfo.systemUptime * 1000)
    if firedShake {
      keyboardSink?(["type": "shake"])
    }
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
    localShakeMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved]
    ) { [weak self] event in
      self?.mouseMovedEvent()
      return event
    }
    globalShakeMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.mouseMoved]
    ) { [weak self] _ in self?.mouseMovedEvent() }

    let voiceOverlay = FlutterMethodChannel(
      name: "omi/voice_overlay",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    voiceOverlay.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        self?.voiceOverlayController.start()
        result(nil)
      case "stop":
        self?.voiceOverlayController.stop()
        result(nil)
      case "level":
        self?.voiceOverlayController.setAudioLevel(call.arguments as? Double ?? 0)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

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
          height: arguments?["height"] as? Double ?? 230)
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

    let launcher = FlutterMethodChannel(
      name: "omi/launcher",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    launcher.setMethodCallHandler { call, result in
      guard call.method == "openApp" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let query = (call.arguments as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !query.isEmpty
      else {
        result(nil)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        guard
          let url = Self.resolveApplicationURL(
            query: query, candidates: Self.installedApplicationURLs())
        else {
          DispatchQueue.main.async { result(nil) }
          return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
          DispatchQueue.main.async { result(error == nil ? name : nil) }
        }
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
    if let localShakeMonitor { NSEvent.removeMonitor(localShakeMonitor) }
    if let globalShakeMonitor { NSEvent.removeMonitor(globalShakeMonitor) }
    voiceOverlayController.stop()
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

  /// Directories scanned for the overlay's deterministic "open <app>" fast
  /// path. Shallow, launch-time cheap; NSWorkspace performs the real open.
  static var launcherSearchRoots: [URL] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
      URL(
        fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true),
    ]
  }

  static func installedApplicationURLs(roots: [URL] = launcherSearchRoots) -> [URL] {
    var applications: [URL] = []
    for root in roots {
      guard
        let entries = try? FileManager.default.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles])
      else { continue }
      applications.append(
        contentsOf: entries.filter { $0.pathExtension == "app" })
    }
    return applications
  }

  /// Deterministic name match for the overlay launcher: exact name first,
  /// then prefix, then substring — all case-insensitive — so "chrome" finds
  /// "Google Chrome" and "safari" never loses to "Safari Technology Preview".
  static func resolveApplicationURL(query: String, candidates: [URL]) -> URL? {
    let normalized = query.lowercased()
    guard !normalized.isEmpty else { return nil }
    var prefixMatch: URL?
    var substringMatch: URL?
    for url in candidates {
      let name = url.deletingPathExtension().lastPathComponent.lowercased()
      if name == normalized { return url }
      if prefixMatch == nil, name.hasPrefix(normalized) { prefixMatch = url }
      if substringMatch == nil, name.contains(normalized) { substringMatch = url }
    }
    return prefixMatch ?? substringMatch
  }

  /// The text-input pill sits just below-right of the cursor, clamped to the
  /// screen's visible frame; once summoned it does not move.
  static func cursorPillFrame(
    cursor: NSPoint, width: Double, height: Double, visible: NSRect
  ) -> NSRect {
    var target = NSRect(
      x: cursor.x + 18,
      y: cursor.y - height - 18,
      width: width,
      height: height)
    target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - width)
    target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - height)
    return target
  }

  func summonPill(width: Double, height: Double) {
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
    let target = Self.cursorPillFrame(
      cursor: NSEvent.mouseLocation,
      width: width, height: height,
      visible: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: width, height: height))
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // The text input is static and interactive: it must accept mouse events
    // so its input field and suggestion chips stay clickable.
    ignoresMouseEvents = false
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
