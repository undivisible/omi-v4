# Omi device firmware

Zephyr / nRF Connect SDK firmware for the Omi wearables, vendored from
`BasedHardware/omi`. See [`PROVENANCE.md`](PROVENANCE.md) for what was vendored
and how to re-sync, [`ARCHITECTURE.md`](ARCHITECTURE.md) for how it is put
together and how it differs from upstream, and
[`BLE_CONTRACTS.md`](BLE_CONTRACTS.md) for the app-facing GATT interface.

This tree is **excluded from the repository's CI** (`.github/workflows/ci.yml`
has `paths-ignore: firmware/**`) because it needs the nRF Connect SDK toolchain,
which no CI job installs.

> **Not compile-verified.** The changes in this tree were written without a
> Zephyr / nRF Connect SDK toolchain available. They were statically checked
> (every `CONFIG_OMI_*` symbol referenced resolves, every devicetree node label
> and alias resolves) but never compiled. Build all four targets before relying
> on any of it.

## Build targets

| Target id | App directory | Board | SoC | Config file | Extra |
| --- | --- | --- | --- | --- | --- |
| `omi-cv1` | `omi/` | `omi/nrf5340/cpuapp` | nRF5340 | `omi/omi.conf` → `omi/prj.conf` | `--sysbuild`, `BOARD_ROOT` |
| `devkit-v1` | `devkit/` | `xiao_ble/nrf52840/sense` | nRF52840 | `devkit/prj_xiao_ble_sense_devkitv1.conf` | overlay |
| `devkit-v1-spisd` | `devkit/` | `xiao_ble/nrf52840/sense` | nRF52840 | `devkit/prj_xiao_ble_sense_devkitv1-spisd.conf` | overlay |
| `devkit-v2-adafruit` | `devkit/` | `xiao_ble/nrf52840/sense` | nRF52840 | `devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf` | overlay |
| `evt-test` | `test/` | `omi/nrf5340/cpuapp` | nRF5340 | `test/omi.conf` → `test/prj.conf` | `--sysbuild`, `BOARD_ROOT`, bring-up/throughput harness, not a shipping image |

**Board name caveat for the DevKit targets.** The board identifier for the Seeed
XIAO nRF52840 Sense was renamed across Zephyr versions and the vendored files
disagree with each other: `devkit/CMakeLists.txt` sets
`set(BOARD seeed_xiao_nrf52840_sense)` while `devkit/CMakePresets.json` uses
`BOARD: xiao_ble_sense`. Under NCS v2.9.0 (Zephyr 3.7, hardware model v2) the
correct identifier is `xiao_ble/nrf52840/sense`. Pass `-b` explicitly on the
command line — it overrides the `set(BOARD ...)` in `CMakeLists.txt` — and
confirm with `west boards | grep xiao` in your workspace before wiring this into
CI.

## Toolchain

nRF Connect SDK **v2.9.0**, installed through Nordic's toolchain manager. Do not
mix SDK versions between the images in a sysbuild.

```sh
# nrfutil itself
brew install nrfutil            # macOS; or download from nordicsemi.com
nrfutil install toolchain-manager
nrfutil toolchain-manager install --ncs-version v2.9.0

# host build tools
brew install ninja ccache       # apt: ninja-build ccache
```

One-time west workspace, inside the SDK shell:

```sh
nrfutil toolchain-manager launch --ncs-version v2.9.0 --shell

mkdir -p <workspace>/v2.9.0 && cd <workspace>/v2.9.0
west init -m https://github.com/nrfconnect/sdk-nrf --mr v2.9.0
west update          # ~1.5 GB
```

`<workspace>` can be anywhere; `firmware/v2.9.0/` is gitignored if you want it
in-tree. Every build command below assumes you are inside the toolchain shell
and inside the west workspace directory.

Let `FW=/absolute/path/to/<repo>/firmware`.

## `omi-cv1` — production nRF5340 pendant

```sh
cp "$FW/omi/omi.conf" "$FW/omi/prj.conf"

west build -b omi/nrf5340/cpuapp "$FW/omi" \
    --sysbuild \
    --build-dir "$FW/omi/build" \
    -- -DBOARD_ROOT="$FW"
```

