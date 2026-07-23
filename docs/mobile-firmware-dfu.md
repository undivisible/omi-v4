# Pendant firmware update from the mobile app

What ships today, and what still has to be proved on a physical pendant.

## Shipped

| Piece | Where |
| --- | --- |
| DFU capability probe (SMP service `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`) | `app/lib/device/universal_ble_device_relay.dart`, `DeviceRelayDfu` in `app/lib/device/device_relay.dart` |
| Release lookup on the `firmware-v*` tag stream, artifact selection, version compare, dismissal | `app/lib/features/firmware_update_check.dart` |
| Pre-flight gate (disconnected / unsupported / low battery / capturing) | `firmwareUpdateBlock` in the same file |
| Mid-flow abort rule (battery, capture) | `firmwareUpdateAbort` in the same file |
| Streaming download with progress into the temporary directory | `FirmwareDownloader` |
| `manifest.json` parsing and `dfu_application.zip` unpacking (pure Dart, `archive`) | `app/lib/device/firmware_dfu.dart` |
| The flash itself over SMP/mcumgr | `McuMgrFirmwareFlasher` in the same file |
| Size + SHA-256 verification, downgrade refusal, link handover, reconnect, post-flash version confirmation | `app/lib/features/firmware_install.dart` |
| Home banner (same `_BannerCta` component as the desktop install notice), settings entry point, update screen with real progress | `app/lib/features/mobile_companion_shell.dart` |

The banner and the settings row only appear when the connected pendant
advertises the SMP service, so a DevKit build (Adafruit UF2 bootloader, no
MCUboot OTA) never sees them. Developer options states why, rather than leaving
the absence unexplained.

## Safety rules the code enforces

`omi-cv1` runs MCUboot **overwrite-only with downgrade prevention**
(`firmware/bootloader/mcuboot/mcuboot.conf`): there is no rollback slot.

1. `eraseAppSettings` is **false**. True would erase the NVS partition that
   holds the persisted device name (`19B10016`) and the mic gain.
   `FirmwareUpgradeMode.confirmOnly` matches a bootloader with no revert slot.
2. An image whose version is not strictly newer than the DIS revision
   (`0x2A26`) is refused before anything is downloaded.
3. A package whose byte count does not match the release's `size`, or whose
   SHA-256 does not match the release's `digest`, is never unpacked.
4. The gate is evaluated when the button is pressed **and** again immediately
   before the BLE link is released. Battery and capture are re-read on every
   flash progress event; a capture started mid-upload aborts. Battery mid-flash
   is the last value read before the handover — the app has no link to re-read
   it over.
5. Aborting during the upload is safe and offered: MCUboot swaps only after a
   whole image has landed in the secondary slot.
6. Success is only claimed after reconnecting and re-reading `0x2A26`.
7. Every failure carries a recovery line (nRF Connect for Desktop Programmer or
   a J-Link with the release's `merged.hex`), never a silent dead end.

## Not implemented: legacy Nordic Secure DFU

Upstream Omi carries `nordic_dfu` alongside `mcumgr_flutter` because its older
DevKit images use the legacy Secure DFU protocol. Our shipping device is
nRF5340/MCUboot, so only the mcumgr path is implemented. Devices on the legacy
path have no SMP service, so the affordance stays hidden for them — the same
graceful path as any pre-OTA firmware.

## Not verified

- No `firmware-v*` release has been published yet, so the real download has
  never run end to end. Everything is covered against fakes and a fixture zip
  built in-test (`app/test/features/firmware_install_test.dart`).
- **The flash has never run against hardware.** `McuMgrFirmwareFlasher` is the
  one piece with no test coverage beyond compiling: it is a thin adapter over
  `mcumgr_flutter`'s method channel.
- First real-device run should watch: that the `manifest.json` in our
  `dfu_application.zip` really carries `image_index` for both cores; that the
  peripheral is genuinely free after `disconnectDevice()` plus the two-second
  settle (raise the settle if mcumgr reports a connect failure); that the
  pendant re-advertises after the swap so `connectDevice` finds it again; and
  that the DIS revision string equals the release version exactly, since the
  confirmation compares them.

## Release-side prerequisite

The `firmware-v*` releases must attach `dfu_application.zip` with the build
target in the file name (for example `omi-cv1-dfu_application.zip`) when more
than one target is published in the same release. `FirmwareUpdateChecker`
refuses to guess between several packages, and will report "up to date" rather
than offer a possibly-wrong image.
