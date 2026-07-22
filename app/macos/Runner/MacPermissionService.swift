import ApplicationServices
import AVFoundation
import Cocoa
import SQLite3

final class MacPermissionService {
  static let privacyPanes: Set<String> = [
    "Privacy_Accessibility",
    "Privacy_Microphone",
    "Privacy_ScreenCapture",
    "Privacy_AllFiles",
  ]

  private static let fullDiskProbeMinInterval: TimeInterval = 3

  let bundleURL: URL
  private let libraryURL: URL
  private let screenCaptureGrantedAtLaunch: Bool
  private var cachedFullDiskProbes: [String]?
  private var lastFullDiskProbeAt: Date?

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
      "accessibility": AXIsProcessTrusted() || tccAccessibilityAllowed(),
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

  /// `AXIsProcessTrusted()` is the authoritative live check, but some launch
  /// paths (e.g. a freshly rebuilt debug binary re-signed since the last
  /// grant) leave tccd reporting the process untrusted for a beat after the
  /// user has visibly enabled it in System Settings. Read the grant directly
  /// from TCC.db as a fallback so the UI doesn't get stuck showing "Open"
  /// for a permission that is actually on. Any failure (no Full Disk Access
  /// yet, missing db, locked file) yields `false` — this only ever adds a
  /// grant the live API missed, never removes one it reported.
  private func tccAccessibilityAllowed() -> Bool {
    guard let bundleId = Bundle.main.bundleIdentifier else { return false }
    let path = libraryURL.appendingPathComponent("Application Support/com.apple.TCC/TCC.db").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      sqlite3_close(db)
      return false
    }
    defer { sqlite3_close(db) }
    let sql =
      "SELECT auth_value FROM access WHERE service = 'kTCCServiceAccessibility' AND client = ? ORDER BY last_modified DESC LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      sqlite3_finalize(statement)
      return false
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, bundleId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
    return sqlite3_column_int(statement, 0) == 2
  }

  private func fullDiskProbes() -> [String] {
    if let cached = cachedFullDiskProbes,
      let lastProbe = lastFullDiskProbeAt,
      Date().timeIntervalSince(lastProbe) < Self.fullDiskProbeMinInterval
    {
      return cached
    }
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
    let result = files + directories
    cachedFullDiskProbes = result
    lastFullDiskProbeAt = Date()
    return result
  }
}
