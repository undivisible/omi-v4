# Pendant firmware update from the mobile app

What ships today, and what still has to be proved on a physical pendant.

## Shipped

| Piece | Where |
| --- | --- |
| DFU capability probe and transport selection (SMP service `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`, Nordic Secure DFU `0xFE59`, Nordic legacy DFU `00001530-1212-EFDE-1523-785FEABCD123`) | `app/lib/device/universal_ble_device_relay.dart`, `DeviceRelayDfu` in `app/lib/device/device_relay.dart` |
| Release lookup on the `firmware-v*` tag stream, artifact selection, version compare, dismissal | `app/lib/features/firmware_update_check.dart` |
| Pre-flight gate (disconnected / unsupported / low battery / capturing) | `firmwareUpdateBlock` in the same file |
| Mid-flow abort rule (battery, capture) | `firmwareUpdateAbort` in the same file |
| Streaming download with progress into the temporary directory | `FirmwareDownloader` |
| `manifest.json` parsing and `dfu_application.zip` unpacking (pure Dart, `archive`) | `app/lib/device/firmware_dfu.dart` |
| The flash itself over SMP/mcumgr | `McuMgrFirmwareFlasher` in the same file |
| The flash over legacy Nordic Secure DFU | `NordicSecureDfuFlasher` + `PluginNordicDfuRunner` in the same file |
| Size + SHA-256 verification, downgrade refusal, link handover, reconnect, post-flash version confirmation, transport routing | `app/lib/features/firmware_install.dart` |
| Home banner (same `_BannerCta` component as the desktop install notice), settings entry point, update screen with real progress | `app/lib/features/mobile_companion_shell.dart` |

The banner and the settings row appear when the connected pendant advertises
**either** DFU transport — the SMP service, or Nordic's Secure/legacy DFU
service. A pendant advertising neither still sees nothing, and developer
options states why rather than leaving the absence unexplained. A DevKit build
running the Adafruit UF2 bootloader with no BLE DFU service at all is in that
last category; a DevKit or older pendant that *does* expose `0xFE59` now gets
the update affordance rather than having it hidden.

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
   whole image has landed in the secondary slot. Rules 2, 3, 4, 6 and 7 are
   transport-independent and are enforced identically on the legacy path;
   rule 1 is mcumgr configuration and has no legacy equivalent. Rule 5 is the
   one that is weaker on legacy: Nordic Secure DFU on a single-bank device
   activates as it writes, so an abort there can leave the pendant sitting in
   its DFU bootloader. `NordicSecureDfuFlasher` calls `abortDfu` on cancel, but
   what the pendant does afterwards has not been observed.
6. Success is only claimed after reconnecting and re-reading `0x2A26`.
7. Every failure carries a recovery line (nRF Connect for Desktop Programmer or
   a J-Link with the release's `merged.hex`), never a silent dead end.

## Legacy Nordic Secure DFU

This reverses an earlier decision. Older pendants and DevKit images predate
MCUboot and expose Nordic's Secure DFU service (`0xFE59`, or the SDK ≤ 11
legacy service `00001530-…`) instead of SMP. They used to be handed a hidden
affordance and no way to update from the app. They are now supported, over
`nordic_dfu` (`^7.1.3`), alongside `mcumgr_flutter`.

How the two paths differ:

- **Selection.** `UniversalBleDeviceRelay.dfuTransport` reads the discovered
  services and returns `mcuboot` when SMP is present, `nordicSecure` when only
  a Nordic DFU service is, and `none` otherwise. SMP wins when a pendant
  somehow advertises both. `dfuSupported` is now `dfuTransport != none`.
- **Routing.** `FirmwareInstaller` picks `flasher` for `mcuboot` and
  `legacyFlasher` (default `NordicSecureDfuFlasher`) for `nordicSecure`. The
  choice is read from the host, not guessed from the package.
- **Package handling.** Secure DFU reads the distribution zip itself, so on the
  legacy path the installer skips `readFirmwarePackage` entirely, passes no
  images, and hands the flasher the downloaded file's path. A release artifact
  that is a Secure DFU distribution zip — with `manifest.json` in Nordic's DFU
  shape rather than MCUboot's, or with no MCUboot manifest at all — therefore
  installs rather than being rejected as unparseable. This is the point of the
  change and is guarded by test.
- **What stays the same.** Size and SHA-256 verification, the downgrade
  refusal, the pre-flight and mid-flash battery/capture gates, the link
  handover and settle, the reconnect, and the post-flash `0x2A26` confirmation
  all run unchanged on both paths.
- **Transport internals.** `PluginNordicDfuRunner` is the adapter over the
  plugin's method channel; `NordicDfuRunner` is the seam that lets everything
  above it be tested without a radio. The runner is configured with
  `enableUnsafeExperimentalButtonlessServiceInSecureDfu: true` and
  `forceScanningForNewAddressInLegacyDfu: true`, because a buttonless pendant
  re-advertises under a different address once it enters DFU mode.

## Not verified

- No `firmware-v*` release has been published yet, so the real download has
  never run end to end. Everything is covered against fakes and a fixture zip
  built in-test (`app/test/features/firmware_install_test.dart`).
- **Neither flash has ever run against hardware.** This is as true of the
  legacy Secure DFU path as it is of the mcumgr one: it has been written and
  unit-tested against a fake `NordicDfuRunner`, and never once against a real
  old pendant. Do not read its presence in the "Shipped" table as evidence it
  works on a device.
- Two adapters have no test coverage beyond compiling, because both are thin
  wrappers over a method channel: `McuMgrFirmwareFlasher` over
  `mcumgr_flutter`, and `PluginNordicDfuRunner` over `nordic_dfu`.
- The transport probe is untested against a real pre-MCUboot pendant. Whether
  old firmware advertises `0xFE59` while running the application (rather than
  only once already in DFU mode) decides whether `dfuTransport` ever returns
  `nordicSecure` in the field; if it does not, the affordance stays hidden for
  exactly the devices this change was made for.
- No `firmware-v*` release publishes a Secure DFU distribution zip today, so
  the legacy path has never been fed a real artifact either. Which artifact a
  legacy pendant should be offered — and how `FirmwareUpdateChecker` should
  tell it apart from `dfu_application.zip` in the same release — is not
  designed yet.
- Legacy-path aborts are unobserved, per safety rule 5 above.
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
