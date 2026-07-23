import Cocoa
import FlutterMacOS

/// Native Liquid Glass backing for the cursor pill. On macOS 26+ this hosts
/// the real NSGlassEffectView (looked up dynamically so older SDKs still
/// build); earlier systems fall back to a behind-window NSVisualEffectView.
/// The glass is masked to the pill's rounded-rect regions, which Dart
/// reports through the omi/pill channel so the native shape always
/// matches the Flutter layout above it.
final class PillGlassView: NSView {
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

/// The floating text-input overlay's own window. It is a non-activating panel
/// — summoning it never moves, resizes, or restyles the main app window, and
/// the hub keeps its own frame and level behind it — that nonetheless becomes
/// key, because the whole point of the surface is typing into it.
final class PillPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  static func make(size: NSSize) -> PillPanel {
    let panel = PillPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return panel
  }
}

/// Owns the text-input overlay: a [PillPanel] backed by its own Flutter
/// engine running the `pillMain` entrypoint, which renders only the pill UI.
/// The panel's engine has no services of its own — every action it takes
/// (submit, choose a suggestion, ask for an AI completion, dismiss) is
/// relayed to the primary engine over the omi/pill_host channel, and the
/// primary engine pushes render state back the same way.
@MainActor
final class PillPanelController {
  /// Relays one panel action to the primary engine and returns its reply.
  typealias Relay = (String, Any?, @escaping FlutterResult) -> Void

  static var shared: PillPanelController?
  static let defaultSize = NSSize(width: 460, height: 320)
  static let entrypoint = "pillMain"

  private let panel: PillPanel
  private let engine: FlutterEngine
  private let channel: FlutterMethodChannel
  private weak var glassView: PillGlassView?
  private var relay: Relay?

  private init(panel: PillPanel, engine: FlutterEngine, channel: FlutterMethodChannel) {
    self.panel = panel
    self.engine = engine
    self.channel = channel
  }

  var isVisible: Bool { panel.isVisible }

  static func present(at cursor: NSPoint, size: NSSize, relay: @escaping Relay) {
    let controller = shared ?? make(size: size)
    shared = controller
    controller.relay = relay
    controller.show(at: cursor, size: size)
  }

  private static func make(size: NSSize) -> PillPanelController {
    let engine = FlutterEngine(name: "omi-pill", project: nil)
    engine.run(withEntrypoint: entrypoint)
    RegisterGeneratedPlugins(registry: engine)
    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    viewController.backgroundColor = .clear
    let panel = PillPanel.make(size: size)
    let host = NSView(frame: NSRect(origin: .zero, size: size))
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.clear.cgColor
    let glass = PillGlassView(frame: host.bounds)
    glass.autoresizingMask = [.width, .height]
    viewController.view.frame = host.bounds
    viewController.view.autoresizingMask = [.width, .height]
    host.addSubview(glass)
    host.addSubview(viewController.view)
    let hostController = NSViewController()
    hostController.view = host
    hostController.addChild(viewController)
    panel.contentViewController = hostController
    panel.setContentSize(size)
    let channel = FlutterMethodChannel(
      name: "omi/pill", binaryMessenger: engine.binaryMessenger)
    let controller = PillPanelController(panel: panel, engine: engine, channel: channel)
    controller.glassView = glass
    channel.setMethodCallHandler { [weak controller] call, result in
      controller?.handle(call, result: result)
    }
    return controller
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "glass":
      let arguments = call.arguments as? [String: Any]
      updateGlass(
        regions: arguments?["regions"] as? [[String: Any]] ?? [],
        radius: arguments?["radius"] as? Double ?? 18)
      result(nil)
    case "close":
      // The panel's own request to disappear without ending the surface —
      // the hub or the native voice windows take it from here.
      if panel.isVisible { panel.orderOut(nil) }
      result(nil)
    case "ready":
      // The engine finished booting; if the panel was summoned before that
      // happened, replay the summon and ask the host to re-push its state.
      result(["visible": panel.isVisible])
      if panel.isVisible { relay?("sync", nil) { _ in } }
    case "dismiss":
      hide()
      relay?("dismiss", nil) { _ in }
      result(nil)
    default:
      guard let relay else {
        result(FlutterError(code: "pill_host_unavailable", message: nil, details: nil))
        return
      }
      relay(call.method, call.arguments, result)
    }
  }

  /// Where a summon puts the panel: anchored to the cursor the first time,
  /// and exactly where it already is once it is up. The overlay is summoned
  /// at the cursor and then static — it must never track the pointer, and a
  /// repeat summon must not teleport it out from under the user's hands.
  static func summonFrame(
    current: NSRect, visible isVisible: Bool, cursor: NSPoint, size: NSSize,
    screen: NSRect
  ) -> NSRect {
    guard !isVisible else { return current }
    return MainFlutterWindow.cursorPillFrame(
      cursor: cursor, width: size.width, height: size.height, visible: screen)
  }

  /// Shows the panel next to the cursor, autofocused. Once up it is static:
  /// a repeat summon only re-keys it, so the surface never jumps around
  /// under the user's hands.
  func show(at cursor: NSPoint, size: NSSize) {
    let screen =
      NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }
      ?? NSScreen.main
    let frame = Self.summonFrame(
      current: panel.frame,
      visible: panel.isVisible,
      cursor: cursor,
      size: size,
      screen: screen?.visibleFrame ?? NSRect(origin: cursor, size: size))
    if frame != panel.frame { panel.setFrame(frame, display: true) }
    // A non-activating panel takes keyboard input without pulling the rest of
    // omi in front of whatever the user was working in — the hub stays exactly
    // where it was. Typing is non-negotiable though, so if the panel could not
    // take key focus on its own, fall back to activating the app.
    panel.orderFrontRegardless()
    panel.makeKey()
    if !panel.isKeyWindow {
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    }
    channel.invokeMethod("show", arguments: nil)
  }

  func hide() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
    channel.invokeMethod("hide", arguments: nil)
  }

  /// Pushes the primary engine's pill state (suggestions, status, error) into
  /// the panel's engine so it renders what the live controller holds.
  func push(_ state: [String: Any]) {
    channel.invokeMethod("state", arguments: state)
  }

  private func updateGlass(regions: [[String: Any]], radius: Double) {
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
    glassView?.setRegions(parsed, radius: CGFloat(radius))
  }
}