`prj.conf` is generated (gitignored); Zephyr will not pick up `omi.conf`
directly. Re-run the copy whenever `omi.conf` changes.

`BOARD_ROOT` must point at `firmware/`, because the board definition lives in
`firmware/boards/omi/`. Without it the build fails with
`No board named 'omi' found`.

sysbuild produces four images: MCUboot, the network-core bootloader `b0n`, the
network-core radio image `ipc_radio`, and the application.

Outputs in `omi/build/`:

| File | Use |
| --- | --- |
| `dfu_application.zip` | **OTA package** — this is what the app and nRF Connect for Mobile consume |
| `merged.hex` | Full application-core image for SWD programming |
| `merged_CPUNET.hex` | Network-core image for SWD programming |
| `partitions.yml`, `build_info.yml` | Partition layout and build configuration, useful in release artifacts |

Clean rebuild: `west build -t pristine --build-dir "$FW/omi/build"`, or just
delete the build directory.

### Flashing `omi-cv1`

**OTA (no hardware tools):** copy `dfu_application.zip` to a phone, open nRF
Connect for Mobile, connect to the pendant (advertised name `Omi`), open the DFU
tab, select the zip, upload. Two to five minutes. MCUboot is configured
overwrite-only with downgrade prevention
(`bootloader/mcuboot/mcuboot.conf`), so the image version derived from
`omi/VERSION` must be greater than what is on the device.

**SWD (J-Link / nRF debugger):**

```sh
west flash --build-dir "$FW/omi/build"
```

Images are signed with `bootloader/mcuboot/root-rsa-2048.pem`, which is the key
shipped devices already trust. Do not substitute a different key or OTA will
stop working on existing units.

## `devkit-*` — XIAO nRF52840 Sense

Three configurations off the same `devkit/` application. They differ only in
config file and devicetree overlay:

```sh
# devkit-v1: bare XIAO Sense, onboard PDM mic, no SD
west build -b xiao_ble/nrf52840/sense "$FW/devkit" \
    --build-dir "$FW/devkit/build/devkitv1" \
    -- -DCONF_FILE="$FW/devkit/prj_xiao_ble_sense_devkitv1.conf" \
       -DDTC_OVERLAY_FILE="$FW/devkit/overlay/xiao_ble_sense_devkitv1.overlay"

# devkit-v1-spisd: adds an external SPI SD card module and offline storage
west build -b xiao_ble/nrf52840/sense "$FW/devkit" \
    --build-dir "$FW/devkit/build/devkitv1-spisd" \
    -- -DCONF_FILE="$FW/devkit/prj_xiao_ble_sense_devkitv1-spisd.conf" \
       -DDTC_OVERLAY_FILE="$FW/devkit/overlay/xiao_ble_sense_devkitv1-spisd.overlay"

# devkit-v2-adafruit: Adafruit PDM BFF module, button, battery, USB, haptic, speaker
west build -b xiao_ble/nrf52840/sense "$FW/devkit" \
    --build-dir "$FW/devkit/build/devkitv2-adafruit" \
    -- -DCONF_FILE="$FW/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf" \
       -DDTC_OVERLAY_FILE="$FW/devkit/overlay/xiao_ble_sense_devkitv2-adafruit.overlay"
```

No `--sysbuild` and no `BOARD_ROOT`: the DevKit uses an in-tree Zephyr board and
the XIAO's own Adafruit UF2 bootloader rather than MCUboot.

`devkit/CMakePresets.json` carries the same three configurations for the nRF
Connect VS Code extension. The presets still name the old board id and are kept
as-is for editor use; the commands above are the authoritative ones.

Outputs in each build directory: `zephyr/zephyr.uf2` (and `zephyr.hex`).

### Flashing `devkit-*`

Double-tap the XIAO's reset button to enter the UF2 bootloader — it mounts as a
mass-storage volume named `XIAO-SENSE` — then copy the `.uf2` onto it:

```sh
cp "$FW/devkit/build/devkitv2-adafruit/zephyr/zephyr.uf2" /Volumes/XIAO-SENSE
```

`devkit/flash.sh` does this for the v2-adafruit build on macOS, but it hardcodes
the upstream build path (`build/build_xiao_ble_sense_devkitv2-adafruit/`); if
you use the `--build-dir` layout above, copy the file by hand.

