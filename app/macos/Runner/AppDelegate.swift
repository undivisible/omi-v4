import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Nothing else brings the hub forward on a cold launch: MenuBarBridge only
  // activates when summoned, and the pill deliberately never does. Without
  // this the window opens behind whatever the user is already in, and the
  // cold open plays out where nobody can see it.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  @IBAction func openSettings(_ sender: Any?) {
    guard let window = mainFlutterWindow as? MainFlutterWindow else { return }
    window.requestSettings()
  }
}
