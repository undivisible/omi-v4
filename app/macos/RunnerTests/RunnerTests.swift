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

}
