# Pendant firmware update from the mobile app

What ships today, and exactly what is left before the app may write an image to
a pendant.

## Shipped

| Piece | Where |
| --- | --- |
| DFU capability probe (SMP service `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`) | `app/lib/device/universal_ble_device_relay.dart`, `DeviceRelayDfu` in `app/lib/device/device_relay.dart` |
| Release lookup on the `firmware-v*` tag stream, artifact selection, version compare, dismissal | `app/lib/features/firmware_update_check.dart` |
| Pre-flight gate (disconnected / unsupported / low battery / capturing) | `firmwareUpdateBlock` in the same file |
| Streaming download with progress into the temporary directory | `FirmwareDownloader` |
| Settings entry point and the update screen | `app/lib/features/mobile_companion_shell.dart` (`companion_firmware_update`, `_FirmwareUpdatePage`) |

The row only appears when the connected pendant advertises the SMP service, so
a DevKit build (Adafruit UF2 bootloader, no MCUboot OTA) never sees it.

## Deliberately not shipped: the flash

The install control is absent, not disabled-with-a-spinner. `omi-cv1` runs
MCUboot **overwrite-only with downgrade prevention**
(`firmware/bootloader/mcuboot/mcuboot.conf`), so a partially written image has
no slot to roll back to: an aborted or mis-selected write is a brick, not a
retry. Nothing in this repository can exercise that path — there is no pendant
in CI and the firmware tree is not even compile-verified — so the screen ends at
"downloaded, flash it with nRF Connect for Mobile" and links to the release.

## Remaining wiring

1. **Add the transport.** `mcumgr_flutter` (Nordic, Apache-2.0, no telemetry) is
   the match for MCUboot/SMP on nRF5340 and nRF52840. `nordic_dfu` implements
   the *legacy* Nordic Secure DFU protocol and does **not** apply here — upstream
   Omi carries both only because its older DevKit images use the legacy path.
   Adding it pulls in `iOSMcuManagerLibrary` (CocoaPods) and the Android
   `mcumgr-android` library; neither has a macOS implementation, so confirm
   `flutter build macos --debug` still links before going further.
2. **Unpack the artifact.** `dfu_application.zip` contains `manifest.json` plus
   one signed `.bin` per image (app core, and on the nRF5340 the network core).
   Parse the manifest and build `mcumgr.Image(image: <slot>, data: <bytes>)` per
   entry. Prefer the pure-Dart `archive` package over `flutter_archive` so the
   unpack stays testable off-device.
3. **Free the link first.** Stop `DeviceAudioForwarder`, unsubscribe the audio
   characteristic and let the connection idle before handing the device id to
   `FirmwareUpdateManagerFactory().getUpdateManager(deviceId)`; mcumgr opens its
   own GATT connection and will fight the relay's.
4. **Drive the upload.** `updateManager.setup()` for the state stream,
   `progressStream` for bytes, then `update(images, configuration:
   FirmwareUpgradeConfiguration(estimatedSwapTime: …, eraseAppSettings: false,
   pipelineDepth: 1))`. `eraseAppSettings: true` would wipe the NVS that holds
   the device name (`19B10016`) and mic gain — keep it false.
5. **Re-check the gate per chunk, not once.** Battery and capture state can
   change mid-upload; re-read `19B10013`/battery and abort cleanly on a drop
   below `firmwareUpdateMinimumBattery`.
6. **Handle the reboot.** The pendant disconnects when MCUboot swaps. Expect the
   link to drop, reconnect on the same BLE address, and confirm success by
   re-reading DIS `0x2A26` and comparing to the version that was installed —
   the only honest "it worked".
7. **Failure paths to cover before enabling the control:** upload interrupted by
   distance, phone backgrounded mid-upload, wrong image for the target, image
   version not greater than installed (downgrade prevention rejects it), and a
   pendant that reboots into the old image.
8. **Tests to add with it:** manifest parsing from a fixture zip, the abort path
   leaving no partial state in the app, and the post-flash version confirmation.

## Release-side prerequisite

The `firmware-v*` releases must attach `dfu_application.zip` with the build
target in the file name (for example `omi-cv1-dfu_application.zip`) when more
than one target is published in the same release. `FirmwareUpdateChecker`
refuses to guess between several packages, and will report "up to date" rather
than offer a possibly-wrong image.
