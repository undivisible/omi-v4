# Firmware vendoring provenance

The Omi device firmware in this directory is vendored from a separate upstream
repository. It covers the nRF5340 CV1 pendant (`omi/`), the XIAO nRF52840 Sense
DevKit (`devkit/`) and the CV1 bring-up harness (`test/`). It is **not** built by
this repo's CI (it needs the Zephyr SDK / nRF Connect SDK toolchain).

## Upstream

| Field | Value |
| --- | --- |
| Upstream repo (local path) | `~/projects/omi` |
| Upstream remote | `https://github.com/BasedHardware/omi.git` |
| Branch vendored | `firmware/idle-auto-sleep` |
| Commit SHA | `ed4e513e64702b33fa088f1a0f58fc60e1935976` |
| Upstream commit date | 2026-07-23 02:50:56 -0400 |
| Upstream subtree | `omi/firmware/` |
| Vendored on | 2026-07-23 |

`firmware/idle-auto-sleep` was chosen over `main` because it carries the
idle auto-sleep, DIS firmware-revision, capture-state LED (`19B10015`), BLE
sleep command (`19B10014`) and writable device name (`19B10016`) work.

Verify the upstream tip with:

```sh
git -C ~/projects/omi log --oneline firmware/idle-auto-sleep -5
```

## What was included

Everything the CV1, DevKit and bring-up images need to build:

| Path here | Upstream path | Notes |
| --- | --- | --- |
| `omi/` | `omi/firmware/omi/` | Production CV1 application (Zephyr app root) |
| `omi/src/lib/core/lib/opus-1.2.1/` | same | Vendored Opus 1.2.1, built when `CONFIG_OMI_CODEC_OPUS=y` |
| `devkit/` | `omi/firmware/devkit/` | Seeed XIAO nRF52840 Sense DevKit application, three build configurations |
| `test/` | `omi/firmware/test/` | nRF5340 bring-up and BLE-throughput harness for the same board root as `omi/`. Kept because nothing in this tree is compile-verified and it is the fastest way to validate hardware and measure throughput |
| `boards/omi/` | `omi/firmware/boards/omi/` | nRF5340 board definition (`BOARD_ROOT` target for `omi/` and `test/`) |
| `bootloader/mcuboot/` | `omi/firmware/bootloader/mcuboot/` | MCUboot Kconfig fragment + image signing key |
| `.clang-format` | `omi/firmware/.clang-format` | Formatting rules for the C sources |
| `BUILD_AND_OTA_FLASH.md` | `omi/firmware/BUILD_AND_OTA_FLASH.md` | Upstream build/OTA guide (kept verbatim as reference). `README.md` supersedes it and covers every target |

### `bootloader/mcuboot/root-rsa-2048.pem`

This is the MCUboot **image signing** key referenced by
`omi/sysbuild.conf` (`SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`). It is the key that is
already published in the upstream open-source repository and already burned into
shipped devices — it is *not* a secret, and it is load-bearing: an image signed
with any other key will be rejected by the MCUboot already on the pendant, so
OTA would break. It must stay byte-identical to upstream.

## What was excluded

| Path | Why |
| --- | --- |
| `omi/firmware/FLASH_3.0.8/` | ~40 MB of prebuilt `.hex`/`.exe` flashing blobs for an old release |
| `omi/firmware/bootloader/bootloader0.9.0.uf2`, `bootloader/deprecated/` | XIAO nRF52840 Adafruit bootloader images, unrelated to the nRF5340 |
| `omi/firmware/bootloader/mcuboot/enc-rsa2048-{priv,pub}.pem` | MCUboot image **encryption** keys; encryption is not enabled anywhere in this tree (no `SB_CONFIG_BOOT_ENCRYPTION`, no reference in any `.conf`), so the private key was not vendored |
| `omi/firmware/omi/src/lib/evt/` | EVT-hardware bring-up variant. Not referenced by `omi/CMakeLists.txt`, so it never compiles into the production image |
| `omi/firmware/AGENTS.md` | Upstream repo's agent instructions, not applicable here |
| `omiGlass/` | Different product and architecture (Seeed XIAO ESP32-S3 Sense, PlatformIO/Arduino). Assessed and deliberately not vendored — see below |
| everything outside `omi/firmware/` | Application, backend, SDKs, web, infrastructure: out of scope for a firmware tree |
| `.git` | Not a submodule; this is a flat vendored copy |

### The glasses firmware: assessed, not vendored

`omiGlass/firmware` upstream targets a Seeed XIAO ESP32-S3 Sense
(`platform = espressif32`, `framework = arduino` in its `platformio.ini`), with
a `firmware.ino`, camera pin headers and `partitions_ota.csv`. A near-identical
public sibling exists at `BasedHardware/OpenGlass` — same board, Arduino IDE
rather than PlatformIO — and it is not established which of the two is current.

It was **not** vendored, because: none of the Zephyr feature work in this tree
ports to an ESP32 Arduino sketch; it shares no BLE contract with the pendants;
it would add a second toolchain to any CI matrix; the upstream tree carries a
committed `.pio/libdeps/` build cache of third-party libraries; and the
OpenGlass-versus-omiGlass question would have to be settled first. The full
reasoning is in `ARCHITECTURE.md` §2.1.

`BasedHardware/Whomane` is a Raspberry Pi Python wearable, not MCU firmware, and
is out of scope entirely.

## Divergence from upstream

This tree is **not** a pristine mirror. After the initial vendoring commit
(which is pristine minus the exclusions above), local feature work was applied
on top. See `git log -- firmware/` for the exact set. The feature work covers:

