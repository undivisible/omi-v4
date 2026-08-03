import Cocoa
import FlutterMacOS

/// Hosts the settings UI in its own native macOS window, backed by a second
/// Flutter engine running the `settingsMain` entrypoint (which renders only
/// the settings screen). The window and engine are built once — at launch via
/// `prewarm`, or on first use if something opens settings before that — and
/// then kept alive: closing the window hides it, and every later
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

  /// Builds the window and its engine without showing anything. A cold
  /// FlutterEngine start is seconds — Dart VM, plugin registration, first
  /// frame — and paying it on the click that opens settings is exactly what
  /// makes the first open feel broken. Launch has spare time; the click does
  /// not.
  static func prewarm() {
    guard shared == nil else { return }
    shared = make()
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
    let controller = make()
    shared = controller
    controller.front()
  }

  private static func make() -> SettingsWindowController {
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
      switch call.method {
      case "pendingSection":
        let requested = pendingSection
        pendingSection = nil
        result(requested)
      case "openInHub":
        guard let hub = MainFlutterWindow.shared else {
          result(
            FlutterError(
              code: "no-hub-window", message: "The Omi window is not open.", details: nil))
          return
        }
        shared?.window?.orderOut(nil)
        hub.showSettingsSection(call.arguments as? String)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    controller.routeChannel = route
    // Loading the window forces the FlutterViewController's view into
    // existence, so the engine renders its first frame now rather than on the
    // open that wants to show it.
    _ = controller.window
    return controller
  }

  func front() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
