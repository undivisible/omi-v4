import Cocoa

/// Session-wide capture of the keystrokes and pointer motion omi needs while
/// another application is frontmost: the double-Shift chord, the overlay
/// keybind, and the pointer shake.
///
/// `NSEvent.addGlobalMonitorForEvents` proved unreliable here — it silently
/// delivers nothing in several common states even with the Accessibility
/// grant in place — so the global path is a listen-only CGEventTap on the
/// session tap instead. Listen-only means the tap never modifies, swallows,
/// or delays anyone's input; it only observes.
///
/// The tap can only be created once the process is Accessibility-trusted, and
/// the system disables it if a callback ever times out. Both states are
/// recovered from: installation is retried on a timer until it succeeds, and
/// a disabled tap is re-enabled from its own callback. [isInstalled] reports
/// whether capture is actually live so the app can show the truth instead of
/// failing silently.
final class GlobalInputTap {
  /// Every captured event, on the main thread. The `CGEvent` is only valid
  /// for the duration of the call.
  var onEvent: ((CGEventType, CGEvent) -> Void)?

  /// Fired whenever [isInstalled] changes, so diagnostics can be re-emitted.
  var onStateChange: (() -> Void)?

  static let eventMask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.mouseMoved.rawValue)

  /// How often a failed installation is retried, so granting Accessibility
  /// while omi runs starts global capture without a restart.
  static let retryInterval: TimeInterval = 3

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var retryTimer: Timer?

  /// True only when the tap exists and the system has it enabled — the
  /// honest answer to "is the global chord actually being watched?".
  var isInstalled: Bool {
    guard let tap else { return false }
    return CGEvent.tapIsEnabled(tap: tap)
  }

  func start() {
    install()
    guard retryTimer == nil else { return }
    let timer = Timer(timeInterval: Self.retryInterval, repeats: true) {
      [weak self] _ in
      guard let self else { return }
      if self.isInstalled { return }
      let wasInstalled = self.tap != nil
      self.teardownTap()
      self.install()
      if self.isInstalled || wasInstalled { self.onStateChange?() }
    }
    RunLoop.main.add(timer, forMode: .common)
    retryTimer = timer
  }

  func stop() {
    retryTimer?.invalidate()
    retryTimer = nil
    teardownTap()
  }

  private func install() {
    guard tap == nil, AXIsProcessTrusted() else { return }
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      let tap = Unmanaged<GlobalInputTap>.fromOpaque(userInfo)
        .takeUnretainedValue()
      tap.handle(type: type, event: event)
      return Unmanaged.passUnretained(event)
    }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: Self.eventMask,
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    tap = port
    self.source = source
  }

  private func teardownTap() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap { CFMachPortInvalidate(tap) }
    source = nil
    tap = nil
  }

  private func handle(type: CGEventType, event: CGEvent) {
    // The system hands the tap back disabled after a timeout or a user
    // input-source switch; re-arming it here is what keeps global capture
    // alive across sleep, fast user switching, and busy main threads.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      onStateChange?()
      return
    }
    onEvent?(type, event)
  }
}
