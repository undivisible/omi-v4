import ApplicationServices
import Cocoa

/// A read-only reader of the macOS accessibility tree, snapshotted on demand
/// when a pill prompt is submitted. It never writes, clicks, presses, or types
/// — it only observes what is already on screen: the frontmost app, the text
/// the user has already written in the focused field, any current selection,
/// and a bounded excerpt of the surrounding window (the thread they are looking
/// at). Everything it returns is a JSON-able map for the `omi/ax_context`
/// channel, and it never throws: on any failure it returns a partial map plus a
/// `reason`, so a flaky read can never break sending a prompt.
enum AXContextReader {
  // Hard caps so a huge Chromium/Electron tree can never hang the call or
  // balloon the payload: a shallow depth, a small node budget, a total
  // character budget, and a wall-clock deadline checked between nodes.
  private static let maxDepth = 8
  private static let maxNodes = 50
  private static let maxChars = 4000
  private static let deadline: TimeInterval = 0.15
  // Per-element messaging timeout, so a single unresponsive app can't block
  // past the deadline waiting on one attribute read.
  private static let messagingTimeout: Float = 0.1

  static func snapshot() -> [String: Any] {
    var result: [String: Any] = [:]
    if let app = NSWorkspace.shared.frontmostApplication {
      result["app"] = app.localizedName
      result["bundleId"] = app.bundleIdentifier
    }
    // AXIsProcessTrusted() is a silent check — it never shows the permission
    // prompt — so calling it (and the reads below) when the grant is missing
    // is harmless and simply yields an empty, reasoned snapshot.
    guard AXIsProcessTrusted() else {
      result["reason"] = "not_trusted"
      return result
    }
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    guard let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) else {
      result["reason"] = "no_focus"
      return result
    }
    AXUIElementSetMessagingTimeout(focused, messagingTimeout)

    // Secure-field block: never read a password field's contents. When the
    // focused element is a secure text field, report only that fact and leave
    // focusedText null. This is a privacy boundary, not a nicety.
    if isSecure(focused) {
      result["secure"] = true
    } else {
      if let value = copyString(focused, kAXValueAttribute), !value.isEmpty {
        result["focusedText"] = clamp(value, maxChars)
      }
      if let selected = copyString(focused, kAXSelectedTextAttribute),
        !selected.isEmpty {
        result["selectedText"] = clamp(selected, maxChars)
      }
    }

    // The focused window: its title plus a bounded, depth-limited walk of its
    // text descendants — the visible thread around the cursor.
    if let window = focusedWindow(of: focused) {
      AXUIElementSetMessagingTimeout(window, messagingTimeout)
      if let title = copyString(window, kAXTitleAttribute), !title.isEmpty {
        result["windowTitle"] = title
      }
      let walk = collectText(from: window)
      if !walk.text.isEmpty { result["surrounding"] = walk.text }
      if walk.truncated { result["truncated"] = true }
    }
    return result
  }

  private static func copyValue(
    _ element: AXUIElement, _ attribute: String
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      element, attribute as CFString, &value)
    return error == .success ? value : nil
  }

  private static func copyElement(
    _ element: AXUIElement, _ attribute: String
  ) -> AXUIElement? {
    guard let value = copyValue(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func copyString(
    _ element: AXUIElement, _ attribute: String
  ) -> String? {
    guard let value = copyValue(element, attribute),
      CFGetTypeID(value) == CFStringGetTypeID()
    else { return nil }
    return (value as! CFString) as String
  }

  private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
    guard let value = copyValue(element, kAXChildrenAttribute),
      CFGetTypeID(value) == CFArrayGetTypeID()
    else { return nil }
    return (value as! [AXUIElement])
  }

  private static func isSecure(_ element: AXUIElement) -> Bool {
    copyString(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
  }

  private static func focusedWindow(of focused: AXUIElement) -> AXUIElement? {
    if let window = copyElement(focused, kAXWindowAttribute) { return window }
    // The focused element may not expose its window directly (some web
    // content); fall back to the frontmost app's focused window.
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
    return copyElement(appElement, kAXFocusedWindowAttribute)
  }

  private static func collectText(
    from window: AXUIElement
  ) -> (text: String, truncated: Bool) {
    let start = ProcessInfo.processInfo.systemUptime
    var pieces: [String] = []
    var total = 0
    var nodes = 0
    var truncated = false

    func visit(_ element: AXUIElement, depth: Int) {
      if truncated { return }
      if nodes >= maxNodes || total >= maxChars || depth > maxDepth
        || ProcessInfo.processInfo.systemUptime - start > deadline {
        truncated = true
        return
      }
      nodes += 1
      if let role = copyString(element, kAXRoleAttribute),
        role == (kAXStaticTextRole as String)
          || role == (kAXTextAreaRole as String)
          || role == (kAXTextFieldRole as String),
        !isSecure(element),
        let value = copyString(element, kAXValueAttribute) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          let remaining = maxChars - total
          let piece =
            trimmed.count > remaining
            ? String(trimmed.prefix(remaining)) : trimmed
          pieces.append(piece)
          total += piece.count
          if piece.count < trimmed.count { truncated = true }
        }
      }
      guard let children = copyChildren(element) else { return }
      for child in children {
        if truncated { break }
        visit(child, depth: depth + 1)
      }
    }
    visit(window, depth: 0)
    return (pieces.joined(separator: "\n"), truncated)
  }

  private static func clamp(_ text: String, _ max: Int) -> String {
    text.count <= max ? text : String(text.prefix(max))
  }
}
