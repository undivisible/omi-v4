# Live Activities (iOS 16.1+ Dynamic Island / Lock Screen)

Status: **scaffolded, not wired**. The plumbing on the Dart side is real and
safe to call; the native side is a documented stub because adding a
WidgetKit extension target is an Xcode project change that's risky to do
purely from source edits without an Xcode session to verify the build
graph.

## What's real today

- `app/lib/native/live_activity_bridge.dart` — `LiveActivityBridge` calls a
  `omi/live_activity` method channel (`start` / `update` / `end`) with
  `{connected, batteryLevel, deviceName, listening}`. It's wired into
  `MobilePendantPageState` in `app/lib/features/mobile_companion_shell.dart`
  and fires on every `DeviceRelaySnapshot` change, and calls `end()` on
  dispose.
- Because no native handler is registered for that channel yet, every call
  hits `MissingPluginException`, which the bridge catches and swallows —
  it's a safe no-op today, not a crash.
- `app/ios/Runner/LiveActivityAttributes.swift` — a plain Swift struct
  (`PendantActivityAttributesShape`) mirroring the state Live Activities
  should show (`connected`, `batteryLevel`, `listening`, `deviceName`). It
  does not import `ActivityKit` and does not conform to
  `ActivityAttributes` yet — see the TODO block in that file.

## What's manual / not yet done

1. **Add a WidgetKit extension target** named `OmiWidgets` to
   `ios/Runner.xcodeproj` in Xcode (File → New → Target → Widget
   Extension). This needs a human/Xcode session: it creates a new bundle
   id, provisioning, entitlements, and an Info.plist that are impractical
   to hand-edit into the `.pbxproj` reliably.
2. Move `LiveActivityAttributes.swift` (or a copy) into that target, add
   `import ActivityKit`, and make `PendantActivityAttributesShape` actually
   conform to `ActivityAttributes` (rename if desired — e.g.
   `PendantActivityAttributes`).
3. Build the widget's Lock Screen and Dynamic Island SwiftUI views in the
   new target, reading `context.state.connected` /
   `context.state.batteryLevel` / `context.state.listening` /
   `context.attributes.deviceName`.
4. Add a native method channel handler in `ios/Runner` (mirror
   `AppleEventKitBridge.swift`'s pattern) on channel name
   `omi/live_activity` handling:
   - `start` → `Activity<PendantActivityAttributes>.request(attributes:content:)`
   - `update` → find the running activity and call `.update(...)`
   - `end` → call `.end(...)`
5. Wire that handler into `ios/Runner/AppDelegate.swift`
   `didInitializeImplicitFlutterEngine` the same way
   `AppleEventKitBridge` is registered (via
   `engineBridge.pluginRegistry.registrar(forPlugin:)?.messenger()`).
6. Add `NSSupportsLiveActivities = true` to `ios/Runner/Info.plist`.

No further Dart-side changes should be required once 1-6 land — the
`LiveActivityBridge` call sites are already in place and will simply stop
throwing `MissingPluginException` once the native side exists.
