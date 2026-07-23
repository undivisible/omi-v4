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

  func testLauncherResolvesExactThenPrefixThenSubstring() {
    let candidates = [
      URL(fileURLWithPath: "/Applications/Safari Technology Preview.app"),
      URL(fileURLWithPath: "/Applications/Safari.app"),
      URL(fileURLWithPath: "/Applications/Google Chrome.app"),
      URL(fileURLWithPath: "/System/Applications/Mail.app"),
    ]
    XCTAssertEqual(
      MainFlutterWindow.resolveApplicationURL(query: "safari", candidates: candidates)?
        .lastPathComponent,
      "Safari.app")
    XCTAssertEqual(
      MainFlutterWindow.resolveApplicationURL(query: "chrome", candidates: candidates)?
        .lastPathComponent,
      "Google Chrome.app")
    XCTAssertEqual(
      MainFlutterWindow.resolveApplicationURL(query: "MAIL", candidates: candidates)?
        .lastPathComponent,
      "Mail.app")
    XCTAssertNil(
      MainFlutterWindow.resolveApplicationURL(query: "fizzbuzzer", candidates: candidates))
    XCTAssertNil(MainFlutterWindow.resolveApplicationURL(query: "", candidates: candidates))
  }

  func testLauncherScansOnlyAppBundlesFromKnownRoots() {
    let roots = MainFlutterWindow.launcherSearchRoots.map(\.path)
    XCTAssertTrue(roots.contains("/Applications"))
    XCTAssertTrue(roots.contains("/System/Applications"))
    let applications = MainFlutterWindow.installedApplicationURLs()
    XCTAssertTrue(applications.allSatisfy { $0.pathExtension == "app" })
  }

  func testCursorPillFrameSitsBelowRightOfTheCursorAndClamps() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let frame = MainFlutterWindow.cursorPillFrame(
      cursor: NSPoint(x: 500, y: 500), width: 420, height: 230, visible: visible)
    XCTAssertEqual(frame.origin.x, 518)
    XCTAssertEqual(frame.origin.y, 500 - 230 - 18)
    XCTAssertEqual(frame.size, NSSize(width: 420, height: 230))

    // Near the bottom-right corner the pill clamps inside the visible frame.
    let clamped = MainFlutterWindow.cursorPillFrame(
      cursor: NSPoint(x: 1430, y: 10), width: 420, height: 230, visible: visible)
    XCTAssertEqual(clamped.maxX, visible.maxX)
    XCTAssertEqual(clamped.minY, visible.minY)
  }

  func testVoiceGlowOverlayIsItsOwnClickThroughWindow() {
    let glow = VoiceGlowOverlayWindow.make(
      frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    defer { glow.close() }
    XCTAssertTrue(glow.ignoresMouseEvents)
    XCTAssertFalse(glow.isOpaque)
    XCTAssertFalse(glow.hasShadow)
    XCTAssertEqual(glow.level, .screenSaver)
    XCTAssertTrue(glow.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(glow.contentView is VoiceEdgeGlowView)
    // Click-through all the way down: the glow view swallows no hits.
    XCTAssertNil(glow.contentView?.hitTest(NSPoint(x: 10, y: 10)))
  }

  func testWaveformPanelFollowFrameHugsTheCursorAndClamps() {
    let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let size = VoiceWaveformPanel.waveformSize
    let frame = VoiceWaveformPanel.panelFrame(
      cursor: NSPoint(x: 300, y: 300), size: size, visible: visible)
    XCTAssertEqual(frame.origin.x, 318)
    XCTAssertEqual(frame.origin.y, 300 - size.height - 18)

    let clamped = VoiceWaveformPanel.panelFrame(
      cursor: NSPoint(x: 995, y: 5), size: size, visible: visible)
    XCTAssertEqual(clamped.maxX, visible.maxX)
    XCTAssertEqual(clamped.minY, visible.minY)
  }

  func testWaveformPanelIsNonActivatingAndClickThrough() {
    let panel = VoiceWaveformPanel.make()
    defer { panel.close() }
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertFalse(panel.isOpaque)
    XCTAssertEqual(panel.level, .screenSaver)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
  }

  @MainActor
  func testVoiceOverlayNeverTouchesTheMainWindow() {
    let initialFrame = NSRect(x: 40, y: 40, width: 400, height: 300)
    let window = MainFlutterWindow(
      contentRect: initialFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }

    let overlay = window.voiceOverlayController
    overlay.start()
    XCTAssertTrue(overlay.isActive)
    // The main app window stays exactly where it was, unaffected.
    XCTAssertEqual(window.frame, initialFrame)
    XCTAssertFalse(window.ignoresMouseEvents)
    overlay.stop()
    XCTAssertFalse(overlay.isActive)
    XCTAssertEqual(window.frame, initialFrame)
  }

  func testMouseShakeDetectorFiresOnRapidReversalsOnly() {
    let detector = MouseShakeDetector()
    // Steady travel in one direction never fires.
    var atMs = 0.0
    for step in 0..<60 {
      XCTAssertFalse(detector.feed(x: CGFloat(step * 30), atMs: atMs))
      atMs += 16
    }
    // Rapid wide reversals fill the meter and fire exactly once.
    detector.reset()
    atMs = 0
    var position: CGFloat = 0
    var fired = 0
    for step in 0..<9 {
      position = step % 2 == 0 ? 60 : 0
      if detector.feed(x: position, atMs: atMs) { fired += 1 }
      atMs += 40
    }
    XCTAssertEqual(fired, 1)
    // After firing, the meter restarts from zero.
    XCTAssertEqual(detector.progress, 0)
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

  @MainActor
  func testPillPanelIsItsOwnNonActivatingWindowThatStillBecomesKey() {
    let panel = PillPanel.make(size: PillPanelController.defaultSize)
    defer { panel.close() }
    // Non-activating, so summoning it never yanks the whole app forward…
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.canBecomeMain)
    // …but typable, which is the entire point of the surface.
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.isOpaque)
    XCTAssertFalse(panel.hasShadow)
    XCTAssertFalse(panel.ignoresMouseEvents)
    XCTAssertEqual(panel.level, .floating)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    panel.orderFrontRegardless()
    panel.makeKey()
    XCTAssertTrue(panel.isKeyWindow)
  }

  @MainActor
  func testSummoningTheTextPillNeverTouchesTheMainWindow() {
    let initialFrame = NSRect(x: 40, y: 40, width: 400, height: 300)
    let window = MainFlutterWindow(
      contentRect: initialFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let initialLevel = window.level
    let initialStyleMask = window.styleMask

    window.summonPill(width: 460, height: 320)
    // The pill lives in its own panel: the hub keeps its frame, level, and
    // chrome, and stays interactive behind it.
    XCTAssertEqual(window.frame, initialFrame)
    XCTAssertEqual(window.level, initialLevel)
    XCTAssertEqual(window.styleMask, initialStyleMask)
    XCTAssertFalse(window.ignoresMouseEvents)

    window.restoreFromPill()
    XCTAssertEqual(window.frame, initialFrame)
    XCTAssertEqual(window.level, initialLevel)
    XCTAssertEqual(window.styleMask, initialStyleMask)
  }

  @MainActor
  func testHubChromeFillsTheScreenAndPersistsTheUsersFrame() {
    NSWindow.removeFrame(usingName: MainFlutterWindow.hubFrameAutosaveName)
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 40, y: 40, width: 400, height: 300),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer {
      window.close()
      NSWindow.removeFrame(usingName: MainFlutterWindow.hubFrameAutosaveName)
    }

    window.enterHubChrome()
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame
    XCTAssertEqual(window.frame, visible)
    // Maximized, not a fullscreen Space: it stays resizable, and the frame
    // is autosaved so a user resize survives the next launch.
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertFalse(window.styleMask.contains(.fullScreen))
    XCTAssertEqual(window.frameAutosaveName, MainFlutterWindow.hubFrameAutosaveName)

    // A user resize is autosaved, and the next launch restores it instead of
    // re-maximizing over the user's choice.
    let resized = NSRect(x: 80, y: 80, width: 900, height: 600)
    window.setFrame(resized, display: false)
    window.saveFrame(usingName: MainFlutterWindow.hubFrameAutosaveName)

    let relaunched = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    relaunched.isReleasedWhenClosed = false
    defer { relaunched.close() }
    relaunched.enterHubChrome()
    XCTAssertEqual(relaunched.frame, resized)
  }

  func testGlobalInputTapWatchesTheChordAndThePointer() {
    let mask = GlobalInputTap.eventMask
    XCTAssertNotEqual(mask & (1 << CGEventType.keyDown.rawValue), 0)
    XCTAssertNotEqual(mask & (1 << CGEventType.flagsChanged.rawValue), 0)
    XCTAssertNotEqual(mask & (1 << CGEventType.mouseMoved.rawValue), 0)
    // Without the Accessibility grant the tap cannot exist, and the app must
    // report that instead of pretending global capture is live.
    let tap = GlobalInputTap()
    tap.start()
    defer { tap.stop() }
    XCTAssertEqual(tap.isInstalled, AXIsProcessTrusted())
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
