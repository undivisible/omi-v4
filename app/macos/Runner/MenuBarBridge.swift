import Cocoa
import FlutterMacOS

@MainActor
final class MenuBarBridge: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var statusItem: NSStatusItem?
  private var task = "Omi"
  private var listening = false
  private var meeting = false
  private var notice: String?

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
        self.meeting = arguments?["meeting"] as? Bool ?? false
        let notice = (arguments?["notice"] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        self.notice = (notice?.isEmpty ?? true) ? nil : notice
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
    menu.autoenablesItems = false
    let current = NSMenuItem(title: task, action: #selector(showApp), keyEquivalent: "")
    current.target = self
    menu.addItem(current)
    menu.addItem(.separator())
    let conversation = NSMenuItem(
      title: listening ? "End live conversation" : "Live conversation",
      action: #selector(toggleLiveConversation), keyEquivalent: "")
    conversation.target = self
    conversation.state = listening ? .on : .off
    menu.addItem(conversation)
    let input = NSMenuItem(title: "Text input", action: #selector(openInput), keyEquivalent: "")
    input.target = self
    menu.addItem(input)
    let meetingItem = NSMenuItem(
      title: meeting ? "End meeting" : "Start meeting", action: #selector(toggleMeeting),
      keyEquivalent: "")
    meetingItem.target = self
    meetingItem.state = meeting ? .on : .off
    menu.addItem(meetingItem)
    if let notice {
      menu.addItem(.separator())
      let reason = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
      reason.isEnabled = false
      menu.addItem(reason)
    }
    menu.addItem(.separator())
    let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
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

  @objc private func openInput() {
    // Summon the floating pill only — never activate the hub window.
    channel.invokeMethod("openInput", arguments: nil)
  }

  @objc private func toggleLiveConversation() {
    channel.invokeMethod("toggleLiveConversation", arguments: nil)
  }

  @objc private func toggleMeeting() {
    channel.invokeMethod("toggleMeeting", arguments: nil)
  }

  @objc private func openSettings() {
    showApp()
    channel.invokeMethod("openSettings", arguments: nil)
  }
}
