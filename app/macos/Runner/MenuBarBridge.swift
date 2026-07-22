import Cocoa
import FlutterMacOS

@MainActor
final class MenuBarBridge: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var statusItem: NSStatusItem?
  private var task = "Omi"
  private var listening = false

  init(binaryMessenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: "omi/menu_bar", binaryMessenger: binaryMessenger)
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "update":
        let arguments = call.arguments as? [String: Any]
        self.task = Self.title(arguments?["task"] as? String)
        self.listening = arguments?["listening"] as? Bool ?? false
        self.render()
        result(nil)
      case "dispose":
        self.remove()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func title(_ value: String?) -> String {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty else { return "Omi" }
    return value.count > 42 ? String(value.prefix(41)) + "…" : value
  }

  private func render() {
    if statusItem == nil {
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
    statusItem?.button?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Omi")
    statusItem?.button?.imagePosition = .imageLeading
    statusItem?.button?.title = " " + task

    let menu = NSMenu()
    let current = NSMenuItem(title: task, action: #selector(showApp), keyEquivalent: "")
    current.target = self
    menu.addItem(current)
    menu.addItem(.separator())
    let capture = NSMenuItem(title: "Capture", action: #selector(capture), keyEquivalent: "")
    capture.target = self
    menu.addItem(capture)
    let listeningItem = NSMenuItem(title: "Listening", action: #selector(toggleListening), keyEquivalent: "")
    listeningItem.target = self
    listeningItem.state = listening ? .on : .off
    menu.addItem(listeningItem)
    statusItem?.menu = menu
  }

  private func remove() {
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }

  @objc private func showApp() {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  @objc private func capture() {
    showApp()
    channel.invokeMethod("capture", arguments: nil)
  }

  @objc private func toggleListening() {
    channel.invokeMethod("toggleListening", arguments: nil)
  }
}
