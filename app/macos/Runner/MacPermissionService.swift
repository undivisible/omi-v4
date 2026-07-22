import ApplicationServices
import AVFoundation
import Cocoa

enum MacPermissionCapability: String {
  case accessibility
  case microphone
  case screenCapture
  case appData
}

struct MacPermissionSnapshot: Equatable {
  let accessibility: Bool
  let microphone: Bool
  let screenCapture: Bool
  let fullDiskAccess: Bool

  var dictionary: [String: Bool] {
    [
      "accessibility": accessibility,
      "microphone": microphone,
      "screenCapture": screenCapture,
      "fullDiskAccess": fullDiskAccess,
    ]
  }

  func grants(_ capability: MacPermissionCapability) -> Bool {
    switch capability {
    case .accessibility: accessibility
    case .microphone: microphone
    case .screenCapture: screenCapture
    case .appData: fullDiskAccess
    }
  }
}

enum AccessibilityPermissionPolicy {
  static func isGranted(trusted: Bool, eventTapAvailable: Bool, axFunctional: Bool) -> Bool {
    (trusted || eventTapAvailable) && axFunctional
  }

  static func isFunctional(_ result: AXError) -> Bool? {
    switch result {
    case .success, .noValue, .notImplemented, .attributeUnsupported: true
    case .apiDisabled: false
    case .cannotComplete: nil
    default: true
    }
  }
}

enum FullDiskAccessProbePolicy {
  static func files(in library: URL) -> [URL] {
    let notes = library.appendingPathComponent("Group Containers/group.com.apple.notes")
    return [
      notes.appendingPathComponent("NoteStore.sqlite"),
      notes.appendingPathComponent("Accounts/LocalAccount/NoteStore.sqlite"),
    ]
  }

  static func directories(in library: URL) -> [URL] {
    [library.appendingPathComponent("Mail", isDirectory: true)]
  }

  static func isGranted(_ readableSources: [Bool]) -> Bool {
    readableSources.contains(true)
  }
}

final class MacPermissionService {
  let bundleURL: URL
  private let libraryURL: URL

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.bundleURL = bundleURL
    libraryURL = homeDirectory.appendingPathComponent("Library", isDirectory: true)
  }

  func snapshot() -> MacPermissionSnapshot {
    MacPermissionSnapshot(
      accessibility: hasAccessibilityAccess(),
      microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      screenCapture: CGPreflightScreenCaptureAccess(),
      fullDiskAccess: hasFullDiskAccess())
  }

  func request(_ capability: MacPermissionCapability, completion: @escaping () -> Void) {
    switch capability {
    case .accessibility:
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
      AXIsProcessTrustedWithOptions(options as CFDictionary)
      openPrivacyPane("Privacy_Accessibility")
      completion()
    case .microphone:
      AVCaptureDevice.requestAccess(for: .audio) { _ in completion() }
    case .screenCapture:
      CGRequestScreenCaptureAccess()
      openPrivacyPane("Privacy_ScreenCapture")
      completion()
    case .appData:
      openPrivacyPane("Privacy_AllFiles")
      completion()
    }
  }

  private func hasAccessibilityAccess() -> Bool {
    AccessibilityPermissionPolicy.isGranted(
      trusted: AXIsProcessTrusted(),
      eventTapAvailable: probeAccessibilityViaEventTap(),
      axFunctional: testAccessibilityPermission())
  }

  private func probeAccessibilityViaEventTap() -> Bool {
    let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .tailAppendEventTap,
      options: .listenOnly,
      eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
      callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
      userInfo: nil)
    if let tap { CFMachPortInvalidate(tap) }
    return tap != nil
  }

  private func testAccessibilityPermission() -> Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return true }
    let result = focusedWindowResult(for: frontmost.processIdentifier)
    if let functional = AccessibilityPermissionPolicy.isFunctional(result) { return functional }
    guard
      let finder = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.finder"
      ).first
    else { return probeAccessibilityViaEventTap() }
    return AccessibilityPermissionPolicy.isFunctional(
      focusedWindowResult(for: finder.processIdentifier)) ?? false
  }

  private func focusedWindowResult(for processIdentifier: pid_t) -> AXError {
    var focusedWindow: CFTypeRef?
    return AXUIElementCopyAttributeValue(
      AXUIElementCreateApplication(processIdentifier),
      kAXFocusedWindowAttribute as CFString,
      &focusedWindow)
  }

  private func hasFullDiskAccess() -> Bool {
    let files = FullDiskAccessProbePolicy.files(in: libraryURL).map { file in
      guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
      try? handle.close()
      return true
    }
    let directories = FullDiskAccessProbePolicy.directories(in: libraryURL).map {
      (try? FileManager.default.contentsOfDirectory(
        at: $0,
        includingPropertiesForKeys: nil)) != nil
    }
    return FullDiskAccessProbePolicy.isGranted(files + directories)
  }

  private func openPrivacyPane(_ pane: String) {
    guard
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
