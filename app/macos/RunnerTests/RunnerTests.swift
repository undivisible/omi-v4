import Cocoa
import FlutterMacOS
import XCTest
@testable import omi

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testAccessibilityPolicyRequiresLivePermissionAndFunctionalAX() {
    XCTAssertFalse(
      AccessibilityPermissionPolicy.isGranted(
        trusted: false,
        eventTapAvailable: false,
        axFunctional: true))
    XCTAssertTrue(
      AccessibilityPermissionPolicy.isGranted(
        trusted: false,
        eventTapAvailable: true,
        axFunctional: true))
    XCTAssertFalse(
      AccessibilityPermissionPolicy.isGranted(
        trusted: true,
        eventTapAvailable: false,
        axFunctional: false))
  }

  func testAccessibilityProbeClassifiesPermissionErrors() {
    XCTAssertEqual(AccessibilityPermissionPolicy.isFunctional(.success), true)
    XCTAssertEqual(AccessibilityPermissionPolicy.isFunctional(.noValue), true)
    XCTAssertEqual(AccessibilityPermissionPolicy.isFunctional(.apiDisabled), false)
    XCTAssertNil(AccessibilityPermissionPolicy.isFunctional(.cannotComplete))
  }

  func testFullDiskPolicyUsesOnlyScannedOmiSources() {
    let library = URL(fileURLWithPath: "/Users/example/Library", isDirectory: true)
    XCTAssertEqual(
      FullDiskAccessProbePolicy.files(in: library).map(\.path),
      [
        "/Users/example/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
        "/Users/example/Library/Group Containers/group.com.apple.notes/Accounts/LocalAccount/NoteStore.sqlite",
      ])
    XCTAssertEqual(
      FullDiskAccessProbePolicy.directories(in: library).map(\.path),
      ["/Users/example/Library/Mail"])
    XCTAssertFalse(FullDiskAccessProbePolicy.isGranted([false, false, false]))
    XCTAssertTrue(FullDiskAccessProbePolicy.isGranted([false, true, false]))
  }

}
