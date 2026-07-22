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
  }

}
