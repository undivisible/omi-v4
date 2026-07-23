import Cocoa
import FlutterMacOS
import XCTest
@testable import omi

class RunnerTests: XCTestCase {

  func testProbeErrorsDistinguishAbsentFromDenied() {
    XCTAssertEqual(MacPermissionService.classifyProbeError(code: NSFileReadNoSuchFileError), "absent")
    XCTAssertEqual(MacPermissionService.classifyProbeError(code: NSFileNoSuchFileError), "absent")
    XCTAssertEqual(
      MacPermissionService.classifyProbeError(code: NSFileReadNoPermissionError), "denied")
  }

  func testOnlyKnownPrivacyPanesOpen() {
    XCTAssertEqual(
      MacPermissionService.privacyPanes,
      ["Privacy_Accessibility", "Privacy_Microphone", "Privacy_ScreenCapture", "Privacy_AllFiles"])
    XCTAssertFalse(MacPermissionService().openPrivacyPane("Privacy_Unknown"))
  }

  func testRawSnapshotReportsEveryProbedCapability() {
    let snapshot = MacPermissionService().rawSnapshot()
    XCTAssertNotNil(snapshot["accessibility"] as? Bool)
    XCTAssertNotNil(snapshot["microphone"] as? String)
    XCTAssertNotNil(snapshot["screenCapture"] as? Bool)
    XCTAssertNotNil(snapshot["screenCaptureAtLaunch"] as? Bool)
    XCTAssertEqual((snapshot["fullDiskProbes"] as? [String])?.count, 4)
    XCTAssertNotNil(snapshot["fullDiskGrantedOutOfProcess"] as? Bool)
  }

  func testVoicePlayoutQueueTracksQueuedMilliseconds() {
    let queue = VoicePlayoutQueue(sampleRateHz: 24000)
    XCTAssertEqual(queue.queuedMs, 0)
    queue.scheduled(frames: 24000)
    XCTAssertEqual(queue.queuedMs, 1000)
    queue.scheduled(frames: 12000)
    XCTAssertEqual(queue.queuedMs, 1500)
    queue.completed(frames: 24000)
    XCTAssertEqual(queue.queuedMs, 500)
  }

  func testVoicePlayoutQueueClampsCompletionUnderflow() {
    let queue = VoicePlayoutQueue(sampleRateHz: 24000)
    queue.scheduled(frames: 100)
    queue.completed(frames: 500)
    XCTAssertEqual(queue.queuedMs, 0)
    queue.scheduled(frames: 240)
    XCTAssertEqual(queue.queuedMs, 10)
  }

  func testFullDiskProbeIsCachedWithinTheMinimumInterval() {
    let service = MacPermissionService()
    let first = service.rawSnapshot()["fullDiskProbes"] as? [String]
    let second = service.rawSnapshot()["fullDiskProbes"] as? [String]
    XCTAssertEqual(first, second)
  }

  @MainActor
  func testSettingsWindowIsTitledClosableResizableAtDefaultSize() {
    let window = SettingsWindowController.makeWindow(
      contentViewController: NSViewController())
    XCTAssertEqual(window.title, SettingsWindowController.windowTitle)
    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertEqual(
      window.contentRect(forFrameRect: window.frame).size,
      SettingsWindowController.defaultContentSize)
    XCTAssertFalse(window.isReleasedWhenClosed)
    window.close()
  }

  func testVoiceOverlayFrameCoversTheWholeScreen() {
    XCTAssertEqual(MainFlutterWindow.voiceOverlayFrame(for: nil), .zero)
    if let screen = NSScreen.main {
      XCTAssertEqual(MainFlutterWindow.voiceOverlayFrame(for: screen), screen.frame)
    }
  }

  func testCenteredPillFrameIsPinnedToTheUpperThird() {
    let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let frame = MainFlutterWindow.centeredPillFrame(width: 420, height: 230, visible: visible)
    XCTAssertEqual(frame.size, NSSize(width: 420, height: 230))
    XCTAssertEqual(frame.midX, visible.midX)
    XCTAssertEqual(frame.maxY, visible.maxY - visible.height * 0.28)
  }

  @MainActor
  func testVoiceSummonIsFullScreenClickThroughAndRestores() {
    let initialFrame = NSRect(x: 40, y: 40, width: 400, height: 300)
    let window = MainFlutterWindow(
      contentRect: initialFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }

    window.summonPill(width: 420, height: 230, centered: false)
    XCTAssertTrue(window.ignoresMouseEvents)
    XCTAssertEqual(window.level, .floating)
    let active =
      NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    if let active {
      XCTAssertEqual(window.frame, active.frame)
    }

    window.summonPill(width: 420, height: 230, centered: true)
    XCTAssertFalse(window.ignoresMouseEvents)

    window.restoreFromPill()
    XCTAssertFalse(window.ignoresMouseEvents)
    XCTAssertEqual(window.frame, initialFrame)
  }

  @MainActor
  func testSettingsWindowShowReusesTheExistingWindow() {
    let controller = NSViewController()
    controller.view = NSView()
    let existing = SettingsWindowController(
      window: SettingsWindowController.makeWindow(contentViewController: controller))
    SettingsWindowController.shared = existing
    defer {
      existing.window?.close()
      SettingsWindowController.shared = nil
    }
    SettingsWindowController.show()
    XCTAssertTrue(SettingsWindowController.shared === existing)
    XCTAssertEqual(existing.window?.isVisible, true)
  }

}
