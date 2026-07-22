import ApplicationServices
import AVFoundation
import Cocoa

final class MacPermissionService {
  static let privacyPanes: Set<String> = [
    "Privacy_Accessibility",
    "Privacy_Microphone",
    "Privacy_ScreenCapture",
    "Privacy_AllFiles",
  ]

  let bundleURL: URL
  private let libraryURL: URL
  private let screenCaptureGrantedAtLaunch: Bool

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.bundleURL = bundleURL
    libraryURL = homeDirectory.appendingPathComponent("Library", isDirectory: true)
    screenCaptureGrantedAtLaunch = CGPreflightScreenCaptureAccess()
  }

  func rawSnapshot() -> [String: Any] {
    [
      "accessibility": AXIsProcessTrusted(),
      "microphone": microphoneStatus(),
      "screenCapture": CGPreflightScreenCaptureAccess(),
      "screenCaptureAtLaunch": screenCaptureGrantedAtLaunch,
      "fullDiskProbes": fullDiskProbes(),
    ]
  }

  func promptAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  func requestMicrophone(completion: @escaping () -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { _ in completion() }
  }

  func promptScreenCapture() {
    CGRequestScreenCaptureAccess()
  }

  func openPrivacyPane(_ pane: String) -> Bool {
    guard
      Self.privacyPanes.contains(pane),
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    else { return false }
    NSWorkspace.shared.open(url)
    return true
  }

  static func classifyProbeError(code: Int) -> String {
    switch code {
    case NSFileReadNoSuchFileError, NSFileNoSuchFileError: "absent"
    default: "denied"
    }
  }

  private func microphoneStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined: "notDetermined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .authorized: "authorized"
    @unknown default: "unknown"
    }
  }

  private func fullDiskProbes() -> [String] {
    let notes = libraryURL.appendingPathComponent("Group Containers/group.com.apple.notes")
    let files = [
      libraryURL.appendingPathComponent("Application Support/com.apple.TCC/TCC.db"),
      notes.appendingPathComponent("NoteStore.sqlite"),
      notes.appendingPathComponent("Accounts/LocalAccount/NoteStore.sqlite"),
    ].map { file in
      do {
        let handle = try FileHandle(forReadingFrom: file)
        try? handle.close()
        return "readable"
      } catch let error as NSError {
        return Self.classifyProbeError(code: error.code)
      }
    }
    let directories = [libraryURL.appendingPathComponent("Mail", isDirectory: true)].map {
      directory in
      do {
        _ = try FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: nil)
        return "readable"
      } catch let error as NSError {
        return Self.classifyProbeError(code: error.code)
      }
    }
    return files + directories
  }
}