- button gesture semantics + user-event BLE characteristic (CV1 and DevKit)
- T5838 hardware-AAD tuning exposed as Kconfig (CV1); a clearly labelled
  software VAD gate instead on the DevKit
- IMU wake-on-motion / tap gestures (CV1 only)
- charging-state BLE notify improvements
- build-derived firmware version (DIS `0x2A26`) for both applications
- offline-sync contract verified and documented, two reliability fixes
- connection-parameter tuning and an `omi.conf` / Kconfig lean pass
- a port of the portable subset to the DevKit in `devkit/src/omi_ext.c`
- a fix for an upstream typo that silently disabled offline storage in the
  DevKit SPI-SD configuration

### SDK divergence: upstream is on v2.9.0, this tree is on v3.4.0

**This is the largest and most consequential divergence, and it is one-way.**
Upstream `BasedHardware/omi` builds against nRF Connect SDK v2.9.0 (Zephyr 3.7).
This tree was migrated to nRF Connect SDK v3.4.0 (Zephyr 4.4.0). Every future
upstream change to a file listed below must now be ported by hand rather than
merged, because the same file has been edited here for the newer SDK.

Files that diverge for SDK reasons only (not feature work):

| Path | Divergence |
| --- | --- |
| `boards/omi/board.yml` | added `full_name`, now required by the board schema |
| `boards/omi/omi_nrf5340_cpuapp.dts` | `<common/nordic/…>` include prefix dropped; `disk-name` on the `mmc` node; `nfct-pins-as-gpios` on `&uicr` |
| `boards/omi/omi_nrf5340_cpunet.dts` | `<common/nordic/…>` include prefix dropped |
| `boards/omi/omi_nrf5340_cpuapp_defconfig` | `CONFIG_NFCT_PINS_AS_GPIOS` removed (moved to devicetree) |
| `boards/omi/omi_nrf5340_cpunet_defconfig` | `CONFIG_BT_CTLR=y` removed (no longer user-assignable) |
| `boards/omi/Kconfig.defconfig` | `BT_CTLR` default block removed |
| `boards/omi/pm_static.yml` | **renamed** to `pm_static_omi_nrf5340_cpuapp.yml` so it is no longer misapplied to the CPUNET domain |
| `omi/sysbuild.conf`, `test/sysbuild.conf` | `SB_CONFIG_PARTITION_MANAGER=y` added; it no longer defaults on |
| `omi/sysbuild/mcuboot.conf` | dead `CONFIG_NCS_SAMPLE_MCUMGR_BT_OTA_DFU` removed |
| `omi/sysbuild/ipc_radio.conf` | dead `BT_PERIPHERAL_PREF_*` block removed |
| `omi/omi.conf`, `test/omi.conf` | `CONFIG_NRFX_PDM0`, `CONFIG_I2S_NRFX`, `CONFIG_SDMMC_VOLUME_NAME` removed; `CONFIG_BT_BUF_EVT_RX_COUNT=12` added |
| `omi/src/sd_card.c` | disk name read from devicetree instead of Kconfig |
| `omi/src/lib/core/transport.c`, `devkit/src/transport.c`, `test/src/ble.c`, `test/src/ble_throughput_test.c` | `BT_LE_ADV_CONN` → `BT_LE_ADV_CONN_FAST_2` |

Files that diverge because a **pre-existing defect** was fixed (the tree had
never been compiled before this upgrade, so these were latent):
`omi/src/lib/core/transport.c`, `omi/src/lib/core/lib/battery/battery.h`,
`test/app.overlay`, `test/src/imu.c`, `test/src/mic.c`, `test/src/mic.h`,
`test/src/main.c`, `test/src/motor.c`. See the README's *Migration status*
section for the exact list.

The three `devkit-*` targets are **not yet migrated** and do not build under
v3.4.0; `devkit/src/mic.c` needs porting to the nrfx 3.x PDM API, and
`devkit/src/{usb,button,transport,sdcard}.c` carry pre-existing compile errors.
Until that is done, DevKit changes can still be taken from upstream almost
verbatim.

When re-syncing, expect step 3 of *How to re-sync with upstream* to produce a
large diff on every file in the first table. Those hunks are deliberate; do not
take the upstream side.

See `ARCHITECTURE.md` for the full upstream comparison and the per-device
support matrix, `BLE_CONTRACTS.md` for the resulting app-facing interface, and
`README.md` for per-target build instructions and the SDK migration record.

## How to re-sync with upstream

1. Fetch upstream and pick the commit to vendor:

   ```sh
   git -C ~/projects/omi fetch origin
   git -C ~/projects/omi log --oneline firmware/idle-auto-sleep -20
   ```

2. Export the same subtree into a scratch directory:

   ```sh
   SHA=<new-sha>
   git -C ~/projects/omi archive "$SHA" \
       omi/firmware/omi omi/firmware/devkit omi/firmware/test \
       omi/firmware/boards omi/firmware/bootloader/mcuboot \
       omi/firmware/.clang-format omi/firmware/BUILD_AND_OTA_FLASH.md \
       -o /tmp/omi-fw.tar
   mkdir -p /tmp/omi-fw && tar -xf /tmp/omi-fw.tar -C /tmp/omi-fw --strip-components=2
   rm -rf /tmp/omi-fw/omi/src/lib/evt /tmp/omi-fw/bootloader/mcuboot/enc-rsa2048-*.pem
   ```

3. Diff against this tree and merge deliberately — do **not** blindly overwrite,
   because of the local divergence listed above:

   ```sh
   diff -ru firmware /tmp/omi-fw | less
   ```

4. Update the SHA / date / branch table at the top of this file in the same
   commit, and re-check `BLE_CONTRACTS.md` if any GATT code changed.
