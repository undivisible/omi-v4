import Cocoa
import FlutterMacOS

/// Hosts the settings UI in its own native macOS window, backed by a second
/// Flutter engine running the `settingsMain` entrypoint (which renders only
/// the settings screen). The window and engine are created lazily on first
/// use and then kept alive: closing the window hides it, and every later
/// open fronts the same window instead of spawning another.
@MainActor
final class SettingsWindowController: NSWindowController {
  static var shared: SettingsWindowController?

  private var engine: FlutterEngine?
  private var routeChannel: FlutterMethodChannel?

  /// The section a deep link asked for, held until the settings engine is up
  /// far enough to ask for it. Cleared once handed over so a later plain
  /// open lands wherever the window already was.
  private static var pendingSection: String?

  static let defaultContentSize = NSSize(width: 760, height: 560)
  static let windowTitle = "Omi Settings"

  static func makeWindow(contentViewController: NSViewController) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: defaultContentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = windowTitle
    window.minSize = NSSize(width: 560, height: 420)
    window.isReleasedWhenClosed = false
    window.contentViewController = contentViewController
    // Assigning a content view controller resizes the window to the
    // controller's own view size; re-assert the intended settings size.
    window.setContentSize(defaultContentSize)
    window.center()
    return window
  }

  static func show(section: String? = nil) {
    pendingSection = section
    if let existing = shared {
      // The window is already up, so its engine will never re-read the
      // pending section on its own; push the request at it instead.
      if let section {
        pendingSection = nil
        existing.routeChannel?.invokeMethod("showSection", arguments: section)
      }
      existing.front()
      return
    }
    let engine = FlutterEngine(name: "omi-settings", project: nil)
    engine.run(withEntrypoint: "settingsMain")
    RegisterGeneratedPlugins(registry: engine)
    let viewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    let controller = SettingsWindowController(
      window: makeWindow(contentViewController: viewController))
    controller.engine = engine
    let route = FlutterMethodChannel(
      name: "omi/settings_route",
      binaryMessenger: engine.binaryMessenger)
    route.setMethodCallHandler { call, result in
      guard call.method == "pendingSection" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let requested = pendingSection
      pendingSection = nil
      result(requested)
    }
    controller.routeChannel = route
    shared = controller
    controller.front()
  }

  func front() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
