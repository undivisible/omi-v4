// SCAFFOLDING — see docs/live-activities.md for what remains manual.
//
// This file defines the ActivityAttributes shape a future `OmiWidgets`
// WidgetKit extension target should adopt to show pendant connection state
// (Live Activity + Dynamic Island) on iOS 16.1+.
//
// It intentionally does NOT compile against ActivityKit today: adding a
// widget extension target is an Xcode project change (new target, new
// bundle id, new entitlements, embedding it in the Runner app) that is out
// of scope for an automated source-only pass. This struct is the contract
// the extension and the LiveActivityBridge method channel handler
// (TODO, also not yet implemented — see below) should share once that
// target exists.
//
// TODO(live-activities): once the OmiWidgets extension target exists:
//   1. Move this file into the new target (or a shared framework both
//      Runner and OmiWidgets link against) and add `import ActivityKit`.
//   2. Make `PendantActivityAttributes` conform to `ActivityAttributes`.
//   3. Implement a `LiveActivityBridge` FlutterMethodChannel handler in
//      ios/Runner (mirroring AppleEventKitBridge.swift's pattern) on
//      channel "omi/live_activity" handling methods "start" / "update" /
//      "end" with arguments {connected: Bool, batteryLevel: Int?,
//      deviceName: String, listening: Bool}, calling
//      Activity<PendantActivityAttributes>.request(...) / .update(...) /
//      .end(...).
//   4. Wire that handler into AppDelegate.swift the same way
//      AppleEventKitBridge is wired (registrar(forPlugin:).messenger()).
//   5. Design the widget's Lock Screen / Dynamic Island SwiftUI views in
//      the new target using `content.state.connected/batteryLevel/...`.
//
// The Dart-side plumbing (lib/native/live_activity_bridge.dart) already
// calls the "omi/live_activity" channel on every DeviceRelaySnapshot change
// and safely no-ops (catches MissingPluginException) until steps 1-5 above
// land, so wiring up the extension later requires no further Dart changes.

/// Fields mirrored from `DeviceRelaySnapshot` for the pendant Live Activity.
///
/// Not yet a real `ActivityAttributes` conformance — see TODO above.
struct PendantActivityAttributesShape {
  struct ContentState {
    var connected: Bool
    var batteryLevel: Int?
    var listening: Bool
  }

  var deviceName: String
}