### DevKit button caveat

The DevKit button is an **external** switch between D4 (driven high as a 3.3 V
source) and D5 (`P0.05`), wired by hand — see `devkit/src/button.c`. There is no
pull resistor configured, so `P0.05` floats on a board with no button attached
and `CONFIG_OMI_ENABLE_BUTTON=y` would produce spurious taps.

Consequently `devkit-v1` and `devkit-v1-spisd` ship with the button disabled,
which also disables the single-tap bookmark, the double-tap assistant trigger,
the BLE sleep command and idle auto-sleep on those two targets.
`devkit-v2-adafruit` enables all of them. If you have wired a button to a v1
board, add to its config file:

```
CONFIG_OMI_ENABLE_BUTTON=y
CONFIG_OMI_ENABLE_BLE_SLEEP_CMD=y
CONFIG_OMI_ENABLE_IDLE_SLEEP=y
```

## `evt-test` — nRF5340 bring-up and BLE throughput harness

Not a shipping image. A Zephyr-shell application for exercising the CV1 board's
peripherals and measuring BLE throughput; see `test/README.md` and
`test/BLE_THROUGHPUT_TEST.md`.

```sh
cp "$FW/test/omi.conf" "$FW/test/prj.conf"

west build -b omi/nrf5340/cpuapp "$FW/test" \
    --sysbuild \
    --build-dir "$FW/test/build" \
    -- -DBOARD_ROOT="$FW"
```

Same board root and sysbuild layout as `omi-cv1`; flash it the same way. Its
shell is on UART and on BLE NUS, and it advertises as `Omi EVT`.

## Firmware versions

Each application derives its DIS firmware-revision string (`0x2A26`) from a
Zephyr `VERSION` file at build time; there is no hand-maintained literal:

| Target | Version file | Current |
| --- | --- | --- |
| `omi-cv1` | `omi/VERSION` | 3.1.0 |
| `devkit-*` | `devkit/VERSION` | 1.1.0 |

`CMakeLists.txt` parses the file before `find_package(Zephyr)` and writes a
generated Kconfig fragment that overrides `CONFIG_BT_DIS_FW_REV_STR`. Bump the
`VERSION` file to cut a release. The `.conf` files still contain
`CONFIG_BT_DIS_FW_REV_STR="0.0.0+unset"` as a sentinel: if a device ever reports
that string, the generated fragment was not applied.

The same `VERSION` file feeds imgtool's image version on `omi-cv1`, which is
what MCUboot's downgrade prevention compares.

## Formatting

`firmware/.clang-format` applies to the C sources in `omi/`, `devkit/` and
`test/` (excluding the vendored Opus tree):

```sh
clang-format -i firmware/omi/src/**/*.c firmware/omi/src/**/*.h
```

## Notes for CI

- Every target above needs the NCS v2.9.0 toolchain and a populated west
  workspace; budget for caching `~/.cache/zephyr` and the west modules.
- `omi-cv1` and `evt-test` need `-DBOARD_ROOT` pointing at `firmware/`.
- `omi-cv1` and `evt-test` need the `omi.conf` → `prj.conf` copy step.
- The `devkit-*` targets need `-DCONF_FILE` and `-DDTC_OVERLAY_FILE`; they have
  no `prj.conf` step.
- Release artifacts worth publishing per target: `dfu_application.zip`,
  `merged.hex`, `merged_CPUNET.hex`, `partitions.yml` for the nRF5340 targets;
  `zephyr.uf2` and `zephyr.hex` for the DevKit targets.
- The signing key `bootloader/mcuboot/root-rsa-2048.pem` is in-tree and must be
  used as-is for the nRF5340 targets.
- `.github/workflows/release-firmware.yml` builds its matrix by parsing the
  `west build` commands above with `.github/scripts/discover_firmware_targets.py`,
  including the `cp … prj.conf` line that precedes them. `$FW` is resolved to
  `firmware/` in the checkout. Keep each target's command a single fenced block
  under its own heading, and re-run
  `python3 .github/scripts/discover_firmware_targets.py --print-only` after
  editing this file — it fails if any path it derives is missing from the tree.
